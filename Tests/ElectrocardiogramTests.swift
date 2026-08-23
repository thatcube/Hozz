import Foundation
import HozzAcquire
import HozzCatalog
import HozzCore
import HozzStore
import XCTest
@testable import HozzHealth

/// An ECG backend with fixed recordings, so the ECG-specific shaping can be
/// checked without an Apple Watch. The paging itself is the shared
/// ``SeriesReader``, exercised in depth by the workout route tests.
private actor FakeECGBackend: SeriesBackend {
    struct Recording {
        let id: UUID
        let start: Date
        let voltages: [ECGVoltage]
        let classification: ECGClassification
        let symptoms: ECGClassification
        let averageHeartRate: Double?
        let samplingFrequency: Double?
        /// What Health says the recording holds, which is not always what it
        /// hands over.
        let reportedCount: Int
        let batchSize: Int
    }

    private let recordings: [Recording]

    init(recordings: [Recording]) {
        self.recordings = recordings
    }

    func nextPage(after anchor: Data?) async throws -> SeriesPage {
        let offset = anchor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        guard offset < recordings.count else {
            return SeriesPage(
                header: nil,
                deletions: [],
                anchor: Data(String(offset).utf8)
            )
        }

        let recording = recordings[offset]
        let base = try JSONSerialization.data(
            withJSONObject: [
                "startDate": ECGFixtures.timestamp(recording.start),
                "endDate": ECGFixtures.timestamp(
                    recording.start.addingTimeInterval(30)
                ),
                "metadata": [:],
                "source": ["name": "Apple Watch", "bundleIdentifier": "com.apple.health"]
            ] as [String: Any],
            options: [.sortedKeys]
        )

        return SeriesPage(
            header: SeriesHeader(
                id: recording.id,
                startDate: recording.start,
                endDate: recording.start.addingTimeInterval(30),
                basePayload: try ElectrocardiogramEncoding.basePayload(
                    base,
                    classification: recording.classification,
                    symptomsStatus: recording.symptoms,
                    averageHeartRate: recording.averageHeartRate,
                    samplingFrequencyHertz: recording.samplingFrequency,
                    numberOfVoltageMeasurements: recording.reportedCount
                )
            ),
            deletions: [],
            anchor: Data(String(offset + 1).utf8)
        )
    }

    func facts(id: UUID) async throws -> SeriesFacts? {
        guard let recording = recordings.first(where: { $0.id == id }) else {
            return nil
        }
        return SeriesFacts(
            startDate: recording.start,
            endDate: recording.start.addingTimeInterval(30)
        )
    }

    nonisolated func elements(
        for id: UUID
    ) -> AsyncThrowingStream<[ECGVoltage], any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.deliver(id, to: continuation)
            }
        }
    }

    private func deliver(
        _ id: UUID,
        to continuation: AsyncThrowingStream<[ECGVoltage], any Error>.Continuation
    ) {
        guard let recording = recordings.first(where: { $0.id == id }) else {
            continuation.finish()
            return
        }
        var index = 0
        while index < recording.voltages.count {
            let end = min(index + recording.batchSize, recording.voltages.count)
            continuation.yield(Array(recording.voltages[index..<end]))
            index = end
        }
        continuation.finish()
    }
}

private enum ECGFixtures {
    static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
    }
}

final class ElectrocardiogramTests: XCTestCase {
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

    private func voltages(
        _ count: Int,
        samplingFrequency: Double = 512,
        gapEvery: Int? = nil
    ) -> [ECGVoltage] {
        (0..<count).map { index in
            let seconds = Double(index) / samplingFrequency
            let isGap = gapEvery.map { index % $0 == 0 } ?? false
            return ECGVoltage(
                timeSinceStart: seconds,
                volts: isGap ? nil : 0.000_1 * Double(index % 100),
                timestamp: start.addingTimeInterval(seconds)
            )
        }
    }

    private func recording(
        id: UUID = UUID(),
        count: Int,
        reportedCount: Int? = nil,
        classification: ECGClassification = ECGClassification(
            name: "sinusRhythm",
            rawValue: 1
        ),
        symptoms: ECGClassification = ECGClassification(
            name: "none",
            rawValue: 1
        ),
        averageHeartRate: Double? = 62,
        samplingFrequency: Double? = 512,
        gapEvery: Int? = nil,
        batchSize: Int = 256
    ) -> FakeECGBackend.Recording {
        FakeECGBackend.Recording(
            id: id,
            start: start,
            voltages: voltages(count, gapEvery: gapEvery),
            classification: classification,
            symptoms: symptoms,
            averageHeartRate: averageHeartRate,
            samplingFrequency: samplingFrequency,
            reportedCount: reportedCount ?? count,
            batchSize: batchSize
        )
    }

