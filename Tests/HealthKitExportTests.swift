import Foundation
import HealthKit
import HozzCatalog
import XCTest
import zlib
@testable import HozzHealth

final class HealthKitExportTests: XCTestCase {
    func testCatalogIdentifiersAreUnique() {
        let identifiers = HealthTypeCatalog.entries.map(\.key.rawValue)

        XCTAssertGreaterThan(identifiers.count, 200)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testCatalogEntryCreatesReadableDisplayName() throws {
        let entry = try XCTUnwrap(
            HealthTypeCatalog.entriesByIdentifier[
                "HKQuantityTypeIdentifierActiveEnergyBurned"
            ]
        )

        XCTAssertEqual(entry.displayName, "Active Energy Burned")
        XCTAssertEqual(
            HealthTypeCatalog.entriesByIdentifier[
                "HKQuantityTypeIdentifierVO2Max"
            ]?.displayName,
            "VO2 Max"
        )
        XCTAssertEqual(
            HealthTypeCatalog.entriesByIdentifier[
                "HKWorkoutTypeIdentifier"
            ]?.displayName,
            "Workout"
        )
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

    func testDeflateOutputRoundTripsStreamingData() throws {
        let source = Data(
            String(repeating: #"{"kind":"quantity","value":12345}"# + "\n", count: 10_000).utf8
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).deflate")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: nil))

        let output = try DeflateExportOutput(fileURL: fileURL)
        for (index, chunk) in source.chunks(ofCount: 1_024).enumerated() {
            try output.write(Data(chunk))
            if index.isMultiple(of: 100) {
                try output.synchronize()
                try output.synchronize()
            }
        }
        let summary = try output.finish()

        let stored = try Data(contentsOf: fileURL)
        let inflated = try ExportArtifactReader.inflateRaw(
            stored + Data(ZipStreamWriter.deflateTerminator)
        )

        XCTAssertLessThan(summary.compressedByteCount, UInt64(source.count / 10))
        XCTAssertEqual(summary.uncompressedByteCount, UInt64(source.count))
        XCTAssertEqual(summary.crc32, ExportArtifactReader.crc32(of: source))
        XCTAssertEqual(inflated, source)
    }

}

private extension Data {
    func chunks(ofCount count: Int) -> AnySequence<SubSequence> {
        AnySequence(
            sequence(
                state: startIndex
            ) { index -> SubSequence? in
                guard index < endIndex else {
                    return nil
                }
                let next = Swift.min(index + count, endIndex)
                defer { index = next }
                return self[index..<next]
            }
        )
    }
}
