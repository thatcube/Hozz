import Foundation
import HozzCore
import HozzDeliver
import HozzHealth
import HozzHealthFake
import HozzReceive
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

/// A source that hands back only a few records per page, the way the series
/// reader does, so a page is bounded by size rather than by the caller's count.
private actor ChunkedHealthDataSource: HealthDataSource {
    private let changes: [HealthChange]
    private let type: HealthTypeKey
    private let perPage: Int

    init(changes: [HealthChange], type: HealthTypeKey, perPage: Int) {
        self.changes = changes
        self.type = type
        self.perPage = perPage
    }

    func changes(
        for type: HealthTypeKey,
        after anchor: AnchorToken?,
        limit: Int
    ) async throws -> HealthChangeBatch {
        guard type == self.type else {
            return HealthChangeBatch(
                changes: [],
                proposedAnchor: AnchorToken(data: Data("0".utf8))
            )
        }
        let offset = anchor
            .flatMap { Int(String(decoding: $0.data, as: UTF8.self)) } ?? 0
        let end = min(offset + min(perPage, limit), changes.count)
        return HealthChangeBatch(
            changes: Array(changes[offset..<end]),
            proposedAnchor: AnchorToken(data: Data(String(end).utf8))
        )
    }
}

final class SyncEngineTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")
    private let heart = HealthTypeKey("HKQuantityTypeIdentifierHeartRate")
    private let audiogram = HealthTypeKey("HKDataTypeIdentifierAudiogram")

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

    private func metricSample(
        _ identifier: String,
        type: HealthTypeKey,
        value: Double
    ) -> HealthChange {
        let payload: [String: Any] = [
            "kind": "quantity",
            "id": identifier,
            "type": type.rawValue,
            "startDate": "2026-01-01T00:00:00.000Z",
            "endDate": "2026-01-01T00:00:00.000Z",
            "quantity": ["value": value, "unit": "count"]
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

    private func encodingFailure(type: HealthTypeKey) throws -> HealthChange {
        let sourceID = UUID()
        return .upsert(
            CapturedHealthObject(
                id: sourceID,
                type: type,
                canonicalPayload: try HealthSampleEncoder()
                    .encodeEncodingFailure(
                        id: sourceID,
                        typeIdentifier: type.rawValue,
                        message: "The sample could not be encoded."
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

    func testMetricsDestinationSkipsUnrepresentableTypeWithoutBlockingSupportedData() async throws {
        let store = try makeStore()
        let channel = RecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = Destination(
            name: "Metrics",
            kind: .folder,
            format: .metrics,
            folderBookmark: Data("metrics".utf8)
        )
        try await delivery.save(destination)
        let unsupported = HealthChange.upsert(
            CapturedHealthObject(
                id: UUID(),
                type: audiogram,
                canonicalPayload: Data(
                    """
                    {"kind":"audiogram","id":"hearing","type":"HKDataTypeIdentifierAudiogram",
                     "startDate":"2026-01-01T00:00:00.000Z",
                     "endDate":"2026-01-01T00:00:00.000Z","sensitivityPoints":[]}
                    """.utf8
                )
            )
        )
        let source = ScriptedHealthDataSource(
            streams: [
                steps: [metricSample("step-1", type: steps, value: 1)],
                audiogram: [unsupported]
            ]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [audiogram, steps]
        )

        _ = try await engine.sync()
        try await source.append(
            metricSample("step-2", type: steps, value: 2),
            to: steps
        )
        _ = try await engine.sync(
            ignoringCadence: true,
            now: Date(timeIntervalSinceNow: 60)
        )

        let unsupportedQueries = await source.queryCount(for: audiogram)
        let unsupportedAnchor = try await store.committedAnchor(
            scope: .destination(destination.id),
            type: audiogram
        )
        let payloadCount = await channel.payloads(for: destination.id).count
        let supportedAnchor = try await store.committedAnchor(
            scope: .destination(destination.id),
            type: steps
        )
        XCTAssertEqual(unsupportedQueries, 0)
        XCTAssertNil(unsupportedAnchor)
        XCTAssertEqual(payloadCount, 2)
        XCTAssertNotNil(supportedAnchor)
    }

    func testEncodingFailureDoesNotWedgeMetricsAndRemainsOwedToLosslessDestination()
        async throws
    {
        let store = try makeStore()
        let channel = RecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let metrics = Destination(
            name: "Metrics",
            kind: .folder,
            format: .metrics,
            folderBookmark: Data("metrics".utf8)
        )
        var compatibleMetrics = Destination(
            name: "Compatible metrics",
            kind: .folder,
            format: .metrics,
            folderBookmark: Data("compatible-metrics".utf8)
        )
        compatibleMetrics.payloadSchema = .healthAutoExport
        let lossless = Destination(
            name: "Archive",
            kind: .folder,
            format: .ndjson,
            folderBookmark: Data("archive".utf8)
        )
        try await delivery.save(metrics)
        try await delivery.save(compatibleMetrics)
        try await delivery.save(lossless)
        await channel.fail(lossless.id)

        let source = ScriptedHealthDataSource(
            streams: [
                steps: [
                    metricSample("valid-step", type: steps, value: 12),
                    try encodingFailure(type: steps)
                ]
            ]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )

        let first = try await engine.sync()

        XCTAssertEqual(first.deliveredRecords, 2)
        for destination in [metrics, compatibleMetrics] {
            let payloads = await channel.payloads(for: destination.id)
            let payload = try XCTUnwrap(payloads.first)
            let roundTrip = try BatchParser.parse(payload)
            XCTAssertEqual(roundTrip.records.map(\.id), ["valid-step"])
            XCTAssertFalse(
                String(decoding: payload, as: UTF8.self)
                    .contains("sampleEncodingError")
            )
        }
        let metricsAnchor = try await store.committedAnchor(
            scope: .destination(metrics.id),
            type: steps
        )
        let compatibleMetricsAnchor = try await store.committedAnchor(
            scope: .destination(compatibleMetrics.id),
            type: steps
        )
        let losslessAnchorBeforeRetry = try await store.committedAnchor(
            scope: .destination(lossless.id),
            type: steps
        )
        XCTAssertNotNil(
            metricsAnchor,
            "The intentionally omitted error must not hold valid metrics behind it."
        )
        XCTAssertNotNil(compatibleMetricsAnchor)
        XCTAssertNil(
            losslessAnchorBeforeRetry,
            "A failed lossless delivery must keep every source record owed."
        )

        await channel.recover(lossless.id)
        let second = try await engine.sync(
            ignoringCadence: true,
            now: Date(timeIntervalSinceNow: 60)
        )
        XCTAssertEqual(second.deliveredRecords, 2)
        let losslessPayloads = await channel.payloads(for: lossless.id)
        let losslessText = String(
            decoding: try XCTUnwrap(losslessPayloads.first),
            as: UTF8.self
        )
        XCTAssertTrue(losslessText.contains("\"id\":\"valid-step\""))
        XCTAssertTrue(losslessText.contains("\"kind\":\"sampleEncodingError\""))
        let losslessAnchorAfterRetry = try await store.committedAnchor(
            scope: .destination(lossless.id),
            type: steps
        )
        XCTAssertNotNil(losslessAnchorAfterRetry)

        _ = try await engine.sync(
            ignoringCadence: true,
            now: Date(timeIntervalSinceNow: 120)
        )
        let finalMetricsPayloads = await channel.payloads(for: metrics.id)
        let finalCompatibleMetricsPayloads = await channel.payloads(
            for: compatibleMetrics.id
        )
        let finalLosslessPayloads = await channel.payloads(for: lossless.id)
        XCTAssertEqual(finalMetricsPayloads.count, 1)
        XCTAssertEqual(finalCompatibleMetricsPayloads.count, 1)
        XCTAssertEqual(finalLosslessPayloads.count, 1)
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

    // MARK: - Bounded passes

    /// Series records carry five hundred points each and are tens of kilobytes,
    /// so a pass bounded only by record count would gather hundreds of
    /// megabytes in a background launch and be killed for it.
    func testAPassStopsOnSizeRatherThanOnlyOnCount() async throws {
        let store = try makeStore()
        let channel = RecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = Destination(
            name: "Folder",
            kind: .folder,
            folderBookmark: Data("a".utf8)
        )
        try await delivery.save(destination)

        // Far fewer records than the count limit, but far more bytes. Paged
        // the way a series type pages, a few large records at a time.
        let recordBytes = 64 * 1_024
        let source = ChunkedHealthDataSource(
            changes: (0..<400).map { index in
                fat("fat-\(index)", type: steps, bytes: recordBytes)
            },
            type: steps,
            perPage: 8
        )
        let engine = HealthSyncEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps],
            lease: ExportWriterLease()
        )

        let outcome = try await engine.sync()

        XCTAssertTrue(
            outcome.wasInterrupted,
            "A pass that hit its size budget must say it did not finish."
        )
        let delivered = await channel.payloads(for: destination.id)
        let bytes = delivered.reduce(0) { $0 + $1.count }
        // A page's size cannot be known before it is read, so the bound is the
        // budget plus at most one more page.
        XCTAssertLessThan(
            bytes,
            HealthSyncEngine.batchByteLimit + 8 * 2 * recordBytes,
            "One pass must not gather an unbounded amount of Health data."
        )
        XCTAssertGreaterThan(bytes, 0, "It must still make progress.")

        // The rest is not lost: the cursor stayed where the pass stopped, so
        // later passes carry on from there.
        var passes = 1
        while passes < 40 {
            let next = try await engine.sync(
                now: Date(timeIntervalSinceNow: Double(passes) * 3_600)
            )
            passes += 1
            if next.deliveredRecords == 0 {
                break
            }
        }
        let identifiers = await channel.sampleIDs(for: destination.id)
        XCTAssertEqual(
            Set(identifiers).count,
            400,
            "Every record must arrive across the passes."
        )
        XCTAssertEqual(
            identifiers.count,
            400,
            "No record may be sent twice."
        )
    }

    // MARK: - Fair ordering

    /// The failure this fixes: types were visited in catalogue order and the
    /// budget was shared first-come, so a big type early in the list took the
    /// whole pass and everything behind it got nothing at all.
    ///
    /// Stand hours sit 4th of 212 and step count 197th, so someone with years
    /// of stand hours saw no step count for dozens of passes.
    func testABigEarlyTypeNoLongerStarvesTheOnesBehindIt() async throws {
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
            streams: [
                // Far more than one pass can carry.
                steps: (0..<20_000).map { sample("stand-\($0)", type: steps) },
                heart: (0..<10).map { sample("heart-\($0)", type: heart) }
            ]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps, heart]
        )

        _ = try await engine.sync()

        let identifiers = await channel.sampleIDs(for: destination.id)
        XCTAssertEqual(
            identifiers.filter { $0.hasPrefix("heart-") }.count,
            10,
            "A small type behind a large one must not wait its turn to be seen."
        )
        XCTAssertGreaterThan(
            identifiers.filter { $0.hasPrefix("stand-") }.count,
            HealthSyncEngine.minimumFairShare,
            "The large type must still make real progress, not just its share."
        )
    }

    func testAFairShareLeavesRoomForEveryTypeToBeSeen() {
        XCTAssertEqual(HealthSyncEngine.fairShare(candidateCount: 1), 5_000)
        XCTAssertEqual(HealthSyncEngine.fairShare(candidateCount: 212), 50)
        XCTAssertEqual(HealthSyncEngine.fairShare(candidateCount: 5), 500)
        XCTAssertGreaterThanOrEqual(
            HealthSyncEngine.fairShare(candidateCount: 212) * 100,
            HealthSyncEngine.batchRecordLimit,
            "A hundred types should fit inside one budget's worth of shares."
        )
    }

    func testTheOrderRotatesSoNoTypeIsPermanentlyFirst() {
        let types = (0..<5).map { HealthTypeKey("type-\($0)") }

        let first = HealthSyncEngine.rotated(
            types,
            at: Date(timeIntervalSince1970: 0)
        )
        let later = HealthSyncEngine.rotated(
            types,
            at: Date(timeIntervalSince1970: 3_600 * 2)
        )

        XCTAssertEqual(Set(first), Set(types), "Rotation must not drop a type.")
        XCTAssertEqual(first.count, types.count)
        XCTAssertNotEqual(
            first.first,
            later.first,
            "The remainder of a pass would otherwise always land on the same type."
        )
    }

    /// Fairness is only worth having if it still loses nothing.
    func testEverythingStillArrivesAcrossPassesWithoutDuplication() async throws {
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
            streams: [
                steps: (0..<6_000).map { sample("stand-\($0)", type: steps) },
                heart: (0..<600).map { sample("heart-\($0)", type: heart) }
            ]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps, heart]
        )

        var passes = 0
        while passes < 30 {
            let outcome = try await engine.sync(
                now: Date(timeIntervalSinceNow: Double(passes) * 3_600)
            )
            passes += 1
            if outcome.deliveredRecords == 0 {
                break
            }
        }

        let identifiers = await channel.sampleIDs(for: destination.id)
        XCTAssertEqual(identifiers.count, 6_600, "No record may be sent twice.")
        XCTAssertEqual(Set(identifiers).count, 6_600, "No record may be missed.")
    }

    /// A partially drained type has to pick up where it stopped rather than
    /// starting over, which is the whole point of the cursor.
    func testAPartiallyDrainedTypeResumesWhereItStopped() async throws {
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
            streams: [steps: (0..<7_000).map { sample("s-\($0)", type: steps) }]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )

        _ = try await engine.sync()
        let afterFirst = await channel.sampleIDs(for: destination.id)
        XCTAssertEqual(afterFirst.count, HealthSyncEngine.batchRecordLimit)

        _ = try await engine.sync(now: Date(timeIntervalSinceNow: 3_600))
        let afterSecond = await channel.sampleIDs(for: destination.id)

        XCTAssertEqual(afterSecond.count, 7_000)
        XCTAssertEqual(
            Set(afterSecond).count,
            7_000,
            "Resuming must not replay what the first pass already sent."
        )
    }

    // MARK: - Honest coverage

    /// The store used to record `anchorClosed` for a type the budget cut off
    /// mid-drain, which asserted the type was caught up when fifteen thousand
    /// records were still to come.
    func testATypeCutOffByTheBudgetIsNotRecordedAsFinished() async throws {
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
            streams: [steps: (0..<20_000).map { sample("s-\($0)", type: steps) }]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )

        _ = try await engine.sync()

        let record = try await store.streamRecord(
            scope: .destination(destination.id),
            type: steps
        )
        XCTAssertEqual(record?.coverage, .draining)
        XCTAssertNil(
            record?.anchorClosedAt,
            "A type with records still to come has not closed."
        )
        XCTAssertGreaterThan(record?.recordCount ?? 0, 0)
    }

    func testATypeThatRanOutIsRecordedAsClosed() async throws {
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
            streams: [steps: (0..<10).map { sample("s-\($0)", type: steps) }]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps]
        )

        _ = try await engine.sync()

        let record = try await store.streamRecord(
            scope: .destination(destination.id),
            type: steps
        )
        XCTAssertEqual(record?.coverage, .anchorClosed)
        XCTAssertNotNil(record?.anchorClosedAt)
    }

    /// A type that produced nothing at all cannot be called covered: Health
    /// does not let Hozz tell a denied type from an empty one.
    func testATypeThatProducedNothingStaysIndeterminate() async throws {
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
            streams: [steps: [sample("s-0", type: steps)], heart: []]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [steps, heart]
        )

        _ = try await engine.sync()

        let record = try await store.streamRecord(
            scope: .destination(destination.id),
            type: heart
        )
        XCTAssertEqual(record?.coverage, .authorizationIndeterminate)
        XCTAssertEqual(record?.recordCount, 0)
    }

    /// A record whose payload is deliberately large, standing in for a workout
    /// route page or a block of ECG voltages.
    private func fat(
        _ identifier: String,
        type: HealthTypeKey,
        bytes: Int
    ) -> HealthChange {
        let payload: [String: Any] = [
            "kind": "quantity",
            "id": UUID().uuidString.lowercased(),
            "type": type.rawValue,
            "startDate": "2026-01-01T00:00:00.000Z",
            "endDate": "2026-01-01T00:00:00.000Z",
            "sample": identifier,
            "filler": String(repeating: "x", count: bytes)
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
}
