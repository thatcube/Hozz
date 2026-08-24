import Foundation
import HozzCore
import HozzDeliver
import HozzHealth
import HozzHealthFake
import HozzReceive
import HozzStore
import XCTest

/// Keeps every payload a destination was handed, so a test can read what was
/// actually sent rather than what the engine believes it sent.
private actor CoverageCapturingChannel: DeliveryChannel {
    private var payloads: [UUID: [Data]] = [:]
    private var identifiers: [UUID: [UUID]] = [:]
    private var counts: [UUID: [Int]] = [:]
    private var attempts: [UUID: [(id: UUID, payload: Data)]] = [:]
    private var failing: Set<UUID> = []

    func fail(_ destinationID: UUID) {
        failing.insert(destinationID)
    }

    func recover(_ destinationID: UUID) {
        failing.remove(destinationID)
    }

    func payloads(for destinationID: UUID) -> [Data] {
        payloads[destinationID, default: []]
    }

    /// The identity each batch was sent under, which is what a receiver uses
    /// to recognise a repeat.
    func identifiers(for destinationID: UUID) -> [UUID] {
        identifiers[destinationID, default: []]
    }

    /// What each batch claimed to be carrying.
    func recordCounts(for destinationID: UUID) -> [Int] {
        counts[destinationID, default: []]
    }

    /// Every batch the engine built for a destination, refused ones included.
    func attemptedIdentifiers(for destinationID: UUID) -> [UUID] {
        attempts[destinationID, default: []].map(\.id)
    }

    func attemptedPayloads(for destinationID: UUID) -> [Data] {
        attempts[destinationID, default: []].map(\.payload)
    }

    /// Every coverage line sent to a destination, in order, as the bytes that
    /// actually went out. Kept as bytes rather than decoded here so what
    /// crosses back is exactly what crossed the wire.
    func coverageLines(for destinationID: UUID) -> [Data] {
        payloads(for: destinationID).flatMap { payload in
            String(decoding: payload, as: UTF8.self)
                .split(separator: "\n")
                .map { Data($0.utf8) }
                .filter { line in
                    let object = try? JSONSerialization.jsonObject(with: line)
                        as? [String: Any]
                    return (object?["kind"] as? String) == "typeCoverage"
                }
        }
    }

    func deliver(
        _ batch: DeliveryBatch,
        to destination: Destination
    ) async throws -> DeliveryReceipt {
        // Recorded before the scripted failure, not after. A refused batch
        // was still built, and its identity is exactly what a test of retry
        // behaviour needs to compare against.
        attempts[destination.id, default: []].append((batch.id, batch.payload))
        if failing.contains(destination.id) {
            throw DeliveryError.transport("scripted failure")
        }
        payloads[destination.id, default: []].append(batch.payload)
        identifiers[destination.id, default: []].append(batch.id)
        counts[destination.id, default: []].append(batch.recordCount)
        return DeliveryReceipt(
            destinationID: destination.id,
            attemptedAt: .now,
            recordCount: batch.recordCount,
            byteCount: UInt64(batch.payload.count),
            state: .delivered
        )
    }
}

