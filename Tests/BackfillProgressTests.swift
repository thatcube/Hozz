import Foundation
import HozzCore
import HozzDeliver
import HozzHealth
import HozzHealthFake
import HozzStore
import XCTest
@testable import Hozz

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
    /// Drives the real counting rather than a copy of it. A test that
    /// reimplements the arithmetic only proves the copy agrees with itself.
    private func progress(
        store: HozzStore,
        destination: Destination,
        everything: Set<HealthTypeKey>
    ) async throws -> SyncViewModel.BackfillProgress {
        let streams = try await store.streamRecords(
            scope: .destination(destination.id)
        )
        return try XCTUnwrap(
            SyncViewModel.backfillProgress(
                gathered: [(destination: destination, streams: streams)],
                everything: everything
            )
        )
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
            destination: destination,
            everything: [stand, heart, steps]
        )
        // Since the drain gives every type a share before spending the
        // remainder, all three are seen in the first pass rather than two of
        // them waiting for the big one to finish.
        XCTAssertEqual(
            after.typesStarted,
            3,
            "Every type should be seen in the first pass, not just the first one."
        )
        XCTAssertEqual(after.recordsDelivered, 5_000, "One pass is bounded at 5,000.")

        // The point of the test still stands: being seen is not being
        // finished, and the big type must not claim to be caught up.
        let big = try await store.streamRecord(
            scope: .destination(destination.id),
            type: stand
        )
        XCTAssertEqual(big?.coverage, .draining)
        XCTAssertNil(
            big?.anchorClosedAt,
            "Fifteen thousand records still to come is not a closed type."
        )
        let small = try await store.streamRecord(
            scope: .destination(destination.id),
            type: heart
        )
        XCTAssertEqual(small?.recordCount, 5)
    }

    /// Progress has to be visible between passes, or it is not progress.
    /// It shows in the record count rather than in the reached count, because
    /// every type is now reached in the first pass.
    func testProgressClimbsBetweenPasses() async throws {
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
            destination: destination,
            everything: [stand, heart, steps]
        )

        _ = try await engine.sync(
            ignoringCadence: true,
            now: Date(timeIntervalSinceNow: 3_600)
        )
        let second = try await progress(
            store: store,
            destination: destination,
            everything: [stand, heart, steps]
        )

        XCTAssertEqual(
            first.typesStarted,
            3,
            "Every type is reached in the first pass now that the budget is shared."
        )
        XCTAssertEqual(second.typesStarted, 3)
        XCTAssertGreaterThan(
            second.recordsDelivered,
            first.recordsDelivered,
            "Progress now shows in the record count rather than in types waiting their turn."
        )

        // The big type is only closed once it genuinely runs out.
        let big = try await store.streamRecord(
            scope: .destination(destination.id),
            type: stand
        )
        XCTAssertEqual(big?.coverage, .anchorClosed)
        XCTAssertNotNil(big?.anchorClosedAt)
    }

    // MARK: - What complete means

    private func stream(
        _ type: HealthTypeKey,
        records: Int,
        closed: Bool
    ) -> StreamRecord {
        StreamRecord(
            type: type,
            coverage: closed
                ? (records == 0 ? .authorizationIndeterminate : .anchorClosed)
                : .draining,
            committedAnchor: AnchorToken(data: Data([1])),
            recordCount: records,
            observedCount: records,
            anchorClosedAt: closed ? Date(timeIntervalSince1970: 1) : nil,
            failureReason: nil,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    /// Someone who never narrowed their selection used to see no progress at
    /// all, because "no types named" was read as "no types wanted" rather than
    /// as "every type".
    func testADestinationThatWantsEverythingStillShowsProgress() throws {
        let destination = Destination(
            name: "Mac",
            kind: .folder,
            folderBookmark: Data("a".utf8)
        )

        let progress = try XCTUnwrap(
            SyncViewModel.backfillProgress(
                gathered: [
                    (
                        destination,
                        [
                            stream(heart, records: 5, closed: true),
                            stream(stand, records: 900, closed: false)
                        ]
                    )
                ],
                everything: [heart, stand, steps]
            )
        )

        XCTAssertEqual(progress.typesSelected, 3)
        XCTAssertEqual(progress.typesComplete, 1)
        XCTAssertEqual(
            progress.typesStarted,
            2,
            "Started counts what has been read; the third has not been touched."
        )
        XCTAssertTrue(progress.isUnderway)
    }

    /// Data still owed to one destination is data still owed, however far the
    /// others have got.
    func testATypeIsCompleteOnlyWhenEveryDestinationHasFinishedIt() throws {
        let finished = Destination(
            name: "Mac",
            kind: .folder,
            folderBookmark: Data("a".utf8),
            includedTypes: [heart]
        )
        let behind = Destination(
            name: "Folder",
            kind: .folder,
            folderBookmark: Data("b".utf8),
            includedTypes: [heart]
        )

        let progress = try XCTUnwrap(
            SyncViewModel.backfillProgress(
                gathered: [
                    (finished, [stream(heart, records: 10, closed: true)]),
                    (behind, [stream(heart, records: 4, closed: false)])
                ],
                everything: [heart]
            )
        )

        XCTAssertEqual(progress.typesSelected, 1)
        XCTAssertEqual(
            progress.typesComplete,
            0,
            "One destination still owed the rest means the type is not done."
        )
        XCTAssertEqual(progress.typesStarted, 1)
        XCTAssertEqual(progress.recordsDelivered, 14)
    }

    /// A type Health answered for with nothing is a complete export of
    /// nothing, and must not sit forever as an unreached type.
    func testATypeWithNoDataCountsAsCompleteRatherThanPending() async throws {
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
            destination: destination,
            everything: [heart, steps]
        )
        XCTAssertEqual(after.recordsDelivered, 3)
        XCTAssertEqual(
            after.typesComplete,
            2,
            "Both ran out: one with records, one with none. Both are finished."
        )
        XCTAssertEqual(
            after.typesEmpty,
            1,
            "An empty type is a complete export of nothing, not an unreached one."
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
            folderBookmark: Data("a".utf8),
            includedTypes: [heart]
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
            destination: destination,
            everything: [heart, steps]
        )
        XCTAssertEqual(
            narrowed.typesSelected,
            1,
            "The denominator is what this destination wants, not what exists."
        )
        XCTAssertLessThanOrEqual(narrowed.typesStarted, 1)
        XCTAssertEqual(
            narrowed.recordsDelivered,
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

/// What a pass tells somebody watching it.
///
/// "Up to date" is a claim about their whole history, and it is the easiest
/// sentence in the app to make untrue: a pass that read an empty stretch of the
/// last few months and sent nothing has not finished anything.
@MainActor
final class SyncSummaryTests: XCTestCase {
    private func outcome(
        delivered: Int,
        primed: Int = 0,
        primingRemains: Bool = false,
        waitingForUnlock: Bool = false
    ) -> SyncOutcome {
        SyncOutcome(
            deliveredRecords: delivered,
            destinationCount: 1,
            typesDrained: 1,
            wasInterrupted: false,
            waitingForUnlock: waitingForUnlock,
            primedRecords: primed,
            primingRemains: primingRemains
        )
    }

    func testAQuietPassWhileStillFetchingDoesNotClaimToBeFinished() {
        let summary = SyncViewModel.describe(
            outcome(delivered: 0, primingRemains: true)
        )

        XCTAssertFalse(
            summary.contains("up to date"),
            """
            Telling somebody their history has arrived at the exact moment it \
            has not is the whole failure this app is trying to avoid.
            """
        )
        XCTAssertTrue(summary.contains("still arriving"))
    }

    func testAQuietPassWithNothingLeftToFetchMaySaySo() {
        XCTAssertEqual(
            SyncViewModel.describe(outcome(delivered: 0)),
            "Already up to date."
        )
    }

    func testAPassSaysHowMuchOfWhatItSentWasRecentHistory() {
        XCTAssertEqual(
            SyncViewModel.describe(outcome(delivered: 1_200, primed: 900)),
            "Sent 1,200 records. 900 from recent months."
        )
        XCTAssertEqual(
            SyncViewModel.describe(outcome(delivered: 40)),
            "Sent 40 records.",
            "With no dated records there is nothing to single out."
        )
    }

    /// A pass that failed has established nothing, least of all completeness.
    ///
    /// Every destination throwing looks from the outside exactly like a quiet
    /// pass — no records, nothing outstanding — and the sentence that fits a
    /// quiet pass is the strongest claim in the app.
    func testAPassThatWasCutShortDoesNotClaimToHaveFinished() {
        let cutShort = SyncOutcome(
            deliveredRecords: 0,
            destinationCount: 1,
            typesDrained: 0,
            wasInterrupted: true,
            waitingForUnlock: false
        )

        let summary = SyncViewModel.describe(cutShort)
        XCTAssertFalse(
            summary.contains("up to date"),
            "Nothing was established, so nothing may be claimed."
        )
        XCTAssertTrue(summary.contains("stopped early"))
    }

    func testALockedPhoneIsSaidToBeLockedRatherThanIdle() {
        XCTAssertEqual(
            SyncViewModel.describe(
                outcome(delivered: 0, primingRemains: true, waitingForUnlock: true)
            ),
            "Unlock this iPhone to continue."
        )
    }
}
