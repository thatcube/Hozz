import Foundation
import HozzCore
import HozzDeliver
import HozzHealth
import HozzHealthFake
import HozzStore
import XCTest

/// Records what each destination actually received, so a test can assert on
/// the union rather than on internal state.
private actor RecordingChannel: DeliveryChannel {
    private var payloads: [UUID: [Data]] = [:]
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

    /// Every sample identifier this destination has been sent, including
    /// repeats, so duplication is visible.
    func sampleIDs(for destinationID: UUID) -> [String] {
        payloads(for: destinationID).flatMap { payload in
            String(decoding: payload, as: UTF8.self)
                .split(separator: "\n")
                .compactMap { line in
                    (try? JSONSerialization.jsonObject(with: Data(line.utf8)))
                        .flatMap { $0 as? [String: Any] }?["sample"] as? String
                }
        }
    }

    func deliver(
        _ batch: DeliveryBatch,
        to destination: Destination
    ) async throws -> DeliveryReceipt {
        if failing.contains(destination.id) {
            throw DeliveryError.transport("scripted failure")
        }
        payloads[destination.id, default: []].append(batch.payload)
        return DeliveryReceipt(
            destinationID: destination.id,
            attemptedAt: .now,
            recordCount: batch.recordCount,
            byteCount: UInt64(batch.payload.count),
            state: .delivered
        )
    }
}

final class SyncEngineTests: XCTestCase {
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
            "id": UUID().uuidString.lowercased(),
            "type": type.rawValue,
            "startDate": "2026-01-01T00:00:00.000Z",
            "endDate": "2026-01-01T00:00:00.000Z",
            "sample": identifier
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

    // MARK: - The invariant

    /// Destinations are scheduled independently. A cursor shared between them
    /// would be advanced by whichever ran first, and the slower one would never
    /// see that data again.
    func testASlowDestinationStillReceivesEverything() async throws {
        let store = try makeStore()
        let channel = RecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])

        var fast = Destination(
            name: "Fast",
            kind: .folder,
            cadence: .whenDataArrives,
            folderBookmark: Data("a".utf8)
        )
        fast.cadence = .whenDataArrives
        var slow = Destination(
            name: "Slow",
            kind: .folder,
            cadence: .daily,
            folderBookmark: Data("b".utf8)
        )
        slow.cadence = .daily
        try await delivery.save(fast)
        try await delivery.save(slow)

        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<4).map { sample("s\($0)", type: steps) }]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )

        // First pass: both are due, both receive everything so far.
        _ = try await engine.sync()

        // More data arrives, then only the fast destination is due.
        for index in 4..<8 {
            try await source.append(sample("s\(index)", type: steps), to: steps)
        }
        _ = try await engine.sync(now: Date(timeIntervalSinceNow: 10 * 60))

        // A day later the slow one is finally due.
        for index in 8..<10 {
            try await source.append(sample("s\(index)", type: steps), to: steps)
        }
        _ = try await engine.sync(now: Date(timeIntervalSinceNow: 25 * 60 * 60))

        let slowIDs = await channel.sampleIDs(for: slow.id)
        let fastIDs = await channel.sampleIDs(for: fast.id)
        let expected = Set((0..<10).map { "s\($0)" })

        XCTAssertEqual(
            Set(fastIDs),
            expected,
            "The fast destination must receive everything."
        )
        XCTAssertEqual(
            Set(slowIDs),
            expected,
            "A slower destination must not lose data the faster one consumed."
        )
        XCTAssertEqual(
            slowIDs.count,
            Set(slowIDs).count,
            "No record may be delivered twice."
        )
    }

    /// One unreachable destination must not stop the others, and must not
    /// resend the same batch to them forever.
    func testABrokenDestinationDoesNotBlockAHealthyOne() async throws {
        let store = try makeStore()
        let channel = RecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])

        let healthy = Destination(
            name: "Healthy",
            kind: .folder,
            folderBookmark: Data("a".utf8)
        )
        let broken = Destination(
            name: "Broken",
            kind: .folder,
            folderBookmark: Data("b".utf8)
        )
        try await delivery.save(healthy)
        try await delivery.save(broken)
        await channel.fail(broken.id)

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
        try await source.append(sample("s3", type: steps), to: steps)
        _ = try await engine.sync(now: Date(timeIntervalSinceNow: 10 * 60))

        let healthyIDs = await channel.sampleIDs(for: healthy.id)
        XCTAssertEqual(
            Set(healthyIDs),
            Set((0..<4).map { "s\($0)" }),
            "The healthy destination must keep receiving new data."
        )
        XCTAssertEqual(
            healthyIDs.count,
            Set(healthyIDs).count,
            "A broken sibling must not cause the healthy one to be resent data."
        )
    }

    /// A failed delivery must replay, not be skipped.
    func testAFailedDeliveryIsReplayedOnTheNextPass() async throws {
        let store = try makeStore()
        let channel = RecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = Destination(
            name: "Flaky",
            kind: .folder,
            folderBookmark: Data("a".utf8)
        )
        try await delivery.save(destination)
        await channel.fail(destination.id)

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
        let afterFailure = await channel.sampleIDs(for: destination.id)
        XCTAssertTrue(afterFailure.isEmpty)

        await channel.recover(destination.id)
        _ = try await engine.sync(now: Date(timeIntervalSinceNow: 24 * 60 * 60))

        let delivered = await channel.sampleIDs(for: destination.id)
        XCTAssertEqual(
            Set(delivered),
            Set((0..<3).map { "s\($0)" }),
            "Nothing may be skipped because an attempt failed."
        )
    }

    /// A destination that only wants some types must not have its cursor moved
    /// past types it excluded.
    func testTypeSelectionIsHonouredAndDoesNotSkipData() async throws {
        let store = try makeStore()
        let channel = RecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])

        var stepsOnly = Destination(
            name: "Steps only",
            kind: .folder,
            folderBookmark: Data("a".utf8)
        )
        stepsOnly.includedTypes = [steps]
        try await delivery.save(stepsOnly)

        let source = ScriptedHealthDataSource(
            streams: [
                steps: [sample("s0", type: steps)],
                heart: [sample("h0", type: heart)]
            ]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps, heart]
        )

        _ = try await engine.sync()

        let ids = await channel.sampleIDs(for: stepsOnly.id)
        XCTAssertEqual(Set(ids), ["s0"])

        let heartCursor = try await store.committedAnchor(
            scope: .destination(stepsOnly.id),
            type: heart
        )
        XCTAssertNil(
            heartCursor,
            "An excluded type must not have its cursor advanced."
        )
    }

    func testNothingIsSentWhenThereAreNoDestinations() async throws {
        let store = try makeStore()
        let delivery = DeliveryEngine(store: store, channels: [:])
        let source = ScriptedHealthDataSource(
            streams: [steps: [sample("s0", type: steps)]]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )

        let outcome = try await engine.sync()

        XCTAssertEqual(outcome, .idle)
        let queries = await source.queryCount(for: steps)
        XCTAssertEqual(queries, 0, "Health must not be read with nowhere to send it.")
    }

    func testASecondPassWithNoNewDataSendsNothing() async throws {
        let store = try makeStore()
        let channel = RecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = Destination(
            name: "Folder",
            kind: .folder,
            folderBookmark: Data("a".utf8)
        )
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
        _ = try await engine.sync(now: Date(timeIntervalSinceNow: 10 * 60))

        let payloads = await channel.payloads(for: destination.id)
        XCTAssertEqual(payloads.count, 1, "An idle pass must not resend.")
    }
}