/// The phone telling a receiver how completely it has read each type.
///
/// The receiver could never work this out for itself: an anchored sweep hands
/// back samples in the order Health stored them, so what has arrived for an
/// unfinished type is an arbitrary subset by date. It guessed, and told a
/// bedbound man he had not walked since January 2023.
final class CoverageDeliveryTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")
    private let heart = HealthTypeKey("HKQuantityTypeIdentifierHeartRate")

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private func sample(_ identifier: String, type: HealthTypeKey) -> HealthChange {
        let payload: [String: Any] = [
            "kind": "quantity",
            "id": identifier,
            "type": type.rawValue,
            "startDate": "2026-01-01T00:00:00.000Z",
            "endDate": "2026-01-01T00:00:00.000Z",
            "quantity": ["value": 1_200, "unit": "count"]
        ]
        return .upsert(
            CapturedHealthObject(
                id: UUID(),
                type: type,
                canonicalPayload: try! JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.sortedKeys]
                )
            )
        )
    }

    private func makeDestination(
        format: DeliveryFormat = .ndjson,
        kind: DestinationKind = .folder
    ) -> Destination {
        var destination = Destination(
            name: "Mac",
            kind: kind,
            cadence: .whenDataArrives,
            folderBookmark: Data("a".utf8)
        )
        destination.format = format
        return destination
    }

    private func makeEngine(
        store: HozzStore,
        source: ScriptedHealthDataSource,
        delivery: DeliveryEngine,
        types: [HealthTypeKey]
    ) -> HealthSyncEngine {
        HealthSyncEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: types,
            lease: ExportWriterLease()
        )
    }

    /// The last thing said about one type, decoded from the delivered bytes.
    private func report(
        _ lines: [Data],
        for type: HealthTypeKey
    ) -> [String: Any]? {
        lines
            .compactMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            .last { ($0["type"] as? String) == type.rawValue }
    }

    // MARK: - The fact travels

    func testAFinishedSweepIsReportedInTheBatchThatFinishesIt() async throws {
        let store = try makeStore()
        let channel = CoverageCapturingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = makeDestination()
        try await delivery.save(destination)

        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<4).map { sample("s\($0)", type: steps) }]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )
        let outcome = try await engine.sync()
        XCTAssertEqual(outcome.deliveredRecords, 4)

        let lines = await channel.coverageLines(for: destination.id)
        let stepsReport = try XCTUnwrap(report(lines, for: steps))
        XCTAssertEqual(stepsReport["state"] as? String, "anchorClosed")
        XCTAssertEqual(stepsReport["complete"] as? Bool, true)
        XCTAssertEqual(
            stepsReport["deliveredCount"] as? Int,
            4,
            "the count is the records this destination has been given"
        )
    }

    /// The completion has to ride in the same batch as the records that
    /// completed it. Sent a pass later, a type that finishes and is then never
    /// touched again would never be reported finished at all — which is
    /// precisely the state Brandon's step count was in.
    func testTheCompletionIsNotOneDeliveryBehindTheRecords() async throws {
        let store = try makeStore()
        let channel = CoverageCapturingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = makeDestination()
        try await delivery.save(destination)

        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<3).map { sample("s\($0)", type: steps) }]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )
        _ = try await engine.sync()

        let payloads = await channel.payloads(for: destination.id)
        XCTAssertEqual(payloads.count, 1, "one pass, one batch")
        let first = String(decoding: try XCTUnwrap(payloads.first), as: UTF8.self)
        XCTAssertTrue(first.contains("\"state\":\"anchorClosed\""), first)
        XCTAssertTrue(first.contains("\"id\":\"s2\""), "the records are in it too")
    }

    /// HealthKit answers identically for a type you have no records of and one
    /// Hozz was never granted, so a stream that closed without ever returning
    /// an object must not claim it was fully read.
    func testATypeThatNeverReturnedAnythingIsNotReportedComplete() async throws {
        let store = try makeStore()
        let channel = CoverageCapturingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = makeDestination()
        try await delivery.save(destination)

        let source = ScriptedHealthDataSource(streams: [:])
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )
        let outcome = try await engine.sync()
        XCTAssertEqual(outcome.deliveredRecords, 0)

        let lines = await channel.coverageLines(for: destination.id)
        let stepsReport = try XCTUnwrap(
            report(lines, for: steps),
            "a batch carrying nothing but coverage is still worth sending"
        )
        XCTAssertEqual(
            stepsReport["state"] as? String,
            "authorizationIndeterminate"
        )
        XCTAssertEqual(stepsReport["complete"] as? Bool, false)
    }

    // MARK: - Sent when it changes, and not otherwise

    /// A digest that moved every pass would deliver a batch every hour to a
    /// Mac that may be switched off — failing, backing off, and eventually
    /// parking a destination with nothing wrong with it.
    func testNothingIsSentWhenNothingHasChanged() async throws {
        let store = try makeStore()
        let channel = CoverageCapturingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = makeDestination()
        try await delivery.save(destination)

        let source = ScriptedHealthDataSource(
            streams: [steps: [sample("s0", type: steps)]]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )

        _ = try await engine.sync()
        let afterFirst = await channel.payloads(for: destination.id).count
        XCTAssertEqual(afterFirst, 1)

        for hour in 1...4 {
            _ = try await engine.sync(
                now: Date(timeIntervalSinceNow: Double(hour) * 3_600)
            )
        }
        let afterQuietHours = await channel.payloads(for: destination.id).count
        XCTAssertEqual(
            afterQuietHours,
            afterFirst,
            "four quiet hours must not become four deliveries"
        )
    }

    func testAChangeInCoverageAloneIsWorthADelivery() async throws {
        let store = try makeStore()
        let channel = CoverageCapturingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = makeDestination()
        try await delivery.save(destination)

        // Only steps to begin with; heart rate is added to the destination's
        // reach later, which is a coverage change with no records behind it.
        let source = ScriptedHealthDataSource(
            streams: [steps: [sample("s0", type: steps)]]
        )
        let first = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )
        _ = try await first.sync()
        let afterSteps = await channel.payloads(for: destination.id).count

        let second = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps, heart]
        )
        _ = try await second.sync(now: Date(timeIntervalSinceNow: 3_600))

        let afterHeart = await channel.payloads(for: destination.id).count
        XCTAssertEqual(
            afterHeart,
            afterSteps + 1,
            "a type the receiver has never been told about is news"
        )
        let lines = await channel.coverageLines(for: destination.id)
        XCTAssertNotNil(report(lines, for: heart))
    }

    /// A refused batch leaves the coverage still owed. Marked as told, the
    /// receiver would wait for a change that had already happened and been
    /// thrown away.
    func testCoverageIsReofferedAfterARefusedDelivery() async throws {
        let store = try makeStore()
        let channel = CoverageCapturingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = makeDestination()
        try await delivery.save(destination)

        let source = ScriptedHealthDataSource(
            streams: [steps: [sample("s0", type: steps)]]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )

        await channel.fail(destination.id)
        _ = try await engine.sync()
        let refused = await channel.payloads(for: destination.id)
        XCTAssertTrue(refused.isEmpty)

        await channel.recover(destination.id)
        _ = try await engine.sync(now: Date(timeIntervalSinceNow: 3_600))

        let lines = await channel.coverageLines(for: destination.id)
        let stepsReport = try XCTUnwrap(report(lines, for: steps))
        XCTAssertEqual(stepsReport["state"] as? String, "anchorClosed")
        XCTAssertEqual(
            stepsReport["deliveredCount"] as? Int,
            1,
            "the record was not lost by the refusal either"
        )
    }

    // MARK: - Formats that cannot carry it are not sent it

    /// A CSV has fixed columns and a metrics envelope reduces a record to one
    /// number. A report sent in either lands as a row of blanks or as a metric
    /// named after a type, which is how a reading page once landed inside the
    /// real metric and made every point count wrong.
    func testAFormatThatCannotCarryAReportIsNotSentOne() async throws {
        for format in DeliveryFormat.allCases where !format.carriesCoverage {
            let directory = try TemporaryDirectory()
            let store = try HozzStore(directory: directory.url.appending(path: "s"))
            let channel = CoverageCapturingChannel()
            let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
            let destination = makeDestination(format: format)
            try await delivery.save(destination)

            let source = ScriptedHealthDataSource(
                streams: [steps: [sample("s0", type: steps)]]
            )
            let engine = makeEngine(
                store: store,
                source: source,
                delivery: delivery,
                types: [steps]
            )
            _ = try await engine.sync()

            let carried = await channel.coverageLines(for: destination.id)
            XCTAssertTrue(
                carried.isEmpty,
                "\(format.rawValue) carried a coverage report"
            )
            for payload in await channel.payloads(for: destination.id) {
                XCTAssertFalse(
                    String(decoding: payload, as: UTF8.self).contains("typeCoverage"),
                    "\(format.rawValue) leaked the word into its payload"
                )
            }
            await store.close()
        }
    }

    /// Nor may a format that cannot carry it be woken up to deliver nothing.
    func testAFormatThatCannotCarryAReportIsNotWokenToSendOne() async throws {
        let store = try makeStore()
        let channel = CoverageCapturingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = makeDestination(format: .csv)
        try await delivery.save(destination)

        let source = ScriptedHealthDataSource(streams: [:])
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )
        _ = try await engine.sync()
        let sent = await channel.payloads(for: destination.id)
        XCTAssertTrue(
            sent.isEmpty,
            "an empty CSV of nothing is not worth a request"
        )
    }

    // MARK: - A repeat still looks like a repeat

    /// A batch is identified by a hash of its bytes, and that identity is the
    /// whole of the receiver's duplicate detection: the phone retries from the
    /// same cursor when an acknowledgement is lost, and the receiver is
    /// supposed to recognise what it already holds.
    ///
    /// Coverage stamped with the clock would put a different byte in every
    /// payload, so an identical retry would arrive under a new identity and be
    /// counted as newly delivered — overstating the receipt on the one path
    /// where the truth matters most.
    func testAnIdenticalRetryIsSentUnderTheSameIdentity() async throws {
        let store = try makeStore()
        let channel = CoverageCapturingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = makeDestination()
        try await delivery.save(destination)

        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<3).map { sample("s\($0)", type: steps) }]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )

        // The batch is built and refused, so the cursors stay put and the same
        // records are drained again an hour later. This is the ordinary case,
        // not an exotic one: it is every lost acknowledgement, and a first
        // sweep is the longest and most interruption-prone delivery there is.
        await channel.fail(destination.id)
        _ = try await engine.sync()
        await channel.recover(destination.id)
        _ = try await engine.sync(now: Date(timeIntervalSinceNow: 3_600))

        let attempted = await channel.attemptedIdentifiers(for: destination.id)
        XCTAssertEqual(attempted.count, 2, "one refused attempt and one retry")
        XCTAssertEqual(
            attempted[0],
            attempted[1],
            "an identical retry has to arrive under the identity the receiver "
                + "already knows, or it is stored a second time"
        )

        let bytes = await channel.attemptedPayloads(for: destination.id)
        XCTAssertEqual(
            bytes[0],
            bytes[1],
            "the identity is a hash of these bytes, so this is the real claim"
        )
    }

    /// And the retry must still be a retry of the *records*, not just of the
    /// coverage: nothing may be dropped on the way through.
    func testARefusedBatchLosesNoRecordsOnItsRetry() async throws {
        let store = try makeStore()
        let channel = CoverageCapturingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = makeDestination()
        try await delivery.save(destination)

        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<3).map { sample("s\($0)", type: steps) }]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )

        await channel.fail(destination.id)
        _ = try await engine.sync()
        await channel.recover(destination.id)
        _ = try await engine.sync(now: Date(timeIntervalSinceNow: 3_600))

        let delivered = await channel.payloads(for: destination.id)
        let text = delivered.map { String(decoding: $0, as: UTF8.self) }.joined()
        for index in 0..<3 {
            XCTAssertTrue(
                text.contains("\"id\":\"s\(index)\""),
                "s\(index) never arrived"
            )
        }
    }

    // MARK: - A statement is not a reading

    /// A coverage report is undated on purpose, so a delivery window admits
    /// it — correctly, since it describes a type rather than a moment. What it
    /// must not do is be counted as a record: a backfill pass that delivered
    /// nothing inside the window would otherwise hand the user a receipt
    /// saying a couple of hundred records arrived.
    func testCoverageLinesAreNotCountedAsRecordsDelivered() async throws {
        let store = try makeStore()
        let channel = CoverageCapturingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])

        var destination = makeDestination()
        destination.deliveryWindow = .sinceStartOfToday
        try await delivery.save(destination)

        // Every record is from 2026-01-01, which a "since today" window
        // excludes, so nothing but the coverage survives.
        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<5).map { sample("s\($0)", type: steps) }]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )
        _ = try await engine.sync()

        let counts = await channel.recordCounts(for: destination.id)
        for count in counts {
            XCTAssertEqual(
                count,
                0,
                "a batch carrying only coverage delivered no readings"
            )
        }
        let lines = await channel.coverageLines(for: destination.id)
        XCTAssertFalse(
            lines.isEmpty,
            "the coverage itself still has to reach the receiver"
        )
    }

    // MARK: - End to end
    /// The whole point, in one test: the phone reads, delivers, and the Mac
    /// ends up able to answer the question the dashboard used to guess at.
    func testAReceiverFedTheRealBytesKnowsWhichTypesAreFinished() async throws {
        let store = try makeStore()
        let channel = CoverageCapturingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = makeDestination()
        try await delivery.save(destination)

        let source = ScriptedHealthDataSource(
            streams: [
                steps: (0..<3).map { sample("s\($0)", type: steps) },
                heart: []
            ]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps, heart]
        )
        _ = try await engine.sync()

        let receiver = try IngestStore(
            directory: directory.url.appending(path: "received")
        )
        for (index, payload) in (await channel.payloads(for: destination.id)).enumerated() {
            _ = try await receiver.ingest(
                try BatchParser.parse(payload),
                idempotencyKey: "batch-\(index)"
            )
        }

        let held = try await receiver.totalRecordCount()
        XCTAssertEqual(held, 3)
        let stepsStanding = try await receiver.coverageStanding(for: steps.rawValue)
        XCTAssertTrue(
            stepsStanding.licensesLatestDate,
            "the Mac was told this type is finished and may say so"
        )
        let heartStanding = try await receiver
            .coverageStanding(for: heart.rawValue)
        XCTAssertFalse(heartStanding.licensesLatestDate)
        XCTAssertTrue(heartStanding.isAuthorizationIndeterminate)
        await receiver.close()
    }

    /// A Mac running an older build meets a record shape it has never seen.
    /// It must keep the bytes rather than refuse the batch, because refusing
    /// wedges: the phone would resend the same payload for ever and every
    /// later record behind it would be blocked.
    func testAnOlderReceiverKeepsACoverageLineItCannotRead() async throws {
        let payload = Data(
            """
            {"kind":"somethingOnlyANewerPhoneSends","type":"x"}
            """.utf8
        )
        let batch = try BatchParser.parse(payload)
        XCTAssertEqual(batch.unhandled.count, 1)
        XCTAssertTrue(batch.records.isEmpty)

        let receiver = try IngestStore(
            directory: directory.url.appending(path: "older")
        )
        let result = try await receiver.ingest(batch, idempotencyKey: "unknown")
        XCTAssertEqual(result.unhandled, 1)
        await receiver.close()
    }
}