    private func drainAll(
        _ reader: SeriesReader<FakeECGBackend>
    ) async throws -> [[String: Any]] {
        var anchor: AnchorToken?
        var records: [[String: Any]] = []
        var queries = 0

        while queries < 5_000 {
            let batch = try await reader.changes(after: anchor, limit: 1_000)
            queries += 1
            if batch.changes.isEmpty {
                return records
            }
            for change in batch.changes {
                guard case .upsert(let object) = change else {
                    continue
                }
                guard
                    let parsed = try JSONSerialization.jsonObject(
                        with: object.canonicalPayload
                    ) as? [String: Any]
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                records.append(parsed)
            }
            anchor = batch.proposedAnchor
        }
        XCTFail("The ECG drain never reached an empty page.")
        return records
    }

    private func readings(in records: [[String: Any]]) -> [[String: Any]] {
        records
            .filter { $0["kind"] as? String == "electrocardiogramVoltages" }
            .flatMap { $0["voltages"] as? [[String: Any]] ?? [] }
    }

    // MARK: - Completeness

    func testEveryVoltageIsWrittenOnceAndInOrder() async throws {
        let count = 15_360
        let backend = FakeECGBackend(recordings: [recording(count: count)])
        let reader = SeriesReader(
            shape: ElectrocardiogramEncoding.shape,
            backend: backend
        )

        let records = try await drainAll(reader)
        let points = readings(in: records)

        XCTAssertEqual(points.count, count)
        XCTAssertEqual(
            points.compactMap { $0["timeSinceStart"] as? Double },
            (0..<count).map { Double($0) / 512 },
            "A recording read out of order is not a heartbeat any more."
        )
    }

    func testARecordingIsWrittenAsAHeaderPagesAndAnEnd() async throws {
        let backend = FakeECGBackend(recordings: [recording(count: 1_001)])
        let reader = SeriesReader(
            shape: ElectrocardiogramEncoding.shape,
            backend: backend
        )

        let kinds = try await drainAll(reader).compactMap { $0["kind"] as? String }

        XCTAssertEqual(kinds.first, "electrocardiogram")
        XCTAssertEqual(kinds.last, "electrocardiogramEnd")
        XCTAssertEqual(kinds.filter { $0 == "electrocardiogramVoltages" }.count, 3)
    }

    /// Health reports how many readings a recording holds. Writing that number
    /// beside the number actually exported is what makes a short read visible
    /// instead of looking complete.
    func testTheExportedCountIsKeptBesideTheCountHealthReported() async throws {
        let backend = FakeECGBackend(
            recordings: [recording(count: 900, reportedCount: 1_000)]
        )
        let reader = SeriesReader(
            shape: ElectrocardiogramEncoding.shape,
            backend: backend
        )

        let records = try await drainAll(reader)
        let header = try XCTUnwrap(
            records.first { $0["kind"] as? String == "electrocardiogram" }
        )
        let end = try XCTUnwrap(
            records.first { $0["kind"] as? String == "electrocardiogramEnd" }
        )

        XCTAssertEqual(header["numberOfVoltageMeasurements"] as? Int, 1_000)
        XCTAssertEqual(end["voltages"] as? Int, 900)
    }

