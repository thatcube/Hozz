import Foundation
import HozzMCP
@testable import HozzReceive
import XCTest

/// ECG readings and hearing tests are not ordinary samples, and storing them
/// as though they were produced answers that were wrong rather than merely
/// unhelpful: one reading counted as two, an aggregate that reported no
/// records for data sitting in the table, and a classification of
/// `atrialFibrillation` that nothing could see.
final class ReceiverSeriesTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> IngestStore {
        try IngestStore(directory: directory.url.appending(path: "store"))
    }

    // MARK: - The shapes the phone writes

    private func header(expecting measurements: Int = 4) -> [String: Any] {
        [
            "kind": "electrocardiogram", "schemaVersion": 1,
            "id": "ecg-1", "type": "HKDataTypeIdentifierElectrocardiogram",
            "startDate": "2026-01-02T15:00:00.000Z",
            "endDate": "2026-01-02T15:00:30.000Z",
            "classification": ["name": "atrialFibrillation", "rawValue": 2],
            "symptomsStatus": ["name": "present", "rawValue": 2],
            "numberOfVoltageMeasurements": measurements,
            "averageHeartRate": ["unit": "count/min", "value": 122.0],
            "samplingFrequency": ["unit": "Hz", "value": 512.0],
            "source": ["name": "Apple Watch", "bundleIdentifier": "com.apple.health"]
        ]
    }

    private func page(
        _ sequence: Int,
        offset: Int,
        points: [(Double, Double)]
    ) -> [String: Any] {
        [
            "kind": "electrocardiogramVoltages", "schemaVersion": 1,
            "id": "ecg-1-voltages-\(sequence)",
            "type": "HKDataTypeIdentifierElectrocardiogram",
            "sample": "ecg-1", "sequence": sequence, "offset": offset,
            "count": points.count,
            "startDate": "2026-01-02T15:00:00.000Z",
            "endDate": "2026-01-02T15:00:01.000Z",
            "voltages": points.map {
                ["timeSinceStart": $0.0, "volts": $0.1]
            }
        ]
    }

    private func audiogram() -> [String: Any] {
        [
            "kind": "audiogram", "schemaVersion": 1, "id": "audio-1",
            "type": "HKDataTypeIdentifierAudiogram",
            "startDate": "2026-02-01T10:00:00.000Z",
            "endDate": "2026-02-01T10:05:00.000Z",
            "source": ["name": "Mimi"],
            "sensitivityPoints": [
                [
                    "frequency": ["unit": "Hz", "value": 1_000.0],
                    "ears": [
                        [
                            "ear": "left",
                            "sensitivity": ["unit": "dBHL", "value": 15.0],
                            "masked": false
                        ],
                        [
                            "ear": "right",
                            "sensitivity": ["unit": "dBHL", "value": 90.0],
                            "masked": false,
                            "clampingRange": ["lowerBound": ["unit": "dBHL", "value": 90.0]]
                        ]
                    ]
                ]
            ]
        ]
    }

    private func deliver(
        _ objects: [[String: Any]],
        to store: IngestStore,
        key: String = UUID().uuidString
    ) async throws -> IngestResult {
        var data = Data()
        for object in objects {
            data.append(
                try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            )
            data.append(0x0A)
        }
        return try await store.ingest(
            try BatchParser.parse(data),
            idempotencyKey: key
        )
    }

    // MARK: - Counting

    /// The bug this work exists to fix: a reading plus its pages counted as
    /// several readings, and the classification was nowhere.
    func testAReadingAndItsPagesAreOneReadingNotSeveralSamples() async throws {
        let store = try makeStore()
        _ = try await deliver(
            [
                header(),
                page(0, offset: 0, points: [(0.0, 0.0001), (0.002, 0.00013)]),
                page(1, offset: 2, points: [(0.004, 0.0002), (0.006, 0.00021)])
            ],
            to: store
        )

        let readings = try await store.electrocardiograms()
        XCTAssertEqual(readings.count, 1, "One reading, not one per page.")
        XCTAssertEqual(readings.first?.classification, "atrialFibrillation")
        XCTAssertEqual(readings.first?.symptomsStatus, "present")
        XCTAssertEqual(readings.first?.averageHeartRate, 122)
        XCTAssertEqual(readings.first?.samplingHertz, 512)

        let strays = try await store.totalRecordCount()
        XCTAssertEqual(
            strays,
            0,
            "An ECG must not also appear as generic samples, or every count lies."
        )
    }

    // MARK: - Reassembly

    /// Pages may arrive in any order and more than once. Neither may change
    /// the waveform.
    func testPagesOutOfOrderAndDuplicatedStillGiveOneCorrectWaveform() async throws {
        let store = try makeStore()
        _ = try await deliver(
            [
                page(1, offset: 2, points: [(0.004, 0.0002), (0.006, 0.00021)]),
                header(),
                page(0, offset: 0, points: [(0.0, 0.0001), (0.002, 0.00013)]),
                // The same page again, byte-identical, as a replay would send.
                page(1, offset: 2, points: [(0.004, 0.0002), (0.006, 0.00021)])
            ],
            to: store
        )

        let waveform = try await store.voltages(forElectrocardiogram: "ecg-1")
        XCTAssertEqual(waveform.points.count, 4, "A replayed page must not duplicate points.")
        XCTAssertEqual(
            waveform.points.map(\.secondsSinceStart),
            [0.0, 0.002, 0.004, 0.006],
            "Points are ordered by offset, not by arrival."
        )
        XCTAssertTrue(waveform.isComplete)
    }

    /// The rule that matters clinically: a waveform still arriving must never
    /// be presented as a whole recording.
    func testAWaveformMissingAPageIsNeverReportedAsComplete() async throws {
        let store = try makeStore()
        _ = try await deliver(
            [
                header(expecting: 6),
                page(0, offset: 0, points: [(0.0, 0.0001), (0.002, 0.00013)]),
                // Page 1 never arrives.
                page(2, offset: 4, points: [(0.008, 0.0003), (0.010, 0.00031)])
            ],
            to: store
        )

        let waveform = try await store.voltages(forElectrocardiogram: "ecg-1")
        XCTAssertEqual(waveform.points.count, 4)
        XCTAssertEqual(waveform.expected, 6)
        XCTAssertFalse(
            waveform.isComplete,
            "A gap between pages makes this a partial trace, whatever its length."
        )

        let readings = try await store.electrocardiograms()
        XCTAssertFalse(readings.first?.isComplete ?? true)
    }

    /// When the Watch never said how many measurements to expect, completeness
    /// is unknown — which is not the same as complete.
    func testAnUnknownExpectedCountIsNotTreatedAsComplete() async throws {
        let store = try makeStore()
        var incomplete = header()
        incomplete["numberOfVoltageMeasurements"] = nil
        _ = try await deliver(
            [
                incomplete.compactMapValues { $0 },
                page(0, offset: 0, points: [(0.0, 0.0001)])
            ],
            to: store
        )

        let readings = try await store.electrocardiograms()
        XCTAssertFalse(
            readings.first?.isComplete ?? true,
            "Not knowing how much to expect is not evidence of having it all."
        )
    }

    // MARK: - Hearing tests

    func testAHearingTestKeepsAThresholdPerFrequencyAndEar() async throws {
        let store = try makeStore()
        _ = try await deliver([audiogram()], to: store)

        let tests = try await store.audiograms()
        XCTAssertEqual(tests.count, 1)
        XCTAssertEqual(tests.first?.points.count, 2)

        let left = try XCTUnwrap(tests.first?.points.first { $0.ear == "left" })
        XCTAssertEqual(left.frequency, 1_000)
        XCTAssertEqual(left.sensitivity, 15)
        XCTAssertEqual(left.unit, "dBHL")
        XCTAssertFalse(left.clamped)

        // A clamped reading is a bound, not a measurement.
        let right = try XCTUnwrap(tests.first?.points.first { $0.ear == "right" })
        XCTAssertTrue(
            right.clamped,
            "At least 90 dB and exactly 90 dB are different claims."
        )
    }

    // MARK: - What an assistant sees

    private func call(
        _ server: MCPServer,
        _ name: String,
        _ arguments: [String: Any] = [:]
    ) async throws -> String {
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ]
        let payload = try JSONSerialization.data(withJSONObject: message)
        let response = await server.handle(payload)
        let reply = try XCTUnwrap(response)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        )
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    func testAnAssistantCanSeeTheClassificationAndTheWaveform() async throws {
        let store = try makeStore()
        _ = try await deliver(
            [
                header(),
                page(0, offset: 0, points: [(0.0, 0.0001), (0.002, 0.00013)]),
                page(1, offset: 2, points: [(0.004, 0.0002), (0.006, 0.00021)])
            ],
            to: store
        )
        let server = MCPServer(store: store)

        let listing = try await call(server, "list_electrocardiograms")
        XCTAssertTrue(listing.contains("1 ECG reading."), listing)
        XCTAssertTrue(
            listing.contains("atrialFibrillation"),
            "The classification is the whole point of an ECG: \(listing)"
        )
        XCTAssertTrue(listing.contains("complete (4 points)"), listing)

        let waveform = try await call(
            server,
            "get_electrocardiogram_voltages",
            ["id": "ecg-1"]
        )
        XCTAssertTrue(waveform.hasPrefix("Complete recording: 4 points."), waveform)
        XCTAssertTrue(waveform.contains("0.0000, 0.0001000"), waveform)
    }

    func testAnIncompleteWaveformSaysSoLoudly() async throws {
        let store = try makeStore()
        _ = try await deliver(
            [
                header(expecting: 6),
                page(0, offset: 0, points: [(0.0, 0.0001), (0.002, 0.00013)])
            ],
            to: store
        )
        let server = MCPServer(store: store)

        let waveform = try await call(
            server,
            "get_electrocardiogram_voltages",
            ["id": "ecg-1"]
        )
        XCTAssertTrue(waveform.contains("INCOMPLETE"), waveform)
        XCTAssertTrue(
            waveform.contains("Do not read this as a whole trace."),
            waveform
        )
    }

    /// "No such reading" and "the waveform has not arrived" are different
    /// answers, and an assistant told only "empty" reports the wrong one.
    func testAMissingReadingIsDistinguishedFromAMissingWaveform() async throws {
        let store = try makeStore()
        _ = try await deliver([header()], to: store)
        let server = MCPServer(store: store)

        let noWaveform = try await call(
            server,
            "get_electrocardiogram_voltages",
            ["id": "ecg-1"]
        )
        XCTAssertTrue(noWaveform.contains("waveform has not"), noWaveform)

        let noReading = try await call(
            server,
            "get_electrocardiogram_voltages",
            ["id": "nope"]
        )
        XCTAssertTrue(noReading.contains("no ECG reading with id"), noReading)
    }

    /// A store holding only ECGs is not an empty store.
    func testTheOverviewNeverReportsNothingWhileHoldingAnECG() async throws {
        let store = try makeStore()
        _ = try await deliver([header(), audiogram()], to: store)
        let server = MCPServer(store: store)

        let summary = try await call(server, "summarise_health_data")
        XCTAssertFalse(
            summary.contains("No Health data has been received yet"),
            "An ECG had arrived, so this store is not empty: \(summary)"
        )
        XCTAssertTrue(summary.contains("1 ECG"), summary)
        XCTAssertTrue(summary.contains("hearing test"), summary)
    }

    func testAHearingTestReportsAClampedThresholdAsABound() async throws {
        let store = try makeStore()
        _ = try await deliver([audiogram()], to: store)
        let server = MCPServer(store: store)

        let listing = try await call(server, "list_audiograms")
        XCTAssertTrue(listing.contains("1000 Hz, left, 15 dBHL"), listing)
        XCTAssertTrue(
            listing.contains("at least 90"),
            "A clamped reading is a bound, not a measurement: \(listing)"
        )
    }
}
