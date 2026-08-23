import Foundation
import HozzAcquire
import HozzCore
import HozzDeliver
import HozzHealthFake
import HozzStore
import XCTest
@testable import HozzHealth

/// Pressing Export and being told an export is already running, when nothing
/// the person can see is running.
///
/// Reproduced before anything was changed, because the message is true from
/// the code's point of view and false from the user's, and only one of those
/// is the bug.
final class ExportLeaseTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private func upsert(_ identifier: String) -> HealthChange {
        .upsert(
            CapturedHealthObject(
                id: UUID(),
                type: steps,
                canonicalPayload: Data(
                    #"{"kind":"quantity","sample":"\#(identifier)"}"#.utf8
                )
            )
        )
    }

    // MARK: - The two ways it happens

    /// The likely one on Brandon's phone. Opening the app starts observing,
    /// which fires the observer, which requests a sync — and an automatic sync
    /// holds the same lease a manual export needs. He pressed Export a second
    /// later and was told an export was already running. None was: a *sync*
    /// was.
    func testAnExportWaitsForAnAutomaticSyncRatherThanRefusing() async throws {
        let lease = ExportWriterLease()
        let taken = await lease.acquire(for: .automaticSync)
        XCTAssertTrue(
            taken,
            "Stand in for the sync pass that opening the app kicks off."
        )

        let store = try makeStore()
        let engine = HealthExportEngine(
            store: store,
            source: ScriptedHealthDataSource(streams: [steps: [upsert("s-0")]]),
            types: [steps],
            lease: lease
        )

        // Pressed while the sync holds the lease. This used to fail at once,
        // saying an export was already running.
        async let outcome = engine.export(format: .ndjson) { _ in }

        // The sync finishes a moment later, as it would have anyway.
        try await Task.sleep(for: .milliseconds(120))
        await lease.release()

        guard case .completed = try await outcome else {
            return XCTFail("The export should have waited and then run.")
        }
    }

    /// A refusal must still be possible, or the app could hang on a genuinely
    /// stuck writer. It just has to name what is actually holding things up.
    func testAWaitThatRunsOutNamesWhatIsHoldingTheLease() async throws {
        let lease = ExportWriterLease()
        _ = await lease.acquire(for: .automaticSync)

        let taken = await lease.acquire(
            for: .manualExport,
            waitingUpTo: .milliseconds(50)
        )
        XCTAssertFalse(taken)

        let error = HealthExportEngineError.busy(.automaticSync)
        XCTAssertEqual(
            error.errorDescription,
            "Hozz is sending health data to your destinations. Hozz will export as soon as it finishes.",
            "The message must name the activity that exists, not an export that does not."
        )
    }

    /// The second way, and the one with nothing running at all: the lease is
    /// released in a detached task, so it outlives the export that held it by
    /// however long that task takes to be scheduled.
    func testTheLeaseOutlivesTheExportThatHeldIt() async throws {
        let lease = ExportWriterLease()
        let store = try makeStore()
        let engine = HealthExportEngine(
            store: store,
            source: ScriptedHealthDataSource(streams: [steps: [upsert("s-0")]]),
            types: [steps],
            lease: lease
        )

        let outcome = try await engine.export(format: .ndjson) { _ in }
        guard case .completed = outcome else {
            return XCTFail("The first export should have completed.")
        }

        // The export has returned. Nothing is running. The lease must be free
        // the instant its owner is finished with it, because that is when the
        // person is most likely to press the button again.
        let free = await lease.acquire()
        XCTAssertTrue(
            free,
            """
            The export finished but still held the lease, so pressing Export \
            again is refused with nothing running.
            """
        )
    }

    // MARK: - What the lease must still do

    /// Waiting replaced refusing, so the old check — that one of two exports
    /// is turned away — now measures the wrong thing: both are expected to
    /// finish. The hazard was never a second *caller*, it was a second
    /// *writer* on one spool, so this measures overlap directly.
    func testTwoExportsNeverWriteAtTheSameTime() async throws {
        let lease = ExportWriterLease()
        let store = try makeStore()
        let overlap = WriterOverlap()

        func makeEngine() -> HealthExportEngine {
            HealthExportEngine(
                store: store,
                source: ScriptedHealthDataSource(
                    streams: [steps: (0..<200).map { upsert("s-\($0)") }]
                ),
                types: [steps],
                batchSize: 1,
                lease: lease
            )
        }

        let engines = [makeEngine(), makeEngine()]
        await withTaskGroup(of: Void.self) { group in
            for engine in engines {
                group.addTask {
                    // Progress only fires while a run is actually being
                    // written, so it brackets the writing rather than the
                    // waiting that precedes it.
                    let token = UUID()
                    _ = try? await engine.export(format: .ndjson) { _ in
                        await overlap.writing(token)
                    }
                    await overlap.finished(token)
                }
            }
        }

        let peak = await overlap.peak
        XCTAssertEqual(
            peak,
            1,
            """
            Two writers were in a run at once. That is the hazard the lease             exists to stop: they pick the same next part sequence and unlink             each other's open file.
            """
        )
        let everWrote = await overlap.everWrote.count
        XCTAssertEqual(
            everWrote,
            2,
            "Both exports should have run, one after the other, not been refused."
        )
    }

    /// The background task has a scarce budget and no one watching it, and it
    /// already means to defer to whatever holds the writer. Waiting would
    /// spend that budget queueing for a run that is going to finish the job
    /// anyway, so a zero wait must be refused at once rather than timed out.
    func testAZeroWaitIsRefusedImmediatelyRatherThanQueueing() async throws {
        let lease = ExportWriterLease()
        let taken = await lease.acquire(for: .manualExport)
        XCTAssertTrue(taken, "The lease should start free.")

        let started = ContinuousClock.now
        let queued = await lease.acquire(for: .backgroundExport, waitingUpTo: .zero)
        let waited = ContinuousClock.now - started

        XCTAssertFalse(queued, "A zero wait cannot succeed while it is held.")
        XCTAssertLessThan(
            waited,
            .milliseconds(50),
            "It queued instead of standing aside."
        )
    }

    // MARK: - Telling the person what they are waiting for

    /// The screen can only say "waiting for the automatic sync" if the engine
    /// tells it that is what holds the writer. Showing an export at 0% while
    /// queued would be the same untruth in a friendlier font.
    func testTheWaitIsAnnouncedWithWhatIsHoldingTheWriter() async throws {
        let lease = ExportWriterLease()
        let store = try makeStore()
        let engine = HealthExportEngine(
            store: store,
            source: ScriptedHealthDataSource(streams: [steps: [upsert("s-0")]]),
            types: [steps],
            batchSize: 1,
            lease: lease
        )

        let announced = Announcements()
        let held = await lease.acquire(for: .automaticSync)
        XCTAssertTrue(held, "The sync should have taken the writer.")

        async let outcome = engine.export(
            format: .ndjson,
            waitingForWriter: { await announced.record($0) }
        ) { _ in }

        try await Task.sleep(for: .milliseconds(100))
        await lease.release()
        _ = try await outcome

        let owners = await announced.owners
        XCTAssertEqual(
            owners,
            [.automaticSync],
            """
            The person was not told what they were waiting for, or was told \
            about the wrong activity — which is the original bug: an automatic \
            sync held the writer and the message named an export.
            """
        )
    }

    /// The ordinary case must stay silent, or every export would flash a
    /// waiting screen it never actually waited on.
    func testNoWaitIsAnnouncedWhenTheWriterIsFree() async throws {
        let lease = ExportWriterLease()
        let store = try makeStore()
        let engine = HealthExportEngine(
            store: store,
            source: ScriptedHealthDataSource(streams: [steps: [upsert("s-0")]]),
            types: [steps],
            batchSize: 1,
            lease: lease
        )

        let announced = Announcements()
        _ = try await engine.export(
            format: .ndjson,
            waitingForWriter: { await announced.record($0) }
        ) { _ in }

        let owners = await announced.owners
        XCTAssertTrue(
            owners.isEmpty,
            "Nothing held the writer, so nothing should have been announced."
        )
    }

    private actor Announcements {
        private(set) var owners: [ExportWriterLease.Owner] = []

        func record(_ owner: ExportWriterLease.Owner) {
            owners.append(owner)
        }
    }

    /// Records how many exports were writing simultaneously.
    private actor WriterOverlap {
        private var inFlight: Set<UUID> = []
        private(set) var peak = 0
        private(set) var everWrote: Set<UUID> = []

        func writing(_ token: UUID) {
            guard everWrote.insert(token).inserted else {
                return
            }
            inFlight.insert(token)
            peak = max(peak, inFlight.count)
        }

        func finished(_ token: UUID) {
            inFlight.remove(token)
        }
    }

    func testTheLeaseIsFreeAgainAfterAFailedExport() async throws {
        let lease = ExportWriterLease()
        let store = try makeStore()
        let engine = HealthExportEngine(
            store: store,
            source: FailingSource(),
            types: [steps],
            lease: lease
        )

        _ = try? await engine.export(format: .ndjson) { _ in }

        let free = await lease.acquire()
        XCTAssertTrue(
            free,
            "An export that threw must not keep the lease for the rest of the process."
        )
    }
}

private struct FailingSource: HealthDataSource {
    struct Failure: Error {}

    func changes(
        for type: HealthTypeKey,
        after anchor: AnchorToken?,
        limit: Int
    ) async throws -> HealthChangeBatch {
        throw Failure()
    }
}
