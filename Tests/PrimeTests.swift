import Foundation
import HozzAcquire
import HozzCore
import HozzDeliver
import HozzHealth
import HozzHealthFake
import HozzStore
import XCTest

/// The chunk arithmetic, checked against numbers worked out here rather than
/// numbers the planner produced.
///
/// Every expected value below is written as a literal or as arithmetic on
/// literals. Asking `PrimePlan` what it thinks and then asserting it thinks
/// that would pass whatever it did, which is how three bugs got through their
/// own tests before this rule existed.
final class PrimePlanTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testAChunkEndsAtTheFrontierAndReachesBack() throws {
        let windowStart = origin
        let frontier = origin.addingTimeInterval(10 * 86_400)

        let chunk = try XCTUnwrap(
            PrimePlan.chunk(
                frontier: frontier,
                windowStart: windowStart,
                seconds: 3 * 86_400
            )
        )

        XCTAssertEqual(chunk.upperBound, frontier)
        XCTAssertEqual(
            chunk.lowerBound,
            Date(timeIntervalSince1970: 1_700_000_000 + 7 * 86_400),
            "Ten days back minus a three day chunk is seven days back."
        )
    }

    func testTheLastChunkStopsExactlyOnTheWindowStart() throws {
        let windowStart = origin
        let frontier = origin.addingTimeInterval(86_400)

        let chunk = try XCTUnwrap(
            PrimePlan.chunk(
                frontier: frontier,
                windowStart: windowStart,
                seconds: 30 * 86_400
            )
        )

        XCTAssertEqual(
            chunk.lowerBound,
            windowStart,
            """
            A final chunk that overshot would leave the frontier below the \
            window, and the app would claim to hold a month it never read.
            """
        )
    }

    func testAFinishedWalkHasNoNextChunk() {
        XCTAssertNil(
            PrimePlan.chunk(
                frontier: origin,
                windowStart: origin,
                seconds: 86_400
            )
        )
        XCTAssertNil(
            PrimePlan.chunk(
                frontier: origin.addingTimeInterval(-1),
                windowStart: origin,
                seconds: 86_400
            ),
            "A frontier past the start is finished, not owed another chunk."
        )
    }

    /// The property the whole design rests on: chunks abut exactly, so no
    /// instant belongs to two of them and none belongs to neither.
    func testChunksTileTheWindowWithNoSeamAndNoOverlap() {
        // Six hours rather than ninety days, with a density that drives the
        // chunk down to the shortest the planner will ask for. Small enough to
        // walk exhaustively, long enough that a seam has somewhere to hide.
        let windowStart = origin
        let windowEnd = origin.addingTimeInterval(6 * 3_600)

        var frontier = windowEnd
        var seconds = 600.0
        var boundaries: [Date] = [windowEnd]
        var ranOn = false

        while let chunk = PrimePlan.chunk(
            frontier: frontier,
            windowStart: windowStart,
            seconds: seconds
        ) {
            XCTAssertEqual(
                chunk.upperBound,
                frontier,
                "A chunk must start where the last one stopped."
            )
            frontier = chunk.lowerBound
            boundaries.append(frontier)
            seconds = PrimePlan.resized(seconds, after: 400)
            if boundaries.count > 1_000 {
                ranOn = true
                break
            }
        }

        XCTAssertFalse(ranOn, "The walk did not converge.")
        XCTAssertEqual(boundaries.first, windowEnd)
        XCTAssertEqual(
            boundaries.last,
            windowStart,
            "The walk must finish exactly on the window's start."
        )
        for (later, earlier) in zip(boundaries, boundaries.dropFirst()) {
            XCTAssertLessThan(
                earlier,
                later,
                "Every chunk must move the frontier backwards, or the walk stalls."
            )
        }
    }

    func testNarrowingQuartersTheChunkAndStopsAtTheMinimum() {
        XCTAssertEqual(PrimePlan.narrowed(86_400), 21_600, accuracy: 0.001)
        XCTAssertEqual(
            PrimePlan.narrowed(120),
            PrimePlan.minimumChunk,
            accuracy: 0.001,
            "Two minutes quartered is below the floor, so it lands on the floor."
        )
        XCTAssertEqual(
            PrimePlan.narrowed(PrimePlan.minimumChunk),
            PrimePlan.minimumChunk,
            accuracy: 0.001
        )
        XCTAssertTrue(PrimePlan.isAtMinimum(PrimePlan.minimumChunk))
        XCTAssertFalse(PrimePlan.isAtMinimum(PrimePlan.minimumChunk * 10))
    }

    func testAChunkIsResizedTowardsTheTargetFill() {
        // A day that yielded 250 records against a 500 record bite: the aim is
        // 70% of 500, which is 350, so the next chunk wants 350/250 = 1.4 days.
        XCTAssertEqual(
            PrimePlan.resized(86_400, after: 250, capacity: 500),
            86_400 * 1.4,
            accuracy: 0.001
        )
        // Overfull the other way: 1000 records in a day wants 350/1000 of one.
        XCTAssertEqual(
            PrimePlan.resized(86_400, after: 1_000, capacity: 500),
            86_400 * 0.35,
            accuracy: 0.001
        )
    }

    func testResizingIsClampedInBothDirections() {
        // 350/10 is 35, far above the growth cap of 8.
        XCTAssertEqual(
            PrimePlan.resized(86_400, after: 10, capacity: 500),
            86_400 * 8,
            accuracy: 0.001
        )
        // 350/100000 is a tiny fraction, below the shrink floor of a quarter.
        XCTAssertEqual(
            PrimePlan.resized(86_400, after: 100_000, capacity: 500),
            86_400 * 0.25,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PrimePlan.resized(0, after: 0, capacity: 500),
            PrimePlan.minimumChunk * 8,
            accuracy: 0.001,
            "A nonsense length is treated as the shortest one, not as itself."
        )
    }

    func testAnEmptyChunkGrowsButNotWithoutBound() {
        XCTAssertEqual(
            PrimePlan.resized(86_400, after: 0, capacity: 500),
            86_400 * 8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            PrimePlan.resized(PrimePlan.maximumChunk, after: 0, capacity: 500),
            PrimePlan.maximumChunk,
            accuracy: 0.001,
            """
            An empty year says nothing about the year before it. Unbounded \
            growth would leap a decade in one chunk and immediately overflow.
            """
        )
    }

    func testTheDefaultWindowIsNinetyDaysEndingNow() {
        let now = origin
        let window = PrimePlan.window(endingAt: now)

        XCTAssertEqual(window.end, now)
        XCTAssertEqual(
            window.start,
            Date(timeIntervalSince1970: 1_700_000_000 - 7_776_000),
            "Ninety days is 7,776,000 seconds."
        )
    }

    // MARK: - The leading edge

    func testATopUpChunkStartsWhereTheCoveredStretchEnds() throws {
        let coveredThrough = origin
        let chunk = try XCTUnwrap(
            PrimePlan.topUp(
                coveredThrough: coveredThrough,
                ceiling: origin.addingTimeInterval(10 * 86_400),
                seconds: 3 * 86_400
            )
        )

        XCTAssertEqual(
            chunk.lowerBound,
            coveredThrough,
            """
            A top-up must abut what is already covered. A gap between them \
            would leave the claimed stretch discontinuous while still being \
            reported as one window.
            """
        )
        XCTAssertEqual(
            chunk.upperBound,
            Date(timeIntervalSince1970: 1_700_000_000 + 3 * 86_400)
        )
    }

    func testATopUpNeverReadsPastTheMomentItWasAskedAbout() throws {
        let ceiling = origin.addingTimeInterval(600)
        let chunk = try XCTUnwrap(
            PrimePlan.topUp(
                coveredThrough: origin,
                ceiling: ceiling,
                seconds: 30 * 86_400
            )
        )

        XCTAssertEqual(
            chunk.upperBound,
            ceiling,
            "Reading into the future would claim a stretch that has not happened."
        )
    }

    func testACaughtUpEdgeHasNothingToTopUp() {
        XCTAssertNil(
            PrimePlan.topUp(
                coveredThrough: origin,
                ceiling: origin,
                seconds: 86_400
            )
        )
        XCTAssertNil(
            PrimePlan.topUp(
                coveredThrough: origin.addingTimeInterval(1),
                ceiling: origin,
                seconds: 86_400
            )
        )
    }

    /// A chunk cut short by an edge is not a measurement of density.
    ///
    /// Five minutes of a dense type holds few records because it is five
    /// minutes. Sized from that count, the next chunk would grow eightfold and
    /// then have to be narrowed back a query at a time — on exactly the dense
    /// types the prime exists for.
    func testAChunkCutShortByAnEdgeIsNotTreatedAsAMeasurement() throws {
        let fullBackfill = try XCTUnwrap(
            PrimePlan.chunk(
                frontier: origin,
                windowStart: origin.addingTimeInterval(-90 * 86_400),
                seconds: 86_400
            )
        )
        XCTAssertTrue(PrimePlan.isFullLength(fullBackfill, seconds: 86_400))

        // The last chunk of a backfill, clamped by the window's start.
        let clippedBackfill = try XCTUnwrap(
            PrimePlan.chunk(
                frontier: origin,
                windowStart: origin.addingTimeInterval(-600),
                seconds: 86_400
            )
        )
        XCTAssertFalse(PrimePlan.isFullLength(clippedBackfill, seconds: 86_400))

        // A top-up clamped by the moment it was asked about, which is the
        // common case: the edge is usually only minutes stale.
        let clippedTopUp = try XCTUnwrap(
            PrimePlan.topUp(
                coveredThrough: origin,
                ceiling: origin.addingTimeInterval(300),
                seconds: 86_400
            )
        )
        XCTAssertFalse(PrimePlan.isFullLength(clippedTopUp, seconds: 86_400))
    }

    /// The two walks meet without overlapping and without a seam.
    func testTheBackfillAndTheTopUpShareOneEdgeExactly() throws {
        let started = origin
        let backfill = try XCTUnwrap(
            PrimePlan.chunk(
                frontier: started,
                windowStart: started.addingTimeInterval(-90 * 86_400),
                seconds: 86_400
            )
        )
        let topUp = try XCTUnwrap(
            PrimePlan.topUp(
                coveredThrough: started,
                ceiling: started.addingTimeInterval(600),
                seconds: 86_400
            )
        )

        XCTAssertEqual(
            backfill.upperBound,
            topUp.lowerBound,
            """
            Both walks start from the instant the prime began. The backfill \
            excludes that instant and the top-up includes it, so a sample \
            recorded exactly then belongs to precisely one of them.
            """
        )
    }
}