    func testResumingMidRecordingNeitherRepeatsNorSkipsAReading() async throws {
        let id = UUID()
        let count = ElectrocardiogramEncoding.shape.elementsPerPage * 2 + 137
        let backend = FakeECGBackend(
            recordings: [recording(id: id, count: count, batchSize: 97)]
        )

        let first = SeriesReader(
            shape: ElectrocardiogramEncoding.shape,
            backend: backend
        )
        var anchor: AnchorToken?
        var records: [[String: Any]] = []
        for _ in 0..<2 {
            let batch = try await first.changes(after: anchor, limit: 1_000)
            for change in batch.changes {
                guard case .upsert(let object) = change else {
                    continue
                }
                records.append(
                    try JSONSerialization.jsonObject(
                        with: object.canonicalPayload
                    ) as? [String: Any] ?? [:]
                )
            }
            anchor = batch.proposedAnchor
        }
        let carried = try SeriesAnchor.decode(anchor)
        XCTAssertEqual(carried.pendingSample, id)
        XCTAssertGreaterThan(carried.deliveredElements, 0)

        // A fresh reader over the same cursor is what relaunching looks like.
        let second = SeriesReader(
            shape: ElectrocardiogramEncoding.shape,
            backend: backend
        )
        while true {
            let batch = try await second.changes(after: anchor, limit: 1_000)
            if batch.changes.isEmpty {
                break
            }
            for change in batch.changes {
                guard case .upsert(let object) = change else {
                    continue
                }
                records.append(
                    try JSONSerialization.jsonObject(
                        with: object.canonicalPayload
                    ) as? [String: Any] ?? [:]
                )
            }
            anchor = batch.proposedAnchor
        }

        let points = readings(in: records)
        XCTAssertEqual(points.count, count, "No reading may be skipped.")
        XCTAssertEqual(
            points.compactMap { $0["timeSinceStart"] as? Double },
            (0..<count).map { Double($0) / 512 },
            "No reading may be written twice or out of order."
        )
    }

    // MARK: - Honest shaping

    func testAReadingWithNoVoltageIsAGapRatherThanAZero() async throws {
        let backend = FakeECGBackend(
            recordings: [recording(count: 20, gapEvery: 5)]
        )
        let reader = SeriesReader(
            shape: ElectrocardiogramEncoding.shape,
            backend: backend
        )

        let points = readings(in: try await drainAll(reader))

        XCTAssertEqual(points.count, 20)
        XCTAssertEqual(
            points.filter { $0["volts"] == nil }.count,
            4,
            "A lead that reported nothing is not a reading of zero volts."
        )
        XCTAssertEqual(
            points.filter { ($0["volts"] as? Double) != nil }.count,
            16
        )
    }

    func testTheHeaderCarriesWhatMakesARecordingReadable() async throws {
        let backend = FakeECGBackend(
            recordings: [
                recording(
                    count: 10,
                    classification: ECGClassification(
                        name: "atrialFibrillation",
                        rawValue: 2
                    ),
                    symptoms: ECGClassification(name: "present", rawValue: 2),
                    averageHeartRate: 121,
                    samplingFrequency: 512.4
                )
            ]
        )
        let reader = SeriesReader(
            shape: ElectrocardiogramEncoding.shape,
            backend: backend
        )

        let records = try await drainAll(reader)
        let header = try XCTUnwrap(
            records.first { $0["kind"] as? String == "electrocardiogram" }
        )

        let classification = try XCTUnwrap(
            header["classification"] as? [String: Any]
        )
        XCTAssertEqual(classification["name"] as? String, "atrialFibrillation")
        XCTAssertEqual(
            classification["rawValue"] as? Int,
            2,
            "A classification from a newer OS must still be readable as a number."
        )

        let symptoms = try XCTUnwrap(header["symptomsStatus"] as? [String: Any])
        XCTAssertEqual(symptoms["name"] as? String, "present")

        let heartRate = try XCTUnwrap(header["averageHeartRate"] as? [String: Any])
        XCTAssertEqual(heartRate["value"] as? Double, 121)
        XCTAssertEqual(heartRate["unit"] as? String, "count/min")

        let frequency = try XCTUnwrap(header["samplingFrequency"] as? [String: Any])
        XCTAssertEqual(frequency["value"] as? Double, 512.4)
        XCTAssertEqual(frequency["unit"] as? String, "Hz")
    }

    func testAnAbsentHeartRateIsLeftOutRatherThanWrittenAsZero() async throws {
        let backend = FakeECGBackend(
            recordings: [
                recording(count: 10, averageHeartRate: nil, samplingFrequency: nil)
            ]
        )
        let reader = SeriesReader(
            shape: ElectrocardiogramEncoding.shape,
            backend: backend
        )

        let records = try await drainAll(reader)
        let header = try XCTUnwrap(
            records.first { $0["kind"] as? String == "electrocardiogram" }
        )

        XCTAssertNil(
            header["averageHeartRate"],
            "An average heart rate of zero is not a measurement."
        )
        XCTAssertNil(header["samplingFrequency"])
        XCTAssertNotNil(header["classification"])
    }

    func testEveryECGRecordCarriesDatesTheReceiverNeeds() async throws {
        let backend = FakeECGBackend(recordings: [recording(count: 600)])
        let reader = SeriesReader(
            shape: ElectrocardiogramEncoding.shape,
            backend: backend
        )

        for record in try await drainAll(reader) {
            XCTAssertNotNil(
                record["startDate"] as? String,
                "A record with no dates is counted as unreadable by the receiver."
            )
            XCTAssertNotNil(record["endDate"] as? String)
            XCTAssertEqual(
                record["type"] as? String,
                ElectrocardiogramEncoding.typeIdentifier
            )
        }
    }

