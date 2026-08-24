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
}

/// What the store will and will not let a prime say about itself.
final class PrimeStoreTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")
    private let scope = AnchorScope.destination(
        UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var end: Date { start.addingTimeInterval(90 * 86_400) }

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
            windowEnd: end,
            chunkSeconds: PrimePlan.initialChunk
        )
    }

    func testAFreshPrimeClaimsNothing() async throws {
        let store = try makeStore()
        let record = try await seed(store)

        XCTAssertEqual(record.frontier, record.windowEnd)
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
                    frontier: moved,
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
            windowEnd: end.addingTimeInterval(3_600),
            chunkSeconds: PrimePlan.initialChunk
        )

        XCTAssertEqual(again.frontier, moved)
        XCTAssertEqual(again.windowEnd, end, "The window must not slide.")
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
                    frontier: moved,
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
                        frontier: moved.addingTimeInterval(86_400),
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
                        frontier: record.frontier.addingTimeInterval(-86_400),
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
                        baseFrontier: end,
                        frontier: start,
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
                    frontier: start,
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
                    frontier: start,
                    chunkSeconds: 86_400,
                    addedRecordCount: 30,
                    state: .covered
                )
            ],
            scope: scope
        )

        let laterEnd = end.addingTimeInterval(30 * 86_400)
        try await store.restartPrime(
            scope: scope,
            windowStart: start,
            windowEnd: laterEnd,
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