/// What the store will and will not let a prime say about itself.
final class PrimeStoreTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")
    private let scope = AnchorScope.destination(
        UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var startedAt: Date { start.addingTimeInterval(90 * 86_400) }

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private func seed(_ store: HozzStore) async throws -> PrimeRecord {
        try await store.beginPrime(
            scope: scope,
            type: steps,
            windowStart: start,
            startedAt: startedAt,
            chunkSeconds: PrimePlan.initialChunk
        )
    }

    func testAFreshPrimeClaimsNothing() async throws {
        let store = try makeStore()
        let record = try await seed(store)

        XCTAssertEqual(record.frontier, record.startedAt)
        XCTAssertEqual(record.coveredThrough, record.startedAt)
        XCTAssertNil(
            record.coveredWindow,
            """
            A prime that has delivered nothing must report no window at all. \
            A zero-length one reads as "yes, a window exists" to anything \
            asking, and that is a density claim about no time whatsoever.
            """
        )
        XCTAssertEqual(record.state, .priming)
    }

    func testSeedingTwiceDoesNotRestartTheWalk() async throws {
        let store = try makeStore()
        let first = try await seed(store)
        let moved = first.frontier.addingTimeInterval(-10 * 86_400)

        try await store.commit(
            [],
            prime: [
                PendingPrimeCommit(
                    type: steps,
                    baseFrontier: first.frontier,
                    baseCoveredThrough: first.coveredThrough,
                    frontier: moved,
                    coveredThrough: first.coveredThrough,
                    chunkSeconds: 86_400,
                    addedRecordCount: 12,
                    state: .priming
                )
            ],
            scope: scope
        )

        // Seeding runs on every pass, so this is the ordinary case rather than
        // an odd one: an eager version would reset the frontier every time a
        // pass began and the walk would never reach the start of the window.
        let again = try await store.beginPrime(
            scope: scope,
            type: steps,
            windowStart: start,
            startedAt: startedAt.addingTimeInterval(3_600),
            chunkSeconds: PrimePlan.initialChunk
        )

        XCTAssertEqual(again.frontier, moved)
        XCTAssertEqual(
            again.startedAt,
            startedAt,
            "The instant the walk is measured from must not slide."
        )
        XCTAssertEqual(again.deliveredCount, 12)
    }

    func testAFrontierMayNotMoveForwardsThroughTime() async throws {
        let store = try makeStore()
        let record = try await seed(store)
        let moved = record.frontier.addingTimeInterval(-10 * 86_400)

        try await store.commit(
            [],
            prime: [
                PendingPrimeCommit(
                    type: steps,
                    baseFrontier: record.frontier,
                    baseCoveredThrough: record.coveredThrough,
                    frontier: moved,
                    coveredThrough: record.coveredThrough,
                    chunkSeconds: 86_400,
                    addedRecordCount: 4,
                    state: .priming
                )
            ],
            scope: scope
        )

        do {
            try await store.commit(
                [],
                prime: [
                    PendingPrimeCommit(
                        type: steps,
                        baseFrontier: moved,
                        baseCoveredThrough: record.coveredThrough,
                        frontier: moved.addingTimeInterval(86_400),
                        coveredThrough: record.coveredThrough,
                        chunkSeconds: 86_400,
                        addedRecordCount: 0,
                        state: .priming
                    )
                ],
                scope: scope
            )
            XCTFail(
                """
                A frontier that moved forwards would abandon a stretch already \
                delivered while still claiming it.
                """
            )
        } catch let error as HozzStoreError {
            XCTAssertEqual(error, .stalePrimeFrontier(type: steps.rawValue))
        }

        let after = try await store.primeRecord(scope: scope, type: steps)
        XCTAssertEqual(after?.frontier, moved)
    }

    func testAnAdvanceFromAStaleFrontierIsRefused() async throws {
        let store = try makeStore()
        let record = try await seed(store)

        do {
            try await store.commit(
                [],
                prime: [
                    PendingPrimeCommit(
                        type: steps,
                        baseFrontier: record.frontier.addingTimeInterval(-1),
                        baseCoveredThrough: record.coveredThrough,
                        frontier: record.frontier.addingTimeInterval(-86_400),
                        coveredThrough: record.coveredThrough,
                        chunkSeconds: 86_400,
                        addedRecordCount: 3,
                        state: .priming
                    )
                ],
                scope: scope
            )
            XCTFail("An advance computed from a frontier nobody holds must fail.")
        } catch let error as HozzStoreError {
            XCTAssertEqual(error, .stalePrimeFrontier(type: steps.rawValue))
        }
    }

    func testAnAdvanceForATypeWithNoWindowIsRefused() async throws {
        let store = try makeStore()

        do {
            try await store.commit(
                [],
                prime: [
                    PendingPrimeCommit(
                        type: steps,
                        baseFrontier: startedAt,
                        baseCoveredThrough: startedAt,
                        frontier: start,
                        coveredThrough: startedAt,
                        chunkSeconds: 86_400,
                        addedRecordCount: 1,
                        state: .covered
                    )
                ],
                scope: scope
            )
            XCTFail("There is no window to advance.")
        } catch let error as HozzStoreError {
            XCTAssertEqual(error, .unknownPrime(type: steps.rawValue))
        }
    }

    /// Anchors and frontiers travel together and stay separate.
    func testOneTransactionCarriesBothCursorsWithoutMixingThem() async throws {
        let store = try makeStore()
        let record = try await seed(store)
        let anchor = AnchorToken(data: Data([0xAB, 0xCD]))

        try await store.commit(
            [
                PendingAnchorCommit(
                    type: steps,
                    baseAnchor: nil,
                    anchor: anchor,
                    coverage: .draining,
                    addedRecordCount: 7,
                    addedObservedCount: 7
                )
            ],
            prime: [
                PendingPrimeCommit(
                    type: steps,
                    baseFrontier: record.frontier,
                    baseCoveredThrough: record.coveredThrough,
                    frontier: start,
                    coveredThrough: record.coveredThrough,
                    chunkSeconds: 86_400,
                    addedRecordCount: 20,
                    state: .covered
                )
            ],
            scope: scope
        )

        let stream = try await store.streamRecord(scope: scope, type: steps)
        let prime = try await store.primeRecord(scope: scope, type: steps)

        XCTAssertEqual(stream?.committedAnchor, anchor)
        XCTAssertEqual(
            stream?.recordCount,
            7,
            "The sweep's count must not absorb the prime's twenty records."
        )
        XCTAssertEqual(prime?.frontier, start)
        XCTAssertEqual(prime?.deliveredCount, 20)
        XCTAssertEqual(prime?.state, .covered)
    }

    func testARestartPointsTheWalkAtAFreshWindow() async throws {
        let store = try makeStore()
        let record = try await seed(store)
        try await store.commit(
            [],
            prime: [
                PendingPrimeCommit(
                    type: steps,
                    baseFrontier: record.frontier,
                    baseCoveredThrough: record.coveredThrough,
                    frontier: start,
                    coveredThrough: record.coveredThrough,
                    chunkSeconds: 86_400,
                    addedRecordCount: 30,
                    state: .covered
                )
            ],
            scope: scope
        )

        let laterEnd = startedAt.addingTimeInterval(30 * 86_400)
        try await store.restartPrime(
            scope: scope,
            windowStart: start,
            startedAt: laterEnd,
            chunkSeconds: PrimePlan.initialChunk
        )

        let after = try await store.primeRecord(scope: scope, type: steps)
        XCTAssertEqual(after?.state, .priming)
        XCTAssertEqual(
            after?.frontier,
            laterEnd,
            """
            A restart must stop claiming the old window immediately. Keeping \
            the frontier while re-reading would assert coverage of a window \
            the app has just decided it is not sure about.
            """
        )
        XCTAssertEqual(after?.coveredThrough, laterEnd)
        XCTAssertNil(after?.coveredWindow)
        XCTAssertEqual(after?.deliveredCount, 0)
    }

    func testForgettingADestinationsHistoryForgetsItsPrime() async throws {
        let store = try makeStore()
        _ = try await seed(store)

        // What happens when a destination's history is about to replay.
        try await store.deleteStreamState(scope: scope)

        let after = try await store.primeRecord(scope: scope, type: steps)
        XCTAssertNil(
            after,
            """
            A frontier left behind would go on asserting that a window had \
            been delivered to a destination that has just been told it holds \
            none of it.
            """
        )
    }
}
