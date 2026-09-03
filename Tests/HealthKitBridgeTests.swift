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

    func testEveryTypeHozzReadsIsAlsoRequestedForReading() {
        let exportable = Set(
            HealthKitTypeRegistry.exportableTypes().map(\.sampleType)
                .map { $0 as HKObjectType }
        )
        let characteristics = Set(
            HealthKitTypeRegistry.characteristicTypes()
                .map { $0.characteristicType as HKObjectType }
        )
        let requested = HealthKitTypeRegistry.authorizationReadTypes()

        // Everything Hozz reads is asked for, except the types Health refuses
        // to be asked about at all. Those are granted per object instead, and
        // requesting one is fatal rather than merely refused.
        let readable = exportable.union(characteristics).filter {
            !HealthKitTypeRegistry.isDisallowedInAuthorizationRequest($0)
        }

        XCTAssertEqual(
            readable,
            requested,
            "Reading a type Hozz never asked for can only ever look indeterminate."
        )
        XCTAssertGreaterThan(
            requested.count,
            exportable.count - 1,
            "Characteristics are read too, so the read set must be wider than the sample types."
        )
    }

    /// Asking for a per-object type kills the app rather than being refused.
    ///
    /// Medication doses are granted one medicine at a time, in Health, under
    /// each one's Data Sources & Access. Including the type in an authorization
    /// request does not come back denied — HealthKit raises
    /// `NSInvalidArgumentException` and the process is gone:
    ///
    ///     Authorization to read the following types is disallowed:
    ///     HKMedicationDoseEventTypeIdentifierMedicationDoseEvent
    ///
    /// The suite could not see this, because the fake source never builds a real
    /// request; only pressing Export on a device did. This asserts the set that
    /// would have been handed to HealthKit, which is the closest a test can get
    /// without a real store.
    func testATypeHealthRefusesToBeAskedAboutIsNeverRequested() throws {
        guard #available(iOS 26.0, *) else {
            throw XCTSkip("Medication doses need iOS 26.")
        }
        let doses = HKObjectType.medicationDoseEventType()
        let requested = HealthKitTypeRegistry.authorizationReadTypes()

        XCTAssertFalse(
            requested.contains(doses),
            "Requesting medication doses raises rather than being declined."
        )

        let drained = Set(
            HealthKitTypeRegistry.exportableTypes().map(\.sampleType)
                .map { $0 as HKObjectType }
        )
        XCTAssertTrue(
            drained.contains(doses),
            "Doses are still exported: Health grants them per medicine instead."
        )
    }

    /// Every catalogue key must be the string HealthKit itself reports.
    ///
    /// Most of the catalogue is generated, but a handful of types are added by
    /// hand because Apple does not list them with the others, and a constant's
    /// name is not always its value: `HKObjectType.audiogramSampleType()`
    /// answers `HKDataTypeIdentifierAudiogram`, not `HKAudiogramTypeIdentifier`.
    /// A key that disagrees with the sample it maps to writes records whose
    /// `type` field does not match the cursor that produced them, which is the
    /// sort of thing nobody notices until the data is read back.
    func testEveryExportableKeyMatchesTheIdentifierHealthKitReports() {
        for exportable in HealthKitTypeRegistry.exportableTypes() {
            XCTAssertEqual(
                exportable.catalogEntry.key.rawValue,
                exportable.sampleType.identifier,
                "\(exportable.catalogEntry.key.rawValue) is not what HealthKit calls this type."
            )
        }
    }

    func testEveryCharacteristicKeyMatchesTheIdentifierHealthKitReports() {
        for characteristic in HealthKitTypeRegistry.characteristicTypes() {
            XCTAssertEqual(
                characteristic.catalogEntry.key.rawValue,
                characteristic.characteristicType.identifier
            )
        }
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

    /// HealthKit stores some workout metrics as a series: one sample whose
    /// quantity is an aggregate over many readings. Written without a count,
    /// an average of three hundred readings looks exactly like one
    /// measurement.
    func testAnAggregateQuantitySaysHowManyReadingsItStandsFor() {
        let object = HealthSampleEncoder.quantityObject(
            unit: "count/min",
            value: 142,
            description: "142 count/min",
            count: 300
        )

        XCTAssertEqual(object["count"] as? Int, 300)
        XCTAssertEqual(
            (object["canonical"] as? [String: Any])?["value"] as? Double,
            142
        )
        XCTAssertEqual(
            (object["original"] as? [String: Any])?["description"] as? String,
            "142 count/min"
        )
        XCTAssertNil((object["original"] as? [String: Any])?["unit"])
        XCTAssertNil((object["original"] as? [String: Any])?["value"])
        XCTAssertEqual(
            object["aggregatesSeries"] as? Bool,
            true,
            "One number standing for three hundred must not read as a single measurement."
        )
    }

    func testASingleReadingIsNotLabelledAsAnAggregate() {
        let object = HealthSampleEncoder.quantityObject(
            unit: "count",
            value: 412,
            description: "412 count",
            count: 1
        )

        XCTAssertEqual(object["count"] as? Int, 1)
        XCTAssertNil(
            object["aggregatesSeries"],
            "A plain reading must not be dressed up as an aggregate either."
        )
    }

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
        let failureID = HealthSampleEncoder.encodingFailureID(
            sourceRecordID: id,
            typeIdentifier: "HKQuantityTypeIdentifierStepCount"
        )

        XCTAssertEqual(object["kind"] as? String, "sampleEncodingError")
        XCTAssertEqual(
            object["id"] as? String,
            failureID.uuidString.lowercased()
        )
        XCTAssertEqual(
            object["canonicalId"] as? String,
            "apple.healthkit:\(failureID.uuidString.lowercased())"
        )
        XCTAssertEqual(
            object["parentCanonicalId"] as? String,
            "apple.healthkit:\(id.uuidString.lowercased())"
        )
        XCTAssertEqual(object["recordVersion"] as? Int, 1)
    }
}
