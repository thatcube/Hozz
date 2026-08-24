import Foundation
import HozzAcquire
import HozzCore
import HozzDeliver
import HozzHealth
import HozzHealthFake
import HozzStore
import XCTest

/// Records what a destination actually received, so a test can assert on what
/// arrived rather than on what the engine says it sent.
private actor PrimeRecordingChannel: DeliveryChannel {
    private var payloads: [UUID: [Data]] = [:]
    private var failing: Set<UUID> = []

    func fail(_ destinationID: UUID) {
        failing.insert(destinationID)
    }

    func recover(_ destinationID: UUID) {
        failing.remove(destinationID)
    }

    /// The last coverage line sent for one type, as the bytes that actually
    /// went out. Kept as bytes rather than decoded here so what crosses back is
    /// exactly what crossed the wire.
    func coverageLine(
        for destinationID: UUID,
        type: HealthTypeKey
    ) -> Data? {
        payloads[destinationID, default: []]
            .flatMap { payload in
                String(decoding: payload, as: UTF8.self)
                    .split(separator: "\n")
                    .map { Data($0.utf8) }
            }
            .last { line in
                guard
                    let object = try? JSONSerialization.jsonObject(with: line)
                        as? [String: Any]
                else {
                    return false
                }
                return (object["kind"] as? String) == "typeCoverage"
                    && (object["type"] as? String) == type.rawValue
            }
    }

    /// Every sample name this destination has been sent, repeats included.
    func sampleNames(for destinationID: UUID) -> [String] {
        payloads[destinationID, default: []].flatMap { payload in
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

/// The recent-first prime, from the outside.
///
/// The fixtures below are laid out by hand and every expected answer is worked
/// out from those literals — which samples fall inside ninety days is decided
/// by arithmetic written in the test, never by asking the planner or the engine
/// what it thinks the window is. A test that asks the code under test for its
/// own expectations passes whatever the code does.
final class PrimeSyncTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")
    private let route = HealthTypeKey("HKWorkoutRouteTypeIdentifier")

    /// A fixed instant, so a run at midnight behaves like a run at noon.
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private func change(_ name: String, type: HealthTypeKey, at date: Date) -> HealthChange {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let payload: [String: Any] = [
            "kind": "quantity",
            "id": UUID().uuidString.lowercased(),
            "type": type.rawValue,
            "startDate": formatter.string(from: date),
            "endDate": formatter.string(from: date),
            "sample": name
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

    /// A sample every twelve hours going back two hundred days from `now`,
    /// starting twelve hours ago.
    ///
    /// Two hundred days on purpose: more than twice the window, so anything
    /// that quietly read outside it shows up as a name the test never expected.
    /// Nothing sits at or after `now`, so these fixtures exercise the backfill
    /// alone; the leading edge has tests of its own that add samples later.
    private func history() -> [ScriptedDatedSample] {
        (0..<400).map { index in
            let date = now.addingTimeInterval(-Double(index + 1) * 12 * 3_600)
            return ScriptedDatedSample(
                change: change("h\(index)", type: steps, at: date),
                start: date
            )
        }
    }

    /// The names a ninety day window holds, worked out here from the literals
    /// above rather than from anything the code under test believes.
    ///
    /// Sample `i` sits `12(i + 1)` hours before `now`, and the window is
    /// `[now - 90 days, now)`. So `i` is held when `12(i + 1) <= 2160`, which
    /// is every `i` from 0 to 179 — and `h179` sits exactly ninety days back,
    /// on the window's inclusive edge. Getting that edge wrong in either
    /// direction is how a record falls between two abutting chunks, so the
    /// boundary has a test of its own as well.
    private var namesInWindow: Set<String> {
        Set((0..<180).map { "h\($0)" })
    }

    /// A busier fixture: enough records inside the window that one pass's
    /// budget cannot finish the backfill.
    ///
    /// Needed because most of what the prime does happens *during* a backfill
    /// that spans passes, and a fixture small enough to finish in one pass
    /// silently skips that whole state.
    private func denseHistory() -> [ScriptedDatedSample] {
        // Fifty a day for ninety days is 4,500 — comfortably past the 3,750 a
        // single pass will spend on priming.
        (0..<(90 * 50)).map { index in
            let date = now.addingTimeInterval(
                -Double(index + 1) * (86_400 / 50)
            )
            return ScriptedDatedSample(
                change: change("d\(index)", type: steps, at: date),
                start: date
            )
        }
    }

    /// The name inside a scripted sample, read back out of its payload.
    private func name(of sample: ScriptedDatedSample) -> String? {
        guard case .upsert(let object) = sample.change else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: object.canonicalPayload))
            .flatMap { $0 as? [String: Any] }?["sample"] as? String
    }

    private func makeDestination(
        _ delivery: DeliveryEngine,
        name: String = "Folder"
    ) async throws -> Destination {
        let destination = Destination(
            name: name,
            kind: .folder,
            cadence: .whenDataArrives,
            folderBookmark: Data("a".utf8)
        )
        try await delivery.save(destination)
        return destination
    }

    private func makeEngine(
        store: HozzStore,
        delivery: DeliveryEngine,
        sweep: ScriptedHealthDataSource,
        dated: ScriptedDatedHealthDataSource?,
        types: [HealthTypeKey]? = nil
    ) -> HealthSyncEngine {
        HealthSyncEngine(
            store: store,
            source: sweep,
            delivery: delivery,
            types: types ?? [steps],
            datedSource: dated,
            lease: ExportWriterLease()
        )
    }

    /// Runs a pass inside its own task, so a fault that cancels the pass
    /// cancels only the pass and not the test running it.
    @discardableResult
    private func pass(
        _ engine: HealthSyncEngine,
        at date: Date
    ) async -> SyncOutcome? {
        await Task { try? await engine.sync(ignoringCadence: true, now: date) }
            .value
    }

    /// The scripted sweep encodes its cursor as a big-endian offset into the
    /// stream, so an anchor can be read back as "how many records the sweep
    /// has consumed" and compared with a number this test knows.
    private func offset(of anchor: AnchorToken?) throws -> Int {
        let anchor = try XCTUnwrap(anchor)
        XCTAssertEqual(anchor.data.count, 8)
        return Int(anchor.data.reduce(UInt64.zero) { ($0 << 8) | UInt64($1) })
    }

    // MARK: - The invariant

    /// The one thing that must not go wrong.
    ///
    /// If a prime advanced an anchor, every record older than the primed window
    /// would be skipped by the sweep permanently. The sweep's stream here holds
    /// exactly three records, so its anchor must come to rest at exactly three
    /// however many hundreds of records the prime moves alongside it.
    func testAPrimeNeverMovesAnAnchor() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)

        let sweep = ScriptedHealthDataSource(
            streams: [
                steps: (0..<3).map {
                    change("s\($0)", type: steps, at: now)
                }
            ]
        )
        let dated = ScriptedDatedHealthDataSource(samples: [steps: history()])
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: sweep,
            dated: dated
        )

        await pass(engine, at: now)

        let scope = AnchorScope.destination(destination.id)
        let stream = try await store.streamRecord(scope: scope, type: steps)
        XCTAssertEqual(
            try offset(of: stream?.committedAnchor),
            3,
            """
            The scripted sweep holds three records, so its cursor belongs at \
            three. Anything else means the prime's hundreds of dated records \
            moved the anchor, and everything they passed over is lost forever.
            """
        )
        XCTAssertEqual(
            stream?.recordCount,
            3,
            "The sweep's own count must not absorb the prime's records."
        )

        // And again on a later pass, where the sweep has nothing new at all and
        // only the prime does any work.
        await pass(engine, at: now.addingTimeInterval(600))

        let later = try await store.streamRecord(scope: scope, type: steps)
        XCTAssertEqual(try offset(of: later?.committedAnchor), 3)
        XCTAssertEqual(later?.recordCount, 3)
    }

    /// The same invariant when iOS takes its time back halfway through.
    func testACancelledPrimeLeavesTheAnchorExactlyWhereItWas() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)
        let scope = AnchorScope.destination(destination.id)

        let sweep = ScriptedHealthDataSource(
            streams: [
                steps: (0..<3).map { change("s\($0)", type: steps, at: now) }
            ]
        )
        let dated = ScriptedDatedHealthDataSource(samples: [steps: history()])
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: sweep,
            dated: dated
        )

        await pass(engine, at: now)
        let before = try await store.streamRecord(scope: scope, type: steps)
        let anchorBefore = try XCTUnwrap(before?.committedAnchor)

        // The second dated read of the next pass cancels the pass, which is
        // what a background launch being cut short looks like from inside.
        await dated.setFaults([2: .cancelTask], for: steps)
        await pass(engine, at: now.addingTimeInterval(600))

        let after = try await store.streamRecord(scope: scope, type: steps)
        XCTAssertEqual(
            after?.committedAnchor,
            anchorBefore,
            """
            A prime cut off midway must leave the sweep's cursor untouched. \
            An anchor nudged by an interrupted prime skips whatever it passed.
            """
        )
        XCTAssertEqual(try offset(of: after?.committedAnchor), 3)
    }

    // MARK: - What a prime delivers

    func testAPrimeDeliversTheWindowAndNothingOlder() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)

        // An empty sweep, so everything that arrives arrived by date.
        let sweep = ScriptedHealthDataSource(streams: [steps: []])
        let dated = ScriptedDatedHealthDataSource(samples: [steps: history()])
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: sweep,
            dated: dated
        )

        for index in 0..<6 {
            await pass(engine, at: now.addingTimeInterval(Double(index) * 600))
        }

        let names = Set(await channel.sampleNames(for: destination.id))
        XCTAssertEqual(
            names,
            namesInWindow,
            """
            Everything inside ninety days, and nothing outside it. Older \
            records are the sweep's job; delivering them here would make the \
            window's edges meaningless.
            """
        )
    }

    /// A window is a claim that everything in it is present. It has to be true
    /// at the boundary too, or the claim is only approximately a claim.
    func testTheWindowIncludesItsOldestInstant() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)

        // Exactly on the boundary, one second inside it, and one second outside.
        let boundary = now.addingTimeInterval(-90 * day)
        let samples = [
            ScriptedDatedSample(
                change: change("onTheEdge", type: steps, at: boundary),
                start: boundary
            ),
            ScriptedDatedSample(
                change: change(
                    "justInside",
                    type: steps,
                    at: boundary.addingTimeInterval(1)
                ),
                start: boundary.addingTimeInterval(1)
            ),
            ScriptedDatedSample(
                change: change(
                    "justOutside",
                    type: steps,
                    at: boundary.addingTimeInterval(-1)
                ),
                start: boundary.addingTimeInterval(-1)
            )
        ]

        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: ScriptedDatedHealthDataSource(samples: [steps: samples])
        )

        for index in 0..<6 {
            await pass(engine, at: now.addingTimeInterval(Double(index) * 600))
        }

        let names = Set(await channel.sampleNames(for: destination.id))
        XCTAssertEqual(names, ["onTheEdge", "justInside"])
    }

    func testAPrimeAsksForTheNewestDatesFirst() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        _ = try await makeDestination(delivery)

        let dated = ScriptedDatedHealthDataSource(samples: [steps: history()])
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: dated
        )

        await pass(engine, at: now)

        let windows = await dated.requestedWindows(for: steps)
        XCTAssertFalse(windows.isEmpty)
        XCTAssertEqual(
            windows.first?.upperBound,
            now,
            "The first thing a prime asks for is the most recent thing there is."
        )
        for (earlier, later) in zip(windows.dropFirst(), windows) {
            XCTAssertLessThanOrEqual(
                earlier.upperBound,
                later.upperBound,
                "The walk must go backwards in time, never forwards."
            )
        }
    }

    // MARK: - Interruption

    /// A prime killed halfway must lose nothing and must not stall.
    func testAnInterruptedPrimeResumesWithoutLosingRecords() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)

        let dated = ScriptedDatedHealthDataSource(samples: [steps: history()])
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: dated
        )

        // Two different ways of being cut off, on two different passes. The
        // fake counts queries across the whole run, so the second index is
        // reached on a later pass, and the test asserts below that both were
        // actually reached — an index past the end of a run is a fault that
        // silently never happens, and a resilience test that was never tested.
        await dated.setFaults([2: .cancelTask], for: steps)
        await pass(engine, at: now)
        let afterFirst = await dated.queryCount(for: steps)
        XCTAssertGreaterThanOrEqual(
            afterFirst,
            2,
            "The cancellation fault must actually have been reached."
        )

        await dated.setFaults([afterFirst + 1: .fail], for: steps)
        await pass(engine, at: now.addingTimeInterval(600))
        let afterSecond = await dated.queryCount(for: steps)
        XCTAssertGreaterThan(
            afterSecond,
            afterFirst,
            "The failing fault must actually have been reached."
        )

        await dated.setFaults([:], for: steps)
        for index in 2..<10 {
            await pass(engine, at: now.addingTimeInterval(Double(index) * 600))
        }

        let names = Set(await channel.sampleNames(for: destination.id))
        XCTAssertEqual(
            names,
            namesInWindow,
            "Being cut off twice, two different ways, must cost time not records."
        )

        let record = try await store.primeRecord(
            scope: .destination(destination.id),
            type: steps
        )
        XCTAssertEqual(record?.state, .covered)
        XCTAssertEqual(record?.frontier, record?.windowStart)
    }

    /// A frontier is a promise that a destination holds the window. A delivery
    /// that failed did not put anything there, so nothing may be claimed.
    func testAFailedDeliveryLeavesTheFrontierWhereItWas() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)
        let scope = AnchorScope.destination(destination.id)
        await channel.fail(destination.id)

        let dated = ScriptedDatedHealthDataSource(samples: [steps: history()])
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: dated
        )

        await pass(engine, at: now)

        let refused = try await store.primeRecord(scope: scope, type: steps)
        XCTAssertEqual(refused?.frontier, refused?.coveredThrough)
        XCTAssertNil(
            refused?.coveredWindow,
            """
            Claiming a window the destination never received is the failure \
            this whole ordering exists to prevent.
            """
        )

        // And once the destination comes back, the same records arrive.
        await channel.recover(destination.id)
        for index in 1..<8 {
            await pass(engine, at: now.addingTimeInterval(Double(index) * 600))
        }

        let names = Set(await channel.sampleNames(for: destination.id))
        XCTAssertEqual(names, namesInWindow)
    }

    /// The claim is only ever about what has actually been handed over.
    func testAPartialPrimeClaimsOnlyThePartItDelivered() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)
        let scope = AnchorScope.destination(destination.id)

        let dated = ScriptedDatedHealthDataSource(samples: [steps: history()])
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: dated
        )

        // One read, then killed: enough to have covered something and nowhere
        // near enough to have covered the window.
        await dated.setFaults([2: .cancelTask], for: steps)
        await pass(engine, at: now)

        let record = try await XCTUnwrapAsync(
            try await store.primeRecord(scope: scope, type: steps)
        )
        let covered = try XCTUnwrap(record.coveredWindow)
        XCTAssertEqual(covered.through, record.coveredThrough)
        XCTAssertEqual(covered.from, record.frontier)
        XCTAssertGreaterThan(
            covered.from,
            record.windowStart,
            """
            A partial prime must report the frontier it reached, never the \
            window's start. Aiming at a date is not holding it.
            """
        )
        XCTAssertEqual(record.state, .priming)

        // Everything the destination has is inside what is claimed, and the
        // claim is checked against the dates the fixture was built from.
        let names = Set(await channel.sampleNames(for: destination.id))
        let expected = Set(
            history()
                .filter { $0.start >= covered.from && $0.start < covered.through }
                .compactMap(name(of:))
        )
        XCTAssertEqual(
            names,
            expected,
            "Everything inside a claimed window must actually be there."
        )
    }

    // MARK: - The leading edge

    /// The half of the problem that is easy to miss.
    ///
    /// `HKAnchoredObjectQuery` hands records back in the order Health stored
    /// them, so a sample recorded this morning sits at the *end* of the queue,
    /// behind the entire backlog. The sweep is therefore no more current than
    /// it is complete: without a walk that keeps the leading edge up to date, a
    /// prime would fill ninety days once and then fall a day behind, daily.
    func testDataRecordedAfterThePrimeBeganStillArrives() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)
        let scope = AnchorScope.destination(destination.id)

        let dated = ScriptedDatedHealthDataSource(samples: [steps: history()])
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            // A sweep with a real backlog, so nothing here can arrive by
            // anchor: this is the situation the whole feature is about.
            sweep: ScriptedHealthDataSource(
                streams: [
                    steps: (0..<20_000).map { change("s\($0)", type: steps, at: now) }
                ]
            ),
            dated: dated
        )

        await pass(engine, at: now)

        // Something happens after the prime began.
        let fresh = now.addingTimeInterval(120)
        await dated.append(
            ScriptedDatedSample(
                change: change("recordedToday", type: steps, at: fresh),
                start: fresh
            ),
            to: steps
        )

        // A pass once the leading edge has gone stale enough to be worth a look.
        await pass(engine, at: now.addingTimeInterval(PrimePlan.topUpInterval + 60))

        let names = Set(await channel.sampleNames(for: destination.id))
        XCTAssertTrue(
            names.contains("recordedToday"),
            """
            A sample recorded after the prime started is at the back of the \
            sweep's queue, behind years of backlog. If the prime does not \
            fetch it, nothing does for weeks.
            """
        )

        let record = try await XCTUnwrapAsync(
            try await store.primeRecord(scope: scope, type: steps)
        )
        let covered = try XCTUnwrap(record.coveredWindow)
        XCTAssertGreaterThan(
            covered.through,
            record.startedAt,
            "The covered stretch must grow past where the prime began."
        )
        XCTAssertLessThanOrEqual(
            covered.through,
            now.addingTimeInterval(PrimePlan.topUpInterval + 60),
            "A prime may not claim a stretch of time that has not happened."
        )
    }

    /// The claim is one stretch, not two, so the two walks must meet exactly.
    func testTheCoveredStretchIsContiguousAndEverythingInItArrived() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)
        let scope = AnchorScope.destination(destination.id)

        var samples = history()
        // Two samples after the prime's starting instant, which only the
        // top-up can reach, and one exactly on it, which only the backfill's
        // exclusive upper edge decides the fate of.
        for offset in [0.0, 90.0, 200.0] {
            let date = now.addingTimeInterval(offset)
            samples.append(
                ScriptedDatedSample(
                    change: change("edge\(Int(offset))", type: steps, at: date),
                    start: date
                )
            )
        }

        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: ScriptedDatedHealthDataSource(samples: [steps: samples])
        )

        let step = PrimePlan.topUpInterval + 60
        for index in 0..<8 {
            await pass(engine, at: now.addingTimeInterval(Double(index) * step))
        }
        let lastPass = now.addingTimeInterval(7 * step)

        let record = try await XCTUnwrapAsync(
            try await store.primeRecord(scope: scope, type: steps)
        )
        let covered = try XCTUnwrap(record.coveredWindow)

        // Where the claim's edges belong, worked out here. Reading them off the
        // record and then filtering the fixture by them would check that the
        // claim has no holes in it — worth checking — while letting the claim
        // be any size at all, including a second wide.
        XCTAssertEqual(
            covered.from,
            now.addingTimeInterval(-90 * 86_400),
            "The backfill had eight passes to reach the oldest instant it aims at."
        )
        XCTAssertEqual(
            covered.through,
            lastPass,
            """
            Each pass is more than the staleness interval after the last, so \
            every one of them tops the edge up to its own idea of now, and the \
            last one leaves it exactly there.
            """
        )

        let expected = Set(
            samples
                .filter {
                    $0.start >= now.addingTimeInterval(-90 * 86_400)
                        && $0.start < lastPass
                }
                .compactMap(name(of:))
        )
        let names = Set(await channel.sampleNames(for: destination.id))
        XCTAssertEqual(
            names,
            expected,
            """
            Every sample inside the claimed stretch must be there, and nothing \
            outside it may have been counted towards the claim.
            """
        )
        for edge in ["edge0", "edge90", "edge200"] {
            XCTAssertTrue(
                names.contains(edge),
                """
                \(edge) is after the instant the prime began, so only the \
                top-up can reach it. `edge0` is on that instant exactly: the \
                backfill's upper edge excludes it and the top-up's lower edge \
                includes it, so it belongs to precisely one of them rather \
                than to the seam between them.
                """
            )
        }
    }

    /// Freshness is worth a query. Freshness every forty seconds is not.
    ///
    /// Deliberately run against a type that is still backfilling, because that
    /// is the state nearly every type is in for the weeks this feature exists
    /// for — and a type is selected for a pass by *either* walk having work, so
    /// a gate that only held for finished types would not hold for anything.
    func testTheLeadingEdgeIsNotCheckedMoreOftenThanItIsWorth() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        _ = try await makeDestination(delivery)

        let dated = ScriptedDatedHealthDataSource(samples: [steps: denseHistory()])
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: dated
        )

        // A top-up is any read that starts at or after the instant the prime
        // began; everything below that is the backfill walking into the past.
        func topUpWindows() async -> [Range<Date>] {
            await dated.requestedWindows(for: steps)
                .filter { $0.lowerBound >= now }
        }

        await pass(engine, at: now)
        await pass(engine, at: now.addingTimeInterval(40))
        await pass(engine, at: now.addingTimeInterval(80))

        let early = await topUpWindows()
        XCTAssertTrue(
            early.isEmpty,
            """
            Three passes inside a minute, on a type with plenty of backfill \
            still to do, must not have cost a single query asking whether \
            anything happened in the last forty seconds.
            """
        )

        await pass(engine, at: now.addingTimeInterval(PrimePlan.topUpInterval + 60))
        let afterInterval = await topUpWindows()
        XCTAssertFalse(
            afterInterval.isEmpty,
            "Once the edge is properly stale it must be looked at."
        )
    }

    /// A minute the top-up had to shrink to must not shrink the backfill too.
    ///
    /// The two walks learn how long a chunk should be from what they read, and
    /// they read different stretches. Shared, a busy afternoon would drag the
    /// backfill down to sixty-second chunks of a quiet 2023, which it would
    /// then spend four or five queries climbing back out of — on every pass,
    /// indefinitely.
    func testABusyLeadingEdgeDoesNotShrinkTheBackfillsChunks() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)
        let scope = AnchorScope.destination(destination.id)

        let dated = ScriptedDatedHealthDataSource(samples: [steps: denseHistory()])
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: dated
        )

        // A first pass, which only backfills — the leading edge is not yet
        // stale enough to be worth a query — and which cannot finish, so the
        // type is still priming when the edge goes bad.
        await pass(engine, at: now)
        let midway = try await XCTUnwrapAsync(
            try await store.primeRecord(scope: scope, type: steps)
        )
        XCTAssertEqual(midway.state, .priming)
        XCTAssertGreaterThan(
            midway.chunkSeconds,
            PrimePlan.minimumChunk,
            "The backfill settled on a useful length over quiet months."
        )

        // The next three reads are the top-up's — it runs first, and narrows
        // twice before giving up — and every one of them overflows.
        let afterFirstPass = await dated.queryCount(for: steps)
        await dated.setFaults(
            Dictionary(
                uniqueKeysWithValues: (afterFirstPass + 1...afterFirstPass + 3)
                    .map { ($0, ScriptedDatedFault.truncate) }
            ),
            for: steps
        )
        await pass(engine, at: now.addingTimeInterval(PrimePlan.topUpInterval + 60))

        let after = try await XCTUnwrapAsync(
            try await store.primeRecord(scope: scope, type: steps)
        )
        XCTAssertEqual(
            after.topUpSeconds,
            PrimePlan.minimumChunk,
            "The top-up narrowed as far as it will go and stopped."
        )
        XCTAssertGreaterThanOrEqual(
            after.chunkSeconds,
            midway.chunkSeconds,
            """
            The months are as quiet as they were an hour ago. Nothing the \
            leading edge did is evidence about them.
            """
        )
        XCTAssertGreaterThan(after.deliveredCount, midway.deliveredCount)
    }

    /// A busy few minutes at the leading edge says nothing about the months
    /// behind it, and must not be recorded as though it did.
    func testDensityAtTheLeadingEdgeDoesNotUndoAFinishedBackfill() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)
        let scope = AnchorScope.destination(destination.id)

        let dated = ScriptedDatedHealthDataSource(samples: [steps: []])
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: dated
        )

        await pass(engine, at: now)
        let covered = try await XCTUnwrapAsync(
            try await store.primeRecord(scope: scope, type: steps)
        )
        XCTAssertEqual(covered.state, .covered)
        let claim = try XCTUnwrap(covered.coveredWindow)

        // From here on, every read of the leading edge overflows.
        let backfillQueries = await dated.queryCount(for: steps)
        await dated.setFaults(
            Dictionary(
                uniqueKeysWithValues: (backfillQueries + 1...backfillQueries + 64)
                    .map { ($0, ScriptedDatedFault.truncate) }
            ),
            for: steps
        )
        await pass(engine, at: now.addingTimeInterval(PrimePlan.topUpInterval + 60))

        let after = try await XCTUnwrapAsync(
            try await store.primeRecord(scope: scope, type: steps)
        )
        XCTAssertEqual(
            after.state,
            .covered,
            """
            The backfill reached the oldest instant it was aiming at. Nothing \
            that happens at the leading edge later can make that untrue, and \
            marking the record stalled would freeze it out of every future \
            pass as well.
            """
        )
        XCTAssertEqual(
            after.coveredWindow?.from,
            claim.from,
            "The months already delivered are still delivered."
        )

        // And it is still being tried, rather than abandoned.
        let beforeLastPass = await dated.queryCount(for: steps)
        await pass(
            engine,
            at: now.addingTimeInterval(2 * (PrimePlan.topUpInterval + 60))
        )
        let afterLastPass = await dated.queryCount(for: steps)
        XCTAssertGreaterThan(
            afterLastPass,
            beforeLastPass,
            "A record frozen by a transient edge condition never recovers."
        )
    }

    /// A top-up that was cut off must not leave a hole behind the edge.
    func testAnInterruptedTopUpDoesNotClaimWhatItDidNotSend() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)
        let scope = AnchorScope.destination(destination.id)

        let dated = ScriptedDatedHealthDataSource(samples: [steps: []])
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: dated
        )

        await pass(engine, at: now)
        let settled = try await XCTUnwrapAsync(
            try await store.primeRecord(scope: scope, type: steps)
        )

        // Now the destination goes away, and the top-up runs anyway.
        await channel.fail(destination.id)
        let later = now.addingTimeInterval(PrimePlan.topUpInterval + 60)
        let fresh = now.addingTimeInterval(30)
        await dated.append(
            ScriptedDatedSample(
                change: change("undelivered", type: steps, at: fresh),
                start: fresh
            ),
            to: steps
        )
        await pass(engine, at: later)

        let after = try await XCTUnwrapAsync(
            try await store.primeRecord(scope: scope, type: steps)
        )
        XCTAssertEqual(
            after.coveredThrough,
            settled.coveredThrough,
            """
            The edge may only move over data the destination accepted. Moving \
            it here would claim a minute whose one record was never sent.
            """
        )

        await channel.recover(destination.id)
        await pass(engine, at: later.addingTimeInterval(PrimePlan.topUpInterval + 60))
        let names = Set(await channel.sampleNames(for: destination.id))
        XCTAssertTrue(names.contains("undelivered"))
    }

    // MARK: - Types a prime cannot help with

    func testATypeWithNothingInTheWindowStillFinishes() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)

        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: ScriptedDatedHealthDataSource(samples: [steps: []])
        )

        for index in 0..<4 {
            await pass(engine, at: now.addingTimeInterval(Double(index) * 600))
        }

        let record = try await store.primeRecord(
            scope: .destination(destination.id),
            type: steps
        )
        XCTAssertEqual(
            record?.state,
            .covered,
            """
            An empty stretch that has been read is covered. If emptiness only \
            counted when something was delivered, a quiet type would be walked \
            again on every pass forever and never reported as done.
            """
        )
        XCTAssertEqual(record?.deliveredCount, 0)
        let delivered = await channel.sampleNames(for: destination.id)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testASeriesTypeIsNotPrimedAtAll() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)

        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [route: []]),
            dated: ScriptedDatedHealthDataSource(samples: [route: []]),
            types: [route]
        )

        await pass(engine, at: now)

        let record = try await store.primeRecord(
            scope: .destination(destination.id),
            type: route
        )
        XCTAssertNil(
            record,
            """
            A route's real content is a stream inside each sample, paged by \
            position, and a dated query has nowhere to carry that position. \
            No row means no primed window, which is the truth about it.
            """
        )
    }

    /// Density the dated reader cannot page through is said out loud rather
    /// than papered over.
    func testATypeTooDenseToReadStopsAndSaysSo() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)
        let scope = AnchorScope.destination(destination.id)

        // Every read claims to have overflowed, however short the window gets.
        let faults = Dictionary(
            uniqueKeysWithValues: (1...64).map { ($0, ScriptedDatedFault.truncate) }
        )
        let dated = ScriptedDatedHealthDataSource(
            samples: [steps: history()],
            faults: [steps: faults]
        )
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: dated
        )

        await pass(engine, at: now)

        let record = try await store.primeRecord(scope: scope, type: steps)
        XCTAssertEqual(record?.state, .stalled)
        XCTAssertNotNil(record?.failureReason)
        XCTAssertNil(
            record?.coveredWindow,
            "A prime that read nothing must claim nothing."
        )
        let delivered = await channel.sampleNames(for: destination.id)
        XCTAssertTrue(delivered.isEmpty)

        // And it does not come back on the next pass to try the same thing
        // again forever.
        let queriesAfterFirstPass = await dated.queryCount(for: steps)
        await pass(engine, at: now.addingTimeInterval(600))
        let queriesAfterSecondPass = await dated.queryCount(for: steps)
        XCTAssertEqual(
            queriesAfterSecondPass,
            queriesAfterFirstPass,
            "A stalled prime stays stopped rather than burning every pass."
        )
    }

    // MARK: - What a pass says about itself

    /// The pass has to carry the prime's facts up, or nothing downstream can
    /// say a true sentence about them.
    ///
    /// The fields have defaults, so an outcome that dropped them still
    /// compiled, still looked right, and turned every sentence that depended on
    /// them into one nobody could ever see. Only a test that goes through the
    /// same call the app does can tell the difference.
    func testAPassReportsThePrimingItActuallyDid() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)

        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: ScriptedDatedHealthDataSource(samples: [steps: denseHistory()])
        )

        let firstOutcome = await pass(engine, at: now)
        let first = try XCTUnwrap(firstOutcome)
        XCTAssertGreaterThan(
            first.primedRecords,
            0,
            "Every record this pass sent came from the dated walk."
        )
        XCTAssertEqual(
            first.primedRecords,
            first.deliveredRecords,
            "The sweep had nothing, so the two counts are the same pass."
        )
        XCTAssertTrue(
            first.primingRemains,
            """
            Four and a half thousand records do not fit in one pass's budget,             so this pass finished nothing and must not say it did.
            """
        )

        var last: SyncOutcome?
        for index in 1..<12 {
            last = await pass(engine, at: now.addingTimeInterval(Double(index) * 60))
        }

        let finished = try XCTUnwrap(last)
        XCTAssertFalse(
            finished.primingRemains,
            "Once every window is walked there is nothing left to be fetching."
        )

        let record = try await store.primeRecord(
            scope: .destination(destination.id),
            type: steps
        )
        XCTAssertEqual(record?.state, .covered)
    }

    /// Two destinations are two lots of priming, and the pass has to add them
    /// up rather than report whichever it looked at last.
    func testAPassAddsUpThePrimingItDidForEveryDestination() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let first = try await makeDestination(delivery, name: "First")
        let second = try await makeDestination(delivery, name: "Second")

        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: ScriptedDatedHealthDataSource(samples: [steps: history()])
        )

        let passOutcome = await pass(engine, at: now)
        let outcome = try XCTUnwrap(passOutcome)

        // Each destination has its own cursor and receives the window in full,
        // so the pass sent the window twice — a hundred and eighty records to
        // each of them, worked out from the fixture rather than read back.
        XCTAssertEqual(
            outcome.primedRecords,
            2 * namesInWindow.count,
            """
            A pass that reported one destination's priming, or the larger of \
            the two, would still look plausible and would still be wrong.
            """
        )
        XCTAssertEqual(outcome.primedRecords, outcome.deliveredRecords)

        for destination in [first, second] {
            let names = await channel.sampleNames(for: destination.id)
            XCTAssertEqual(Set(names), namesInWindow)
        }
    }

    // MARK: - Asking again

    /// Asking again re-reads the months, and stops claiming them first.
    func testAskingAgainWalksTheRecentMonthsFromNothing() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)
        let scope = AnchorScope.destination(destination.id)

        let dated = ScriptedDatedHealthDataSource(samples: [steps: history()])
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: dated
        )

        for index in 0..<6 {
            await pass(engine, at: now.addingTimeInterval(Double(index) * 600))
        }
        let covered = try await XCTUnwrapAsync(
            try await store.primeRecord(scope: scope, type: steps)
        )
        XCTAssertEqual(covered.state, .covered)

        // Somebody widens Health authorization in Settings, and a type Hozz was
        // never allowed to see turns up. A finished prime has no way to notice:
        // it finished, correctly, over what it was allowed to read.
        let restartedAt = now.addingTimeInterval(7 * 600)
        try await engine.restartPrime(now: restartedAt)

        let reset = try await XCTUnwrapAsync(
            try await store.primeRecord(scope: scope, type: steps)
        )
        XCTAssertNil(
            reset.coveredWindow,
            """
            The claim has to go before the re-read starts. Keeping it would \
            assert coverage of months the app has just decided to check again.
            """
        )
        XCTAssertEqual(reset.state, .priming)
        XCTAssertEqual(reset.deliveredCount, 0)

        for index in 7..<16 {
            await pass(engine, at: now.addingTimeInterval(Double(index) * 600))
        }

        let after = try await XCTUnwrapAsync(
            try await store.primeRecord(scope: scope, type: steps)
        )
        XCTAssertEqual(after.state, .covered)

        // The window moved with the restart, so what the second walk owes is
        // worked out from the new starting instant, not the old one.
        let secondWindow = Set(
            history()
                .filter {
                    $0.start >= restartedAt.addingTimeInterval(-90 * 86_400)
                        && $0.start < restartedAt
                }
                .compactMap(name(of:))
        )
        let firstWindow = namesInWindow

        let delivered = await channel.sampleNames(for: destination.id)
        XCTAssertEqual(
            Set(delivered),
            firstWindow.union(secondWindow),
            "Between them the two walks owe exactly the two windows."
        )

        // The point of the test: these months were read *again*, not merely
        // still remembered from the first time. A repeat is what re-reading
        // looks like from the destination's side, and it is harmless — the
        // receiver stores each record under its own identifier.
        let repeats = Set(
            delivered.filter { name in
                delivered.filter { $0 == name }.count > 1
            }
        )
        XCTAssertEqual(
            repeats,
            secondWindow,
            """
            Everything in the new window must have arrived a second time. \
            Anything that did not was claimed on the strength of the first \
            walk, which the restart had already thrown away.
            """
        )
    }

    // MARK: - The gap, on the wire

    /// The whole point, end to end: a receiver is told the held data has two
    /// regions and a hole between them.
    ///
    /// Everything before this test checks the phone's own record. This checks
    /// the bytes, because a fact the phone knows and never says is the state
    /// the coverage report was built to end.
    func testAReceiverIsToldWhichMonthsAreActuallyHeld() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)

        // A sweep with years still to go, which is the state that makes a
        // primed window worth reporting at all.
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(
                streams: [
                    steps: (0..<20_000).map { change("s\($0)", type: steps, at: now) }
                ]
            ),
            dated: ScriptedDatedHealthDataSource(samples: [steps: history()])
        )

        for index in 0..<4 {
            await pass(engine, at: now.addingTimeInterval(Double(index) * 600))
        }

        let sent = await channel.coverageLine(for: destination.id, type: steps)
        let report = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(sent))
                as? [String: Any]
        )

        XCTAssertEqual(
            report["complete"] as? Bool,
            false,
            "Twenty thousand records still to sweep is not a complete type."
        )
        let from = try XCTUnwrap(
            (report["primedFrom"] as? String).flatMap(Timestamps.date(from:))
        )
        let through = try XCTUnwrap(
            (report["primedThrough"] as? String).flatMap(Timestamps.date(from:))
        )
        XCTAssertEqual(
            from,
            now.addingTimeInterval(-90 * 86_400),
            "The window's oldest end is where the backfill actually reached."
        )
        XCTAssertGreaterThanOrEqual(through, now)
        XCTAssertLessThan(
            from,
            through,
            """
            An incomplete sweep with a real window is data with a hole in the \
            middle of it, and a receiver that cannot see both ends cannot know \
            the hole is there.
            """
        )
    }

    // MARK: - The gap the prime creates
    /// Priming leaves recent data and swept data with a hole between them, and
    /// the store has to be able to say so. A surface that cannot see the hole
    /// shows the recent past and reads as complete while years are missing.
    func testTheHoleBetweenTheSweepAndTheWindowIsVisible() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let destination = try await makeDestination(delivery)
        let scope = AnchorScope.destination(destination.id)

        // A sweep that has plenty left to do: it never returns an empty page
        // inside one pass, so its coverage stays `draining`.
        let sweep = ScriptedHealthDataSource(
            streams: [
                steps: (0..<20_000).map { change("s\($0)", type: steps, at: now) }
            ]
        )
        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: sweep,
            dated: ScriptedDatedHealthDataSource(samples: [steps: history()])
        )

        for index in 0..<4 {
            await pass(engine, at: now.addingTimeInterval(Double(index) * 600))
        }

        let stream = try await XCTUnwrapAsync(
            try await store.streamRecord(scope: scope, type: steps)
        )
        let prime = try await XCTUnwrapAsync(
            try await store.primeRecord(scope: scope, type: steps)
        )
        let covered = try XCTUnwrap(prime.coveredWindow)

        // The two facts a report is built from, and the pair of them is the
        // gap: a window that is genuinely full, and a sweep that is not
        // finished, therefore data with a hole in the middle of it.
        let report = TypeCoverageReport(
            type: steps.rawValue,
            state: stream.coverage,
            deliveredCount: stream.recordCount,
            primedFrom: covered.from,
            primedThrough: covered.through,
            observedAt: now
        )

        XCTAssertFalse(
            report.isComplete,
            "The sweep has twenty thousand records left; it is not complete."
        )
        XCTAssertTrue(report.hasPrimedWindow)
        XCTAssertTrue(
            report.hasPrimedWindow && !report.isComplete,
            """
            Two regions with a hole between them. No surface may present this \
            as one continuous history, which it cannot avoid doing if the \
            facts it is given cannot express the hole.
            """
        )
    }

    /// Nothing about the prime may reach a destination that did not ask for
    /// this type.
    func testAPrimeRespectsWhatADestinationAskedFor() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])

        var narrow = Destination(
            name: "Heart only",
            kind: .folder,
            cadence: .whenDataArrives,
            folderBookmark: Data("a".utf8)
        )
        narrow.includedTypes = [HealthTypeKey("HKQuantityTypeIdentifierHeartRate")]
        try await delivery.save(narrow)

        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: ScriptedDatedHealthDataSource(samples: [steps: history()])
        )

        await pass(engine, at: now)

        let primed = try await store.primeRecord(
            scope: .destination(narrow.id),
            type: steps
        )
        XCTAssertNil(
            primed,
            "A destination that excluded a type must not be primed with it."
        )
        let delivered = await channel.sampleNames(for: narrow.id)
        XCTAssertTrue(delivered.isEmpty)
    }

    /// Two destinations are two independent promises, so they get two frontiers.
    func testEachDestinationHasItsOwnFrontier() async throws {
        let store = try makeStore()
        let channel = PrimeRecordingChannel()
        let delivery = DeliveryEngine(store: store, channels: [.folder: channel])
        let first = try await makeDestination(delivery, name: "First")
        let second = try await makeDestination(delivery, name: "Second")
        await channel.fail(second.id)

        let engine = makeEngine(
            store: store,
            delivery: delivery,
            sweep: ScriptedHealthDataSource(streams: [steps: []]),
            dated: ScriptedDatedHealthDataSource(samples: [steps: history()])
        )

        for index in 0..<6 {
            await pass(engine, at: now.addingTimeInterval(Double(index) * 600))
        }

        let ahead = try await store.primeRecord(
            scope: .destination(first.id),
            type: steps
        )
        let behind = try await store.primeRecord(
            scope: .destination(second.id),
            type: steps
        )

        XCTAssertEqual(ahead?.state, .covered)
        XCTAssertNil(
            behind?.coveredWindow,
            """
            A frontier shared between destinations would let a reachable one \
            answer for an unreachable one, and the unreachable one would be \
            recorded as holding data it was never sent.
            """
        )
        let deliveredToFirst = await channel.sampleNames(for: first.id)
        XCTAssertEqual(Set(deliveredToFirst), namesInWindow)
    }
}

/// `XCTUnwrap` cannot be applied to an `await` expression's result inside an
/// autoclosure that also throws, so this does the same job for one.
private func XCTUnwrapAsync<T>(
    _ value: T?,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
