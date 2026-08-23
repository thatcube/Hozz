import Foundation
@testable import HozzDeliver
import HozzStore
import XCTest

/// What happens to a stored destination when this build meets a word it does
/// not know.
///
/// Every payload here is hand-written, never produced by encoding today's
/// types. That distinction is the whole point: a round trip can only ever
/// contain values this build already understands, which is precisely the case
/// that was never in doubt. The bug this file exists for — a destination
/// vanishing from someone's list with no error — was invisible to a round-trip
/// test and took a hand-written payload to see.
final class UnknownSettingTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func payload(
        id: String = "8B2E7F6A-1C2D-4E5F-9A0B-1C2D3E4F5A6B",
        name: String = "My server",
        kind: String = "restAPI",
        format: String = "ndjson",
        cadence: String = "hourly",
        schema: String? = nil,
        options: String? = nil
    ) -> Data {
        var fields = """
        "id": "\(id)",
        "name": "\(name)",
        "kind": "\(kind)",
        "format": "\(format)",
        "cadence": "\(cadence)",
        "isEnabled": true,
        "headers": {"topic": "hozz"},
        "authorizationHeader": "Authorization",
        "includedTypes": [],
        "endpointURL": "https://example.com/health",
        "createdAt": 760000000
        """
        if let schema {
            fields += ",\n\"payloadSchema\": \"\(schema)\""
        }
        if let options {
            fields += ",\n\"options\": \(options)"
        }
        return Data("{\n\(fields)\n}".utf8)
    }

    private func decode(_ data: Data) throws -> Destination {
        try JSONDecoder().decode(Destination.self, from: data)
    }

    // MARK: - The record survives

    /// The failure this file exists for. Before the fix, each of these threw,
    /// was swallowed by the `try?` that loads destinations, and took the
    /// destination out of the user's list with nothing said.
    func testAnUnknownValueInAnyEnumNoLongerDeletesTheDestination() throws {
        let cases: [(String, Data)] = [
            ("format", payload(format: "parquet")),
            ("kind", payload(kind: "webdav")),
            ("cadence", payload(cadence: "weekly")),
            ("payloadSchema", payload(schema: "someFutureApp"))
        ]

        for (field, data) in cases {
            let destination = try decode(data)
            XCTAssertEqual(
                destination.name,
                "My server",
                "An unknown \(field) must not lose the destination."
            )
            XCTAssertFalse(
                destination.isUsable,
                "An unknown \(field) must not be treated as usable."
            )
            XCTAssertNotNil(destination.unsupportedDescription)
        }
    }

    func testTheRestOfTheDestinationIsStillReadable() throws {
        let destination = try decode(payload(format: "parquet"))

        XCTAssertEqual(destination.name, "My server")
        XCTAssertEqual(destination.kind, .restAPI)
        XCTAssertEqual(destination.cadence, .hourly)
        XCTAssertEqual(destination.headers["topic"], "hozz")
        XCTAssertEqual(
            destination.endpointURL?.absoluteString,
            "https://example.com/health"
        )
    }

    func testAKnownDestinationIsUnaffected() throws {
        let destination = try decode(payload(format: "metrics", schema: "healthAutoExport"))

        XCTAssertTrue(destination.isUsable)
        XCTAssertNil(destination.unsupportedDescription)
        XCTAssertEqual(destination.format, .metrics)
        XCTAssertEqual(destination.payloadSchema, .healthAutoExport)
    }

    /// A key that is simply absent is an older build, not a newer one, and has
    /// a right answer.
    func testAnAbsentKeyStillFallsBackWithoutBeingCalledUnsupported() throws {
        let older = Data(
            """
            {
              "id": "8B2E7F6A-1C2D-4E5F-9A0B-1C2D3E4F5A6B",
              "name": "My computer",
              "kind": "folder",
              "createdAt": 760000000
            }
            """.utf8
        )
        let destination = try decode(older)

        XCTAssertTrue(destination.isUsable, "Missing is not the same as unrecognised.")
        XCTAssertEqual(destination.format, .ndjson)
        XCTAssertEqual(destination.cadence, .whenDataArrives)
        XCTAssertEqual(destination.payloadSchema, .hozz)
    }

    // MARK: - The setting survives

    /// The half that makes keeping the record mean anything. Without it the
    /// first re-save would write the fallback over the user's real setting and
    /// the update that could have understood it would arrive too late.
    func testAnUnknownSettingIsWrittenBackUntouched() throws {
        let destination = try decode(payload(format: "parquet", cadence: "weekly"))

        let reEncoded = try JSONEncoder().encode(destination)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
        )

        XCTAssertEqual(object["format"] as? String, "parquet")
        XCTAssertEqual(object["cadence"] as? String, "weekly")
    }

    func testAnUnknownSettingSurvivesRepeatedRoundTrips() throws {
        var data = payload(kind: "webdav")
        for _ in 0..<3 {
            data = try JSONEncoder().encode(try decode(data))
        }
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            object["kind"] as? String,
            "webdav",
            "A build that cannot read a setting must not erode it either."
        )
    }

    func testAKnownDestinationRoundTripsUnchanged() throws {
        var destination = DestinationPreset.influxDB.makeDestination()
        destination.endpointURL = URL(string: "http://influx.local:8086/api/v2/write")
        destination.payloadSchema = .hozz

        let decoded = try JSONDecoder().decode(
            Destination.self,
            from: JSONEncoder().encode(destination)
        )
        XCTAssertEqual(decoded, destination)
        XCTAssertTrue(decoded.isUsable)
    }

    /// A destination saved by an older build must come back byte-comparable,
    /// not quietly rewritten into today's spelling.
    func testSavingADestinationThroughTheEngineKeepsTheUnknownSetting() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        let destination = try decode(payload(format: "parquet"))

        try await engine.save(destination)

        let reopened = DeliveryEngine(store: store, channels: [:])
        let loaded = try await reopened.destinations()
        XCTAssertEqual(loaded.count, 1, "The destination must still be there.")
        XCTAssertEqual(loaded.first?.unsupportedSettings["format"], "parquet")
        XCTAssertFalse(loaded.first?.isUsable ?? true)
    }

    // MARK: - Nothing is sent in a shape nobody chose

    /// Falling back to a default and delivering anyway would be worse than
    /// losing the destination, because it looks like it worked.
    func testAnUnusableDestinationIsNeverDue() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        try await engine.save(try decode(payload(format: "parquet")))

        let due = try await engine.dueDestinations()
        let forced = try await engine.dueDestinations(ignoringCadence: true)

        XCTAssertTrue(due.isEmpty)
        XCTAssertTrue(
            forced.isEmpty,
            "Not even Sync Now may guess at a setting on the user's behalf."
        )
    }

    func testDeliveringToAnUnusableDestinationFailsAndSaysWhy() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = RecordingChannel()
        let engine = DeliveryEngine(store: store, channels: [.restAPI: channel])
        let destination = try decode(payload(format: "parquet"))
        try await engine.save(destination)

        let batch = DeliveryBatch(
            id: UUID(),
            sequence: 0,
            createdAt: .now,
            recordCount: 3,
            payload: Data("{}".utf8),
            format: .ndjson
        )

        do {
            _ = try await engine.deliver(batch, to: destination)
            XCTFail("An unusable destination must not accept a delivery.")
        } catch let error as DeliveryError {
            guard case .unsupportedSettings = error else {
                return XCTFail("Wrong error: \(error)")
            }
        }

        let delivered = await channel.count()
        XCTAssertEqual(delivered, 0, "Nothing may reach the wire.")

        let state = try await engine.state(for: destination.id)
        XCTAssertEqual(state?.state, DeliveryState.needsAttention.rawValue)
        XCTAssertNil(state?.nextAttemptAt, "Waiting does not teach it a new word.")
        let receipts = try await engine.receipts(for: destination.id)
        XCTAssertEqual(receipts.first?.state, DeliveryState.needsAttention.rawValue)
        XCTAssertNotNil(receipts.first?.detail, "The user has to be told why.")
    }

    func testTheConnectionTestAlsoRefusesRatherThanGuessing() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = RecordingChannel()
        let engine = DeliveryEngine(store: store, channels: [.restAPI: channel])
        let destination = try decode(payload(format: "parquet"))

        do {
            _ = try await engine.deliverWithoutRecording(
                DeliveryBatch(
                    id: UUID(),
                    sequence: 0,
                    createdAt: .now,
                    recordCount: 0,
                    payload: Data(),
                    format: .ndjson
                ),
                to: destination
            )
            XCTFail("The test must not report a destination Hozz cannot use as working.")
        } catch let error as DeliveryError {
            guard case .unsupportedSettings = error else {
                return XCTFail("Wrong error: \(error)")
            }
        }
        let delivered = await channel.count()
        XCTAssertEqual(delivered, 0)
    }

    // MARK: - The InfluxDB precision

    /// The precision is a string in `options`, so it cannot throw. It can do
    /// something quieter and worse: fall back to nanoseconds and file every
    /// point in the wrong decade, in a database that will not complain.
    func testAnUnknownPrecisionMakesTheDestinationUnusableRatherThanWrong() throws {
        let destination = try decode(
            payload(
                format: "influx",
                options: #"{"influxMeasurement": "health", "influxPrecision": "picoseconds"}"#
            )
        )

        XCTAssertFalse(destination.isUsable)
        XCTAssertEqual(
            destination.unsupportedSettings[Destination.precisionKey],
            "picoseconds"
        )
        XCTAssertTrue(
            try XCTUnwrap(destination.unsupportedDescription).contains("precision")
        )
    }

    func testAKnownPrecisionIsStillFine() throws {
        let destination = try decode(
            payload(
                format: "influx",
                options: #"{"influxMeasurement": "health", "influxPrecision": "ms"}"#
            )
        )
        XCTAssertTrue(destination.isUsable)
        XCTAssertEqual(destination.influxOptions.precision, .milliseconds)
    }

    // MARK: - What the user is told

    func testTheExplanationNamesTheSettingAndTheValue() throws {
        let one = try XCTUnwrap(
            try decode(payload(format: "parquet")).unsupportedDescription
        )
        XCTAssertTrue(one.contains("parquet"), one)
        XCTAssertTrue(one.contains("format"), one)
        XCTAssertTrue(one.contains("Nothing has been sent"), one)

        let two = try XCTUnwrap(
            try decode(payload(format: "parquet", cadence: "weekly"))
                .unsupportedDescription
        )
        XCTAssertTrue(two.contains("parquet") && two.contains("weekly"), two)
        XCTAssertTrue(two.contains(" and "), "Two problems must read as two: \(two)")
    }

    func testEveryUnsupportedSettingHasAHumanName() {
        for key in ["kind", "format", "cadence", "payloadSchema", Destination.precisionKey] {
            XCTAssertNotEqual(
                Destination.settingName(for: key),
                "a setting",
                "\(key) needs a name someone can act on."
            )
        }
    }
}

/// Counts what actually reached a channel.
private actor RecordingChannel: DeliveryChannel {
    private var delivered = 0

    func count() -> Int {
        delivered
    }

    func deliver(
        _ batch: DeliveryBatch,
        to destination: Destination
    ) async throws -> DeliveryReceipt {
        delivered += 1
        return DeliveryReceipt(
            destinationID: destination.id,
            attemptedAt: .now,
            recordCount: batch.recordCount,
            byteCount: UInt64(batch.payload.count),
            state: .delivered
        )
    }
}
