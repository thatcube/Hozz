import Foundation
import HealthKit
import HozzCatalog
import HozzCore
import XCTest
@testable import HozzHealth

final class HealthKitBridgeTests: XCTestCase {
    // MARK: - Anchor coding

    func testAnchorTokenRoundTripsThroughHealthKit() throws {
        let anchor = HKQueryAnchor(fromValue: 4_242)

        let token = try HealthKitAnchorCoding.token(for: anchor)
        let restored = try HealthKitAnchorCoding.anchor(for: token)

        XCTAssertEqual(restored, anchor)
        XCTAssertFalse(token.data.isEmpty)
    }

    func testAnchorTokensAreStableForTheSameAnchor() throws {
        let anchor = HKQueryAnchor(fromValue: 7)

        let first = try HealthKitAnchorCoding.token(for: anchor)
        let second = try HealthKitAnchorCoding.token(for: anchor)

        XCTAssertEqual(first, second)
    }

    func testANilTokenDecodesToNoAnchor() throws {
        XCTAssertNil(try HealthKitAnchorCoding.anchor(for: nil))
    }

    func testAMalformedTokenIsRejectedRatherThanSilentlyIgnored() {
        let token = AnchorToken(data: Data("not an archive".utf8))

        XCTAssertThrowsError(try HealthKitAnchorCoding.anchor(for: token))
    }

    // MARK: - Failure classification

    func testALockedDatabaseIsTransientAndDeferred() {
        let error = NSError(
            domain: HKError.errorDomain,
            code: HKError.Code.errorDatabaseInaccessible.rawValue
        )

        let failure = HealthKitFailure.classify(error, typeIdentifier: "HKQuantityTypeIdentifierStepCount")

        XCTAssertEqual(failure.kind, .deviceLocked)
        XCTAssertEqual(failure.coverageState, .deviceLockedDeferred)
        XCTAssertTrue(
            failure.isTransient,
            "A locked device is the common background failure and must be retried, not treated as permanent."
        )
    }

    func testDeniedAuthorizationStaysIndeterminate() {
        let error = NSError(
            domain: HKError.errorDomain,
            code: HKError.Code.errorAuthorizationDenied.rawValue
        )

        let failure = HealthKitFailure.classify(error)

        XCTAssertEqual(failure.coverageState, .authorizationIndeterminate)
        XCTAssertFalse(failure.isTransient)
    }

    func testUnavailableHealthDataIsReportedAsUnsupported() {
        let error = NSError(
            domain: HKError.errorDomain,
            code: HKError.Code.errorHealthDataUnavailable.rawValue
        )

        XCTAssertEqual(
            HealthKitFailure.classify(error).coverageState,
            .unsupported
        )
    }

    func testANonHealthKitErrorIsNotMisclassified() {
        let error = CocoaError(.fileReadNoSuchFile)

        let failure = HealthKitFailure.classify(error)

        XCTAssertEqual(failure.kind, .unclassified)
        XCTAssertFalse(failure.isTransient)
    }

    func testClassifyingAnAlreadyClassifiedFailureIsIdempotent() {
        let original = HealthKitFailure(
            kind: .deviceLocked,
            typeIdentifier: "x",
            underlyingDescription: "locked"
        )

        XCTAssertEqual(HealthKitFailure.classify(original), original)
    }

    // MARK: - Catalog units

    /// `HKUnit(from:)` raises an Objective-C exception that Swift cannot catch,
    /// so an unrecognised catalog unit would crash the export rather than fail
    /// it. Every unit the catalog can hand to the encoder is checked here.
    func testEveryCatalogQuantityUnitIsAcceptedByHealthKit() throws {
        let quantityEntries = HealthTypeCatalog.entries.filter {
            $0.family == .quantity
        }
        XCTAssertGreaterThan(quantityEntries.count, 100)

        var checked = 0
        for entry in quantityEntries {
            let unitString = try XCTUnwrap(
                entry.canonicalUnit,
                "\(entry.key.rawValue) is a quantity type with no canonical unit."
            )
            let unit = HKUnit(from: unitString)
            XCTAssertEqual(
                unit.unitString,
                HKUnit(from: unit.unitString).unitString,
                "\(entry.key.rawValue) has a unit that does not round-trip: \(unitString)"
            )
            checked += 1
        }
        XCTAssertEqual(checked, quantityEntries.count)
    }

    func testEveryExportableTypeIsAlsoRequestedForReading() {
        let exportable = Set(
            HealthKitTypeRegistry.exportableTypes().map(\.sampleType)
        )
        let requested = HealthKitTypeRegistry.authorizationReadTypes()

        XCTAssertEqual(
            exportable,
            requested,
            "Reading a type Hozz never asked for can only ever look indeterminate."
        )
    }

    func testCorrelationTypesAreNotClaimedAsCovered() {
        let families = Set(
            HealthKitTypeRegistry.exportableTypes().map(\.catalogEntry.family)
        )

        XCTAssertFalse(
            families.contains(.correlation),
            "Correlations cannot be authorized today, so they must not be presented as covered."
        )
    }

    // MARK: - Encoder

    func testEncodingFailuresAreRecordedRatherThanDropped() throws {
        let encoder = HealthSampleEncoder()
        let id = UUID()

        let data = try encoder.encodeEncodingFailure(
            id: id,
            typeIdentifier: "HKQuantityTypeIdentifierStepCount",
            message: "unsupported"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["kind"] as? String, "sampleEncodingError")
        XCTAssertEqual(object["id"] as? String, id.uuidString.lowercased())
    }
}