    // MARK: - Through an export

    private struct ECGOnlySource: HealthDataSource {
        let reader: SeriesReader<FakeECGBackend>

        func changes(
            for type: HealthTypeKey,
            after anchor: AnchorToken?,
            limit: Int
        ) async throws -> HealthChangeBatch {
            try await reader.changes(after: anchor, limit: limit)
        }
    }

    func testAnExportCarriesEveryReadingOfEveryRecording() async throws {
        let store = try makeStore()
        let backend = FakeECGBackend(
            recordings: [recording(count: 900), recording(count: 1_100)]
        )
        let engine = HealthExportEngine(
            store: store,
            source: ECGOnlySource(
                reader: SeriesReader(
                    shape: ElectrocardiogramEncoding.shape,
                    backend: backend
                )
            ),
            types: [ElectrocardiogramEncoding.typeKey],
            lease: ExportWriterLease()
        )

        let outcome = try await engine.export(format: .ndjson) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        let records = try ExportArtifactReader.records(in: result.fileURL)
        XCTAssertEqual(readings(in: records).count, 2_000)
        XCTAssertEqual(
            records.filter { $0["kind"] as? String == "electrocardiogram" }.count,
            2
        )
        XCTAssertEqual(
            records.filter { $0["kind"] as? String == "electrocardiogramEnd" }.count,
            2
        )
    }

    func testCSVKeepsOneReadingPerRow() async throws {
        let store = try makeStore()
        let id = UUID()
        let backend = FakeECGBackend(
            recordings: [recording(id: id, count: 750, reportedCount: 800)]
        )
        let engine = HealthExportEngine(
            store: store,
            source: ECGOnlySource(
                reader: SeriesReader(
                    shape: ElectrocardiogramEncoding.shape,
                    backend: backend
                )
            ),
            types: [ElectrocardiogramEncoding.typeKey],
            lease: ExportWriterLease()
        )

        let outcome = try await engine.export(format: .csv) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }
        let entries = try ExportArtifactReader.readZipEntries(at: result.fileURL)

        let voltagesCSV = try XCTUnwrap(entries["ElectrocardiogramVoltages.csv"])
        let rows = String(decoding: voltagesCSV, as: UTF8.self)
            .split(separator: "\n")
        XCTAssertEqual(rows.count, 751, "Every reading needs its own row.")
        XCTAssertTrue(
            rows[0].hasPrefix("electrocardiogram,sequence,offset,timestamp,timeSinceStart,volts")
        )

        let summaryCSV = try XCTUnwrap(entries["Electrocardiograms.csv"])
        let summaryRows = String(decoding: summaryCSV, as: UTF8.self)
            .split(separator: "\n")
        XCTAssertEqual(summaryRows.count, 2)
        let fields = summaryRows[1].split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertTrue(summaryRows[1].contains(id.uuidString.lowercased()))
        XCTAssertTrue(
            fields.contains("800") && fields.contains("750"),
            "The reported and exported counts both belong in the row, so a short read shows."
        )
    }

    // MARK: - Catalog and registry

    func testTheECGTypeIsCataloguedAndExportable() {
        let entry = HealthTypeCatalog.entriesByIdentifier[
            ElectrocardiogramEncoding.typeIdentifier
        ]

        XCTAssertEqual(entry?.family, .series)
        XCTAssertEqual(entry?.displayName, "Electrocardiogram")
        XCTAssertTrue(
            HealthKitTypeRegistry.exportableTypes().contains {
                $0.catalogEntry.key == ElectrocardiogramEncoding.typeKey
            },
            "An ECG Hozz can read must be one it offers."
        )
    }

    func testTheTwoSeriesTypesDoNotShareIdentifiers() {
        let sample = UUID()

        let route = SeriesEncoding.identifier(
            shape: WorkoutRouteEncoding.shape,
            sample: sample,
            suffix: "locations-0"
        )
        let ecg = SeriesEncoding.identifier(
            shape: ElectrocardiogramEncoding.shape,
            sample: sample,
            suffix: "locations-0"
        )

        XCTAssertNotEqual(
            route,
            ecg,
            "Two series types must never collide on a derived identifier."
        )
    }
}
