import Foundation
import HealthKit
import HozzAcquire
import HozzCatalog
import HozzCore
import HozzHealthFake
import HozzStore
import XCTest
@testable import HozzHealth

/// Audiograms are ordinary anchored samples, so these tests are about the
/// shape of a hearing test rather than about paging: an ear with nothing
/// recorded, and a reading Health says is clamped, both have to survive as
/// what they are.
final class AudiogramTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private func hertz(_ value: Double) -> HKQuantity {
        HKQuantity(unit: .hertz(), doubleValue: value)
    }

    private func decibels(_ value: Double) -> HKQuantity {
        HKQuantity(unit: .decibelHearingLevel(), doubleValue: value)
    }

    private var catalogEntry: HealthCatalogEntry {
        get throws {
            try XCTUnwrap(
                HealthTypeCatalog.entriesByIdentifier[
                    AudiogramEncoding.typeIdentifier
                ]
            )
        }
    }

    private func encode(
        _ sample: HKAudiogramSample
    ) throws -> [String: Any] {
        let data = try HealthSampleEncoder().encode(
            sample: sample,
            catalogEntry: try catalogEntry
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: - Shape

    func testAHearingTestKeepsEveryFrequencyAndEar() throws {
        try XCTSkipUnless(
            isModernAudiogramAPIAvailable,
            "Building sensitivity tests needs iOS 18.1 or newer."
        )
        let sample = try makeSample(
            frequencies: [250, 500, 1_000, 2_000, 4_000, 8_000]
        )

        let object = try encode(sample)
        let points = try XCTUnwrap(
            object["sensitivityPoints"] as? [[String: Any]]
        )

        XCTAssertEqual(object["kind"] as? String, "audiogram")
        XCTAssertEqual(points.count, 6)
        XCTAssertEqual(
            points.compactMap {
                ($0["frequency"] as? [String: Any])?["value"] as? Double
            },
            [250, 500, 1_000, 2_000, 4_000, 8_000],
            "Frequencies must stay in the order and the values Health gave them."
        )
        for point in points {
            let ears = try XCTUnwrap(point["ears"] as? [[String: Any]])
            XCTAssertEqual(Set(ears.compactMap { $0["ear"] as? String }), ["left", "right"])
            XCTAssertEqual(
                (ears[0]["sensitivity"] as? [String: Any])?["unit"] as? String,
                "dBHL"
            )
        }
    }

    func testAnEarWithNothingRecordedProducesNoReadingRatherThanZero() throws {
        try XCTSkipUnless(
            isModernAudiogramAPIAvailable,
            "Building sensitivity tests needs iOS 18.1 or newer."
        )
        guard #available(iOS 18.1, *) else {
            return
        }
        // Only the left ear was measured at this frequency.
        let point = try XCTUnwrap(
            try? HKAudiogramSensitivityPoint(
                frequency: hertz(1_000),
                tests: [
                    HKAudiogramSensitivityTest(
                        sensitivity: decibels(30),
                        type: .air,
                        masked: false,
                        side: .left,
                        clampingRange: nil
                    )
                ]
            )
        )
        let sample = HKAudiogramSample(
            sensitivityPoints: [point],
            start: start,
            end: start.addingTimeInterval(120),
            device: nil,
            metadata: nil
        )

        let object = try encode(sample)
        let points = try XCTUnwrap(
            object["sensitivityPoints"] as? [[String: Any]]
        )
        let ears = try XCTUnwrap(points[0]["ears"] as? [[String: Any]])

        XCTAssertEqual(ears.count, 1)
        XCTAssertEqual(ears[0]["ear"] as? String, "left")
        XCTAssertFalse(
            ears.contains { $0["ear"] as? String == "right" },
            "An unmeasured ear is unknown, and 0 dB would read as perfect hearing."
        )
    }

    func testAClampedReadingIsReportedAsABoundRatherThanAValue() throws {
        try XCTSkipUnless(
            isModernAudiogramAPIAvailable,
            "Building sensitivity tests needs iOS 18.1 or newer."
        )
        guard #available(iOS 18.1, *) else {
            return
        }
        let clamping = try XCTUnwrap(
            try? HKAudiogramSensitivityPointClampingRange(
                lowerBound: nil,
                upperBound: 90
            )
        )
        let point = try XCTUnwrap(
            try? HKAudiogramSensitivityPoint(
                frequency: hertz(8_000),
                tests: [
                    HKAudiogramSensitivityTest(
                        sensitivity: decibels(90),
                        type: .air,
                        masked: true,
                        side: .right,
                        clampingRange: clamping
                    )
                ]
            )
        )
        let sample = HKAudiogramSample(
            sensitivityPoints: [point],
            start: start,
            end: start.addingTimeInterval(120),
            device: nil,
            metadata: nil
        )

        let object = try encode(sample)
        let points = try XCTUnwrap(
            object["sensitivityPoints"] as? [[String: Any]]
        )
        let ear = try XCTUnwrap((points[0]["ears"] as? [[String: Any]])?.first)
        let range = try XCTUnwrap(ear["clampingRange"] as? [String: Any])

        XCTAssertEqual(ear["masked"] as? Bool, true)
        XCTAssertEqual(ear["conduction"] as? String, "air")
        XCTAssertEqual(
            (range["upperBound"] as? [String: Any])?["value"] as? Double,
            90,
            "A clamped 90 dB means at least 90, and losing the bound loses that."
        )
        XCTAssertNil(
            range["lowerBound"],
            "A bound Health did not give must not be invented."
        )
    }

    func testTheEncodingIsStableForTheSameHearingTest() throws {
        try XCTSkipUnless(
            isModernAudiogramAPIAvailable,
            "Building sensitivity tests needs iOS 18.1 or newer."
        )
        let sample = try makeSample(frequencies: [500, 1_000])
        let encoder = HealthSampleEncoder()

        let first = try encoder.encode(sample: sample, catalogEntry: try catalogEntry)
        let second = try encoder.encode(sample: sample, catalogEntry: try catalogEntry)

        XCTAssertEqual(
            first,
            second,
            "The same hearing test must always encode to the same bytes."
        )
    }

    // MARK: - Through an export

    func testAnExportCarriesAHearingTestWholeAndAsAGrid() async throws {
        try XCTSkipUnless(
            isModernAudiogramAPIAvailable,
            "Building sensitivity tests needs iOS 18.1 or newer."
        )
        let store = try makeStore()
        let sample = try makeSample(frequencies: [250, 500, 1_000])
        let payload = try HealthSampleEncoder().encode(
            sample: sample,
            catalogEntry: try catalogEntry
        )
        let source = ScriptedHealthDataSource(
            streams: [
                AudiogramEncoding.typeKey: [
                    .upsert(
                        CapturedHealthObject(
                            id: sample.uuid,
                            type: AudiogramEncoding.typeKey,
                            canonicalPayload: payload
                        )
                    )
                ]
            ]
        )
        let engine = HealthExportEngine(
            store: store,
            source: source,
            types: [AudiogramEncoding.typeKey],
            lease: ExportWriterLease()
        )

        let outcome = try await engine.export(format: .csv) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }
        let entries = try ExportArtifactReader.readZipEntries(at: result.fileURL)

        let csv = try XCTUnwrap(entries["Audiograms.csv"])
        let rows = String(decoding: csv, as: UTF8.self).split(separator: "\n")
        XCTAssertTrue(rows[0].hasPrefix("audiogram,startDate,endDate,frequencyHz,ear"))
        XCTAssertEqual(
            rows.count,
            7,
            "Three frequencies across two ears is six readings, plus the header."
        )
        XCTAssertTrue(rows[1].contains(sample.uuid.uuidString.lowercased()))
    }

    // MARK: - Catalog and registry

    func testTheAudiogramTypeIsCataloguedAndExportable() throws {
        let entry = try catalogEntry

        XCTAssertEqual(entry.family, .audiogram)
        XCTAssertEqual(entry.displayName, "Audiogram")
        XCTAssertTrue(
            HealthKitTypeRegistry.exportableTypes().contains {
                $0.catalogEntry.key == AudiogramEncoding.typeKey
            },
            "A hearing test Hozz can read must be one it offers."
        )
        XCTAssertTrue(
            HealthKitTypeRegistry.authorizationReadTypes().contains(
                HKObjectType.audiogramSampleType()
            ),
            "A type Hozz reads must also be one it asked for."
        )
    }

    // MARK: - Helpers

    private var isModernAudiogramAPIAvailable: Bool {
        if #available(iOS 18.1, *) {
            return true
        }
        return false
    }

    private func makeSample(
        frequencies: [Double]
    ) throws -> HKAudiogramSample {
        guard #available(iOS 18.1, *) else {
            throw XCTSkip("Building sensitivity tests needs iOS 18.1 or newer.")
        }
        let points = try frequencies.enumerated().map { index, frequency in
            try XCTUnwrap(
                try? HKAudiogramSensitivityPoint(
                    frequency: hertz(frequency),
                    tests: [
                        HKAudiogramSensitivityTest(
                            sensitivity: decibels(Double(10 + index * 5)),
                            type: .air,
                            masked: false,
                            side: .left,
                            clampingRange: nil
                        ),
                        HKAudiogramSensitivityTest(
                            sensitivity: decibels(Double(15 + index * 5)),
                            type: .air,
                            masked: false,
                            side: .right,
                            clampingRange: nil
                        )
                    ]
                )
            )
        }
        return HKAudiogramSample(
            sensitivityPoints: points,
            start: start,
            end: start.addingTimeInterval(120),
            device: nil,
            metadata: nil
        )
    }
}
