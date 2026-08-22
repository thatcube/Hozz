import Foundation
import HozzCore
import HozzHealth
import XCTest

/// Lets a test hold a suspension open and release it deliberately.
///
/// The coalescer's behaviour is entirely about *when* things overlap, so the
/// tests control the quiet window and the operation directly rather than
/// sleeping and hoping. Nothing here depends on wall-clock timing.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// Counts operation runs and the types each run was given.
private actor Recorder {
    private(set) var runs: [Set<HealthTypeKey>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []

    func record(_ types: Set<HealthTypeKey>) {
        runs.append(types)
        let pending = arrivals
        arrivals.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    var runCount: Int { runs.count }

    /// Waits until at least `count` runs have happened.
    func waitForRuns(_ count: Int) async {
        while runs.count < count {
            await withCheckedContinuation { continuation in
                arrivals.append(continuation)
            }
        }
    }
}

/// Tracks how many passes are inside `operation` at the same time.
private actor ConcurrencyProbe {
    private var current = 0
    private(set) var peak = 0

    /// Returns whether this is the first pass to enter.
    func enter() -> Bool {
        current += 1
        peak = max(peak, current)
        return current == 1 && peak == 1
    }

    func leave() {
        current -= 1
    }
}

/// Records whether a pass observed cancellation, and lets a test await it.
private actor Completion {
    private(set) var wasCancelled = false
    private var isFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func markCancelled(_ cancelled: Bool) {
        wasCancelled = cancelled
    }

    func finish() {
        isFinished = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func wait() async {
        if isFinished {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

final class SyncCoalescerTests: XCTestCase {
    private func key(_ raw: String) -> HealthTypeKey {
        guard let key = HealthTypeKey(rawValue: raw) else {
            preconditionFailure("Test key must be non-empty.")
        }
        return key
    }

    /// The core reason this type exists.
    ///
    /// HealthKit fires every observer at once after a Watch sync. Without
    /// coalescing that is one full sync pass per type, all contending for the
    /// same writer lease, for a single logical change.
    func testABurstOfRequestsRunsTheOperationOnce() async {
        let quietWindow = Gate()
        let recorder = Recorder()
        let coalescer = SyncCoalescer(
            sleep: { _ in await quietWindow.wait() },
            operation: { types in await recorder.record(types) }
        )

        // A burst arrives while the quiet window is still open.
        for index in 0..<36 {
            await coalescer.request(types: [key("type\(index)")])
        }
        await quietWindow.open()
        await recorder.waitForRuns(1)

        // Give any wrongly-scheduled extra passes a chance to show up.
        for _ in 0..<10 {
            await Task.yield()
        }

        let runs = await recorder.runs
        XCTAssertEqual(runs.count, 1, "A burst must collapse into one pass.")
        XCTAssertEqual(runs.first?.count, 36, "No dirty type may be dropped.")
    }

    /// Requests that land mid-pass must not be silently lost.
    ///
    /// The pass already running read its cursors before that data existed, so
    /// without a follow-up pass the new samples would wait for some unrelated
    /// future trigger — which for a quiet type could be days.
    func testARequestDuringAPassSchedulesExactlyOneMorePass() async {
        let quietWindow = Gate()
        await quietWindow.open()
        let firstPassStarted = Gate()
        let releaseFirstPass = Gate()
        let recorder = Recorder()

        let coalescer = SyncCoalescer(
            sleep: { _ in await quietWindow.wait() },
            operation: { types in
                let isFirst = await recorder.runCount == 0
                await recorder.record(types)
                if isFirst {
                    await firstPassStarted.open()
                    await releaseFirstPass.wait()
                }
            }
        )

        await coalescer.request(types: [key("stepCount")])
        await firstPassStarted.wait()

        // Three arrive while the first pass is still in flight.
        for _ in 0..<3 {
            await coalescer.request(types: [key("heartRate")])
        }
        await releaseFirstPass.open()
        await recorder.waitForRuns(2)
        for _ in 0..<10 {
            await Task.yield()
        }

        let runs = await recorder.runs
        XCTAssertEqual(runs.count, 2, "Three mid-pass requests must coalesce into one follow-up.")
        XCTAssertEqual(runs.last, [key("heartRate")], "The follow-up carries only the new work.")
    }

    /// The follow-up pass must not inherit the first pass's types, or a
    /// destination would be re-drained for data it already committed.
    func testTypesAreClaimedBeforeThePassRuns() async {
        let quietWindow = Gate()
        await quietWindow.open()
        let recorder = Recorder()
        let coalescer = SyncCoalescer(
            sleep: { _ in await quietWindow.wait() },
            operation: { types in await recorder.record(types) }
        )

        await coalescer.request(types: [key("stepCount")])
        await recorder.waitForRuns(1)
        await coalescer.request(types: [key("heartRate")])
        await recorder.waitForRuns(2)

        let runs = await recorder.runs
        XCTAssertEqual(runs, [[key("stepCount")], [key("heartRate")]])
    }

    /// Background refresh has a hard deadline and cannot spend it waiting.
    func testFlushRunsImmediatelyWithoutTheQuietWindow() async {
        let neverOpens = Gate()
        let recorder = Recorder()
        let coalescer = SyncCoalescer(
            sleep: { _ in await neverOpens.wait() },
            operation: { types in await recorder.record(types) }
        )

        await coalescer.request(types: [key("stepCount")])
        await coalescer.flush()

        let runs = await recorder.runs
        XCTAssertEqual(runs, [[key("stepCount")]], "Flush must not wait for the quiet window.")
    }

    func testFlushWithNothingPendingDoesNothing() async {
        let recorder = Recorder()
        let coalescer = SyncCoalescer(
            sleep: { _ in },
            operation: { types in await recorder.record(types) }
        )

        await coalescer.flush()

        let runCount = await recorder.runCount
        XCTAssertEqual(runCount, 0, "An empty flush must not start a pass.")
    }

    /// A pass must never start on its own; something has to have changed.
    func testNoRequestMeansNoPass() async {
        let recorder = Recorder()
        _ = SyncCoalescer(
            sleep: { _ in },
            operation: { types in await recorder.record(types) }
        )

        for _ in 0..<20 {
            await Task.yield()
        }

        let runCount = await recorder.runCount
        XCTAssertEqual(runCount, 0)
    }

    /// Regression: `cancel()` used to clear the worker slot while a pass was
    /// still running, so the next request started a second pass alongside it —
    /// exactly the concurrent writer contention this type prevents.
    func testCancelDuringAPassDoesNotAllowAConcurrentPass() async {
        let quietWindow = Gate()
        await quietWindow.open()
        let firstPassStarted = Gate()
        let releaseFirstPass = Gate()
        let concurrency = ConcurrencyProbe()

        let coalescer = SyncCoalescer(
            sleep: { _ in await quietWindow.wait() },
            operation: { _ in
                let isFirst = await concurrency.enter()
                if isFirst {
                    await firstPassStarted.open()
                    await releaseFirstPass.wait()
                }
                await concurrency.leave()
            }
        )

        await coalescer.request(types: [key("stepCount")])
        await firstPassStarted.wait()
        await coalescer.cancel()
        await coalescer.request(types: [key("heartRate")])
        for _ in 0..<20 {
            await Task.yield()
        }
        await releaseFirstPass.open()
        for _ in 0..<40 {
            await Task.yield()
        }

        let peak = await concurrency.peak
        XCTAssertEqual(peak, 1, "Two passes must never write at once.")
    }

    /// Regression: a pass already running was torn down by `cancel()` because
    /// it inherited the scheduled worker's cancellation. A half-finished sync
    /// is exactly what the durability rules exist to avoid.
    func testCancelDoesNotAbortAPassAlreadyRunning() async {
        let quietWindow = Gate()
        await quietWindow.open()
        let passStarted = Gate()
        let releasePass = Gate()
        let completed = Completion()

        let coalescer = SyncCoalescer(
            sleep: { _ in await quietWindow.wait() },
            operation: { _ in
                await passStarted.open()
                await releasePass.wait()
                await completed.markCancelled(Task.isCancelled)
                await completed.finish()
            }
        )

        await coalescer.request(types: [key("stepCount")])
        await passStarted.wait()
        await coalescer.cancel()
        await releasePass.open()
        await completed.wait()

        let wasCancelled = await completed.wasCancelled
        XCTAssertFalse(
            wasCancelled,
            "A pass already writing must run to completion."
        )
    }

    /// Regression: `flush()` left the scheduled worker parked, so when the
    /// quiet window elapsed it woke to an empty batch and ran a second,
    /// pointless full sync.
    func testFlushDoesNotLeaveAWorkerThatRunsARedundantPass() async {
        let quietWindow = Gate()
        let recorder = Recorder()
        let coalescer = SyncCoalescer(
            sleep: { _ in await quietWindow.wait() },
            operation: { types in await recorder.record(types) }
        )

        await coalescer.request(types: [key("stepCount")])
        await coalescer.flush()
        // Release the window the scheduled worker was sleeping on.
        await quietWindow.open()
        for _ in 0..<40 {
            await Task.yield()
        }

        let runs = await recorder.runs
        XCTAssertEqual(
            runs,
            [[key("stepCount")]],
            "Flushing must not leave a worker behind to run an empty pass."
        )
    }

    /// Work arriving during a flush still has to be delivered.
    func testFlushSchedulesAFollowUpForWorkArrivingDuringIt() async {
        let quietWindow = Gate()
        await quietWindow.open()
        let passStarted = Gate()
        let releasePass = Gate()
        let recorder = Recorder()

        let coalescer = SyncCoalescer(
            sleep: { _ in await quietWindow.wait() },
            operation: { types in
                let isFirst = await recorder.runCount == 0
                await recorder.record(types)
                if isFirst {
                    await passStarted.open()
                    await releasePass.wait()
                }
            }
        )

        await coalescer.request(types: [key("stepCount")])
        async let flushed: Void = coalescer.flush()
        await passStarted.wait()
        await coalescer.request(types: [key("heartRate")])
        await releasePass.open()
        await flushed
        await recorder.waitForRuns(2)

        let runs = await recorder.runs
        XCTAssertEqual(runs.last, [key("heartRate")])
    }

    func testCancelPreventsAScheduledPass() async {
        let quietWindow = Gate()
        let recorder = Recorder()
        let coalescer = SyncCoalescer(
            sleep: { _ in await quietWindow.wait() },
            operation: { types in await recorder.record(types) }
        )

        await coalescer.request(types: [key("stepCount")])
        await coalescer.cancel()
        await quietWindow.open()
        for _ in 0..<20 {
            await Task.yield()
        }

        let runCount = await recorder.runCount
        XCTAssertEqual(runCount, 0, "A cancelled pass must not run.")
    }
}
