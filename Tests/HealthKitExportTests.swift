import Foundation
import HealthKit
import HozzCatalog
import HozzHealth
import XCTest

final class HealthKitExportTests: XCTestCase {
    func testCatalogIdentifiersAreUnique() {
        let identifiers = HealthTypeCatalog.entries.map(\.key.rawValue)

        XCTAssertGreaterThan(identifiers.count, 200)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testRegistryResolvesStepCount() {
        let types = HealthKitTypeRegistry.exportableTypes()
        let identifiers = Set(types.map(\.catalogEntry.key.rawValue))

        XCTAssertTrue(identifiers.contains("HKQuantityTypeIdentifierStepCount"))
        XCTAssertTrue(identifiers.contains("HKWorkoutTypeIdentifier"))
        XCTAssertTrue(types.allSatisfy { !$0.sampleType.requiresPerObjectAuthorization() })
        XCTAssertTrue(
            HealthKitTypeRegistry.authorizationReadTypes()
                .allSatisfy { !($0 is HKCorrelationType) }
        )
    }

    func testQuantityEncodingUsesCatalogUnitAndIsDeterministic() throws {
        let identifier = "HKQuantityTypeIdentifierStepCount"
        let entry = try XCTUnwrap(
            HealthTypeCatalog.entriesByIdentifier[identifier]
        )
        let type = try XCTUnwrap(
            HKObjectType.quantityType(
                forIdentifier: HKQuantityTypeIdentifier(rawValue: identifier)
            )
        )
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .count(), doubleValue: 12_345),
            start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_000_060),
            metadata: [HKMetadataKeyWasUserEntered: true]
        )
        let encoder = HealthSampleEncoder()

        let first = try encoder.encode(sample: sample, catalogEntry: entry)
        let second = try encoder.encode(sample: sample, catalogEntry: entry)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: first) as? [String: Any]
        )
        let quantity = try XCTUnwrap(object["quantity"] as? [String: Any])

        XCTAssertEqual(first, second)
        XCTAssertEqual(object["kind"] as? String, "quantity")
        XCTAssertEqual(quantity["unit"] as? String, "count")
        XCTAssertEqual(quantity["value"] as? Double, 12_345)
    }
}
