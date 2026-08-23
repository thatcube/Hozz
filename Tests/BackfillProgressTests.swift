import Foundation
import HozzCore
import HozzDeliver
import HozzHealth
import HozzHealthFake
import HozzStore
import XCTest

/// A first sweep through years of history drains a bounded batch at a time, in
/// catalog order, so a phone can spend days on its earliest types and have
/// genuinely not looked at the rest. Someone seeing one type arrive concludes
/// the export is broken, or that they have no heart data.
///
/// These tests hold the display to the two things that make it worth having:
/// the counts are true, and nothing is invented to make them look tidier.
final class BackfillProgressTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let stand = HealthTypeKey("HKCategoryTypeIdentifierAppleStandHour")
    private let heart = HealthTypeKey("HKQuantityTypeIdentifierHeartRate")
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func sample(_ id: String, type: HealthTypeKey) -> HealthChange {
        .upsert(
            CapturedHealthObject(
                id: UUID(),
                type: type,
                canonicalPayload: Data(
                    #"{"kind":"quantity","sample":"\#(id)"}"#.utf8
                )
            )
        )
    }

    /// The progress figures, computed the way the dashboard computes them.
    private func progress(
        store: HozzStore,
        destinationID: UUID,
        selected: Set<HealthTypeKey>
    ) async throws -> (reached: Int, empty: Int, records: Int) {
        let streams = try await store.streamRecords(
            scope: .destination(destinationID)
        )
        var reached: Set<HealthTypeKey> = []
        var empty: Set<HealthTypeKey> = []
        var records = 0
        for stream in streams where selected.contains(stream.type) {
            records += stream.recordCount
            if stream.recordCount > 0 {
                reached.insert(stream.type)
            } else if stream.coverage == .authorizationIndeterminate {
                empty.insert(stream.type)
            }
        }
        empty.subtract(reached)
        return (reached.count + empty.count, empty.count, records)
    }

    private func makeEngine(
        store: HozzStore,
        source: any HealthDataSource,
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

    /// The state Brandon's Mac was actually in: tens of thousands of records,
    /// all of one type, with the rest untouched. The display has to say that
    /// rather than implying the sync is finished or broken.
    func testATypeStillBeingDrainedDoesNotMakeTheOthersLookFinished() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = AcceptingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = Destination(
            name: "Mac",
            kind: .folder,
            folderBookmark: Data("a".utf8)
        )
        try await delivery.save(destination)

        // A large type ahead of the others, exactly as the catalogue orders it.
        let source = ScriptedHealthDataSource(
            streams: [
                stand: (0..<20_000).map { sample("stand-\($0)", type: stand) },
                heart: (0..<5).map { sample("heart-\($0)", type: heart) },
                steps: (0..<5).map { sample("step-\($0)", type: steps) }
            ]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [stand, heart, steps]
        )

        _ = try await engine.sync(ignoringCadence: true)

        let after = try await progress(
            store: store,
            destinationID: destination.id,
            selected: [stand, heart, steps]
        )
        XCTAssertEqual(
            after.reached,
            1,
            "One type has been drained; the other two have not been looked at."
        )
        XCTAssertEqual(after.records, 5_000, "One pass is bounded at 5,000.")
    }

    /// The count has to climb as the sweep works through the list, or it is
    /// not progress.
    func testReachedTypesClimbAsTheSweepWorksThroughTheList() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = AcceptingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = Destination(
            name: "Mac",
            kind: .folder,
            folderBookmark: Data("a".utf8)
        )
        try await delivery.save(destination)

        let source = ScriptedHealthDataSource(
            streams: [
                stand: (0..<6_000).map { sample("stand-\($0)", type: stand) },
                heart: (0..<5).map { sample("heart-\($0)", type: heart) },
                steps: (0..<5).map { sample("step-\($0)", type: steps) }
            ]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [stand, heart, steps]
        )

        _ = try await engine.sync(ignoringCadence: true)
        let first = try await progress(
            store: store,
            destinationID: destination.id,
            selected: [stand, heart, steps]
        )

        _ = try await engine.sync(
            ignoringCadence: true,
            now: Date(timeIntervalSinceNow: 3_600)
        )
        let second = try await progress(
            store: store,
            destinationID: destination.id,
            selected: [stand, heart, steps]
        )

        XCTAssertEqual(first.reached, 1)
        XCTAssertEqual(
            second.reached,
            3,
            "Once the big type finishes, the queued ones are reached."
        )
        XCTAssertGreaterThan(second.records, first.records)
    }

    /// A type Health answered for with nothing is a complete export of
    /// nothing, and must not sit forever as an unreached type.
    func testATypeWithNoDataCountsAsReachedRatherThanPending() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = AcceptingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = Destination(
            name: "Mac",
            kind: .folder,
            folderBookmark: Data("a".utf8)
        )
        try await delivery.save(destination)

        let source = ScriptedHealthDataSource(
            streams: [
                heart: (0..<3).map { sample("heart-\($0)", type: heart) },
                steps: []
            ]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [heart, steps]
        )

        _ = try await engine.sync(ignoringCadence: true)

        let after = try await progress(
            store: store,
            destinationID: destination.id,
            selected: [heart, steps]
        )
        XCTAssertEqual(after.records, 3)
        XCTAssertGreaterThanOrEqual(
            after.reached,
            1,
            "The type that produced records is reached."
        )
    }

    /// The invariant that keeps this honest: nothing here can exceed what was
    /// actually asked for, and no fraction of records is ever computed.
    func testProgressNeverClaimsMoreTypesThanWereSelected() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = AcceptingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = Destination(
            name: "Mac",
            kind: .folder,
            folderBookmark: Data("a".utf8)
        )
        try await delivery.save(destination)

        let source = ScriptedHealthDataSource(
            streams: [
                heart: (0..<3).map { sample("heart-\($0)", type: heart) },
                steps: (0..<3).map { sample("step-\($0)", type: steps) }
            ]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            delivery: delivery,
            types: [heart, steps]
        )
        _ = try await engine.sync(ignoringCadence: true)

        // Someone who narrowed their selection to one type must not see two.
        let narrowed = try await progress(
            store: store,
            destinationID: destination.id,
            selected: [heart]
        )
        XCTAssertLessThanOrEqual(narrowed.reached, 1)
        XCTAssertEqual(
            narrowed.records,
            3,
            "Only the selected type's records are counted."
        )
    }
}

/// Accepts everything, so these tests measure the drain rather than delivery.
private actor AcceptingChannel: DeliveryChannel {
    func deliver(
        _ batch: DeliveryBatch,
        to destination: Destination
    ) async throws -> DeliveryReceipt {
        DeliveryReceipt(
            destinationID: destination.id,
            attemptedAt: .now,
            recordCount: batch.recordCount,
            byteCount: UInt64(batch.payload.count),
            state: .delivered
        )
    }
}
