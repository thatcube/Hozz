import Foundation
import HozzCore
@testable import HozzDeliver
import HozzStore
import XCTest

/// What a delivery window does, and — more importantly — what it is not allowed
/// to do.
///
/// The dangerous case here is not a window that excludes too much. It is a
/// window that excludes a reading quietly, reports the delivery as complete, and
/// leaves that reading unreachable for ever because the acquisition cursor has
/// moved past it. Most of this file is about that.
final class DeliveryWindowTests: XCTestCase {
    private var directory: TemporaryDirectory!

    /// A fixed clock, in a fixed zone, so "today" means the same thing wherever
    /// this runs. 2026-08-22 at 14:30 local.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private var now: Date {
        calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 22, hour: 14, minute: 30)
        )!
    }

    /// Local midnight on the given August day in 2026, worked out from
    /// components rather than by asking the code under test.
    private func midnight(august day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day))!
    }

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    // MARK: - The floors are the dates their names claim

    func testEachWindowsFloorIsTheMidnightItsNameClaims() {
        XCTAssertNil(
            DeliveryWindow.sinceLastDelivery.floor(now: now, calendar: calendar),
            "The default is the absence of a floor, not a very old one."
        )
        XCTAssertEqual(
            DeliveryWindow.sinceStartOfToday.floor(now: now, calendar: calendar),
            midnight(august: 22)
        )
        XCTAssertEqual(
            DeliveryWindow.sinceStartOfYesterday.floor(now: now, calendar: calendar),
            midnight(august: 21)
        )
        XCTAssertEqual(
            DeliveryWindow.sinceSevenDaysAgo.floor(now: now, calendar: calendar),
            midnight(august: 15)
        )
        XCTAssertEqual(
            DeliveryWindow.sinceThirtyDaysAgo.floor(now: now, calendar: calendar),
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 23))
        )
    }






    // MARK: - Coverage, which is what decides whether history replays



    /// Crossing a daylight-saving boundary must still land on local midnight,
    /// not on a time shifted by an hour.
    func testAFloorLandsOnLocalMidnightAcrossADaylightSavingChange() {
        // In New York, clocks go back on 1 November 2026.
        let afterTheChange = calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 2, hour: 9)
        )!
        let floor = DeliveryWindow.sinceStartOfYesterday.floor(
            now: afterTheChange,
            calendar: calendar
        )

        XCTAssertEqual(
            floor,
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)),
            "A day back has to be the previous midnight, not 23 or 25 hours."
        )
    }


    // MARK: - The floor itself

    /// A record with no date is always admitted. The one record shape that
    /// carries none is a deletion tombstone, and holding one back leaves a
    /// receiver showing a reading the user deleted.
    func testAFloorAlwaysAdmitsARecordItCannotDate() {
        XCTAssertTrue(DeliveryFloor(date: midnight(august: 22)).admits(nil))
        XCTAssertTrue(DeliveryFloor.unbounded.admits(nil))
    }

    func testAFloorAdmitsItsOwnInstantAndRefusesTheOneBefore() {
        let floor = DeliveryFloor(date: midnight(august: 22))

        XCTAssertTrue(
            floor.admits(midnight(august: 22)),
            "Midnight belongs to the day that starts at it."
        )
        XCTAssertFalse(
            floor.admits(midnight(august: 22).addingTimeInterval(-0.001))
        )
    }

    /// There is no upper bound, so a sample HealthKit gains while the sync is
    /// already running is never rejected for being too new.
    func testAFloorNeverRefusesAReadingForBeingTooNew() {
        let floor = DeliveryFloor(date: midnight(august: 22))

        XCTAssertTrue(floor.admits(now.addingTimeInterval(90)))
        XCTAssertTrue(floor.admits(now.addingTimeInterval(400 * 86_400)))
    }

    func testAnUnboundedFloorAdmitsAnythingAtAll() {
        XCTAssertTrue(DeliveryFloor.unbounded.admits(Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(DeliveryFloor.unbounded.admits(midnight(august: 22)))
    }

    /// Compared as dates, because two destinations set to "start from 7 days
    /// ago" weeks apart do not have the same starting point.
    func testOneFloorCoversAnotherWhenItIsTheEarlierDate() {
        let earlier = DeliveryFloor(date: midnight(august: 15))
        let later = DeliveryFloor(date: midnight(august: 22))

        XCTAssertTrue(earlier.covers(later))
        XCTAssertFalse(later.covers(earlier))
        XCTAssertTrue(later.covers(later))
        XCTAssertTrue(DeliveryFloor.unbounded.covers(earlier))
        XCTAssertFalse(earlier.covers(.unbounded))
    }

    // MARK: - The date is resolved once and then stays put

    /// The failure this design exists to remove. Sleep is dated from bedtime, so
    /// a starting point that crept forward to each morning's midnight would
    /// throw away every night's sleep, every night, and report it as delivered.
    func testLastNightsSleepIsStillSentByAMorningSync() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = CapturingChannel()
        let engine = DeliveryEngine(store: store, channels: [.restAPI: channel])

        // Chosen on the 21st, so the starting point is midnight on the 21st.
        let destination = endpoint(.sinceStartOfToday)
        try await engine.save(destination, now: calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 21, hour: 20)
        )!)
        let reloaded = try await engine.destination(id: destination.id)
        let saved = try XCTUnwrap(reloaded)

        // Sleep recorded from 23:00 on the 21st, delivered by a sync at 07:00 on
        // the 22nd — after the point a rolling floor would have moved to.
        let sleep = Data(
            """
            {"id":"sleep","kind":"category","startDate":"2026-08-22T03:00:00.000Z"}

            """.utf8
        )
        let morning = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 22, hour: 7)
        )!
        _ = try await engine.deliver(batch(sleep), to: saved, now: morning)

        let sent = await channel.payloads()
        XCTAssertEqual(
            sent.count,
            1,
            "A starting point that moved would have dropped this every night."
        )
        XCTAssertEqual(identifiers(in: sent[0]), ["sleep"])
    }

    /// An endpoint down for ten minutes at 23:55 must not have its retry judged
    /// against the next day's line. Ten minutes of downtime erasing a day is
    /// exactly the failure a moving starting point causes.
    func testARetryAfterMidnightJudgesTheSameReadingsByTheSameLine() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = CapturingChannel()
        let engine = DeliveryEngine(store: store, channels: [.restAPI: channel])
        let destination = endpoint(.sinceStartOfToday)
        try await engine.save(destination, now: calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 22, hour: 9)
        )!)
        let reloaded = try await engine.destination(id: destination.id)
        let saved = try XCTUnwrap(reloaded)

        // Readings from the 22nd, delivered at 00:07 on the 23rd.
        let afterMidnight = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 23, hour: 0, minute: 7)
        )!
        let receipt = try await engine.deliver(
            batch(fourDays),
            to: saved,
            now: afterMidnight
        )

        let sent = await channel.payloads()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(
            identifiers(in: sent[0]),
            ["d22"],
            "The 22nd is still above a line drawn at midnight on the 22nd."
        )
        XCTAssertEqual(receipt.recordCount, 1)
    }

    func testSavingResolvesTheChoiceToADateAndKeepsIt() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        let destination = endpoint(.sinceSevenDaysAgo)

        try await engine.save(destination, now: now)
        let afterFirstSave = try await engine.destination(id: destination.id)
        let first = try XCTUnwrap(afterFirstSave)
        XCTAssertEqual(
            first.deliveryFloor.date,
            midnight(august: 15),
            "Seven days before the 22nd, worked out from the calendar."
        )

        // Saved again a fortnight later without touching the setting.
        var renamed = first
        renamed.name = "Still the same server"
        try await engine.save(renamed, now: now.addingTimeInterval(14 * 86_400))

        let afterSecondSave = try await engine.destination(id: destination.id)
        let second = try XCTUnwrap(afterSecondSave)
        XCTAssertEqual(
            second.deliveryFloor.date,
            midnight(august: 15),
            "Re-saving must not move the line and strand two weeks of readings."
        )
    }

    func testChoosingTheSameOptionAgainDoesNotMoveTheLine() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        try await engine.save(endpoint(.sinceStartOfToday), now: now)
        let afterFirst = try await engine.destinations()
        let first = try XCTUnwrap(afterFirst.first)

        try await engine.save(first, now: now.addingTimeInterval(3 * 86_400))

        let afterSecond = try await engine.destinations()
        let second = try XCTUnwrap(afterSecond.first)
        XCTAssertEqual(second.deliveryFloor.date, midnight(august: 22))
    }

    func testGoingBackToEverythingClearsTheLineAltogether() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        try await engine.save(endpoint(.sinceStartOfToday), now: now)
        let loaded = try await engine.destinations()
        var destination = try XCTUnwrap(loaded.first)

        destination.deliveryWindow = .sinceLastDelivery
        try await engine.save(destination, now: now)

        let reloaded = try await engine.destinations()
        let saved = try XCTUnwrap(reloaded.first)
        XCTAssertFalse(saved.deliveryFloor.isBounded)
        XCTAssertNil(saved.options[Destination.windowFloorKey])
    }

    /// A bounded choice with no resolved date has to admit everything. Sending
    /// too much costs a duplicate a receiver can recognise; sending too little
    /// costs a reading nobody sees again.
    func testABoundedChoiceWithNoResolvedDateExcludesNothing() throws {
        var destination = endpoint(.sinceStartOfToday)
        destination.options[Destination.windowFloorKey] = nil

        let result = try destination.deliveryWindow.apply(
            to: batch(fourDays),
            destination: destination
        )

        XCTAssertEqual(result.excludedRecords, 0)
        XCTAssertEqual(result.batch?.payload, fourDays)
    }

    // MARK: - Applying a window to a batch

    private func batch(_ payload: Data, format: DeliveryFormat = .ndjson) -> DeliveryBatch {
        DeliveryBatch(
            id: DeliveryBatch.identifier(for: payload),
            sequence: 0,
            createdAt: now,
            recordCount: payload
                .split(separator: 0x0A, omittingEmptySubsequences: true)
                .count,
            payload: payload,
            format: format
        )
    }

    /// One record per day from the 19th to the 22nd, written by hand at 12:00
    /// UTC so each falls unambiguously inside its own New York day.
    private let fourDays = Data(
        """
        {"id":"d19","kind":"quantity","startDate":"2026-08-19T12:00:00.000Z"}
        {"id":"d20","kind":"quantity","startDate":"2026-08-20T12:00:00.000Z"}
        {"id":"d21","kind":"quantity","startDate":"2026-08-21T12:00:00.000Z"}
        {"id":"d22","kind":"quantity","startDate":"2026-08-22T12:00:00.000Z"}

        """.utf8
    )

    private func identifiers(in payload: Data) -> [String] {
        payload
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { slice -> String? in
                guard
                    let object = try? JSONSerialization
                        .jsonObject(with: Data(slice)) as? [String: Any]
                else {
                    return nil
                }
                return object["id"] as? String
            }
    }

    func testTheUnboundedWindowChangesNothingAtAll() throws {
        let original = batch(fourDays)
        let result = try DeliveryWindow.sinceLastDelivery.apply(
            to: original,
            destination: Destination(name: "n", kind: .restAPI)
        )

        XCTAssertEqual(result.excludedRecords, 0)
        XCTAssertEqual(result.batch?.payload, fourDays, "Byte for byte.")
        XCTAssertEqual(
            result.batch?.id,
            original.id,
            "An untouched batch keeps its idempotency key."
        )
    }

    func testAFloorKeepsExactlyTheRecordsAtOrAfterIt() throws {
        let result = try DeliveryWindow.sinceStartOfYesterday.apply(
            to: batch(fourDays),
            destination: pinned(.sinceStartOfYesterday, to: midnight(august: 21))
        )

        let payload = try XCTUnwrap(result.batch?.payload)
        XCTAssertEqual(identifiers(in: payload), ["d21", "d22"])
        XCTAssertEqual(result.excludedRecords, 2)
        XCTAssertEqual(result.batch?.recordCount, 2, "The count has to match the bytes.")
    }

    /// The rule the whole idempotency scheme rests on: different bytes, different
    /// key. Reusing the key would let a correct receiver discard records it has
    /// never seen.
    func testAFilteredBatchGetsANewIdentifierDerivedFromItsNewBytes() throws {
        let original = batch(fourDays)
        let result = try DeliveryWindow.sinceStartOfToday.apply(
            to: original,
            destination: pinned(.sinceStartOfToday, to: midnight(august: 22))
        )

        let payload = try XCTUnwrap(result.batch?.payload)
        XCTAssertNotEqual(result.batch?.id, original.id)
        XCTAssertEqual(
            result.batch?.id,
            DeliveryBatch.identifier(for: payload),
            "The key has to be the hash of what is actually sent."
        )
    }

    func testAWindowThatExcludesEverythingProducesNoBatchRatherThanAnEmptyOne() throws {
        let result = try DeliveryWindow.sinceStartOfToday.apply(
            to: batch(onlyOld),
            destination: pinned(.sinceStartOfToday, to: midnight(august: 22))
        )

        XCTAssertNil(result.batch)
        XCTAssertEqual(result.excludedRecords, 1)
    }

    private let onlyOld = Data(
        """
        {"id":"old","kind":"quantity","startDate":"2020-01-01T12:00:00.000Z"}

        """.utf8
    )

    /// A payload this build cannot take apart must not be delivered whole. That
    /// would send readings the user asked to leave out and call it a success.
    func testAnUnreadablePayloadIsRefusedRatherThanSentUnfiltered() {
        let opaque = Data("not a record at all\n".utf8)

        XCTAssertThrowsError(
            try DeliveryWindow.sinceStartOfToday.apply(
                to: batch(opaque),
                destination: pinned(.sinceStartOfToday, to: midnight(august: 22))
            )
        ) { error in
            XCTAssertEqual(error as? DeliveryError, .windowNotApplicable)
        }
    }

    // MARK: - Through the engine

    /// A destination whose starting point is set here rather than resolved by
    /// the code under test.
    private func pinned(_ window: DeliveryWindow, to date: Date) -> Destination {
        var destination = Destination(
            name: "n",
            kind: .restAPI,
            deliveryWindow: window
        )
        destination.options[Destination.windowFloorKey] = Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
        return destination
    }

    private func endpoint(_ window: DeliveryWindow) -> Destination {
        Destination(
            name: "Home server",
            kind: .restAPI,
            endpointURL: URL(string: "https://example.com/health"),
            deliveryWindow: window
        )
    }

    func testTheChannelNeverSeesRecordsTheWindowExcluded() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = CapturingChannel()
        let engine = DeliveryEngine(store: store, channels: [.restAPI: channel])
        try await engine.save(endpoint(.sinceStartOfToday), now: now)
        let loaded = try await engine.destinations()
        let destination = try XCTUnwrap(loaded.first)

        _ = try await engine.deliver(batch(fourDays), to: destination, now: now)

        let sent = await channel.payloads()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(identifiers(in: sent[0]), ["d22"])
    }

    func testTheReceiptSaysHowManyReadingsTheWindowLeftOut() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [.restAPI: CapturingChannel()])
        try await engine.save(endpoint(.sinceStartOfToday), now: now)
        let loaded = try await engine.destinations()
        let destination = try XCTUnwrap(loaded.first)

        _ = try await engine.deliver(batch(fourDays), to: destination, now: now)

        let receipts = try await engine.receipts(for: destination.id)
        let detail = try XCTUnwrap(receipts.first?.detail)
        XCTAssertTrue(detail.contains("3"), "Three were left out: \(detail)")
        XCTAssertEqual(receipts.first?.recordCount, 1)
    }

    /// Nothing to send is a complete delivery of nothing, not a failure. Marking
    /// it as needing attention would put a permanent warning on a destination
    /// that is doing exactly what it was told.
    func testAWindowThatExcludesEverythingIsRecordedAsASuccessWithNoRecords() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = CapturingChannel()
        let engine = DeliveryEngine(store: store, channels: [.restAPI: channel])
        try await engine.save(endpoint(.sinceStartOfToday), now: now)
        let loaded = try await engine.destinations()
        let destination = try XCTUnwrap(loaded.first)

        let receipt = try await engine.deliver(batch(onlyOld), to: destination, now: now)

        XCTAssertEqual(receipt.recordCount, 0)
        XCTAssertEqual(receipt.state, .delivered)
        let sent = await channel.payloads()
        XCTAssertTrue(sent.isEmpty, "Nothing may reach the wire.")

        let state = try await engine.state(for: destination.id)
        XCTAssertEqual(state?.state, DeliveryState.delivered.rawValue)
        XCTAssertEqual(state?.deliveredRecords, 0)
        XCTAssertNotNil(state?.lastSuccessAt)

        let latest = try await engine.receipts(for: destination.id)
        let detail = try XCTUnwrap(latest.first?.detail)
        XCTAssertTrue(detail.contains("1"), detail)
    }

    // MARK: - No record is skipped for ever

    /// The guarantee that makes a floor safe to offer at all.
    ///
    /// A high floor excludes old readings and the cursor moves past them.
    /// Lowering it clears the cursors, so those readings are read again and
    /// delivered. Without this, choosing "Nothing older than today" once would
    /// silently make every earlier reading unreachable for that destination.
    func testLoweringTheFloorClearsTheCursorsSoSkippedReadingsComeBack() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        try await engine.save(endpoint(.sinceStartOfToday), now: now)
        let loaded = try await engine.destinations()
        var destination = try XCTUnwrap(loaded.first)
        try await commitACursor(store, for: destination.id)
        let before = try await store.streamRecords(scope: .destination(destination.id))
        XCTAssertFalse(before.isEmpty)

        destination.deliveryWindow = .sinceSevenDaysAgo
        try await engine.save(destination, now: now)

        let after = try await store.streamRecords(scope: .destination(destination.id))
        XCTAssertTrue(
            after.isEmpty,
            "Lowering the floor has to replay, or the skipped readings never arrive."
        )
    }

    /// Raising the floor throws nothing away that was already delivered, so
    /// re-reading years of Health would be a cost with no benefit.
    func testRaisingTheFloorLeavesTheCursorsWhereTheyAre() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        try await engine.save(endpoint(.sinceLastDelivery), now: now)
        let loaded = try await engine.destinations()
        var destination = try XCTUnwrap(loaded.first)
        try await commitACursor(store, for: destination.id)

        destination.deliveryWindow = .sinceStartOfToday
        try await engine.save(destination, now: now)

        let after = try await store.streamRecords(scope: .destination(destination.id))
        XCTAssertFalse(
            after.isEmpty,
            "Raising the floor excludes nothing that was already sent."
        )
    }

    func testAnOrdinaryReSaveDoesNotThrowAwayTheCursors() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        try await engine.save(endpoint(.sinceStartOfToday), now: now)
        let loaded = try await engine.destinations()
        var destination = try XCTUnwrap(loaded.first)
        try await commitACursor(store, for: destination.id)

        destination.name = "Renamed"
        try await engine.save(destination, now: now)

        let after = try await store.streamRecords(scope: .destination(destination.id))
        XCTAssertFalse(
            after.isEmpty,
            "Renaming a destination must not restart it."
        )
    }

    /// The replay is two writes to two tables and cannot be made atomic from
    /// here, so it is written down before it is carried out. A crash in between
    /// must leave the work owed rather than silently done — otherwise the wider
    /// window is on disk, nothing can tell a replay was due, and the readings
    /// are gone for good.
    func testAReplayInterruptedBeforeItRanIsStillCarriedOutOnTheNextLaunch() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        var destination = endpoint(.sinceStartOfToday)

        // Exactly the state a crash between the two writes would leave: the
        // wider window saved, the marker set, the cursors untouched.
        destination.deliveryWindow = .sinceLastDelivery
        destination.options[Destination.pendingReplayKey] = "1"
        try await store.saveDestination(
            id: destination.id,
            payload: try JSONEncoder().encode(destination),
            createdAt: destination.createdAt
        )
        try await commitACursor(store, for: destination.id)

        // A fresh engine, as after a relaunch.
        let engine = DeliveryEngine(store: store, channels: [:])
        let loaded = try await engine.destinations()

        let after = try await store.streamRecords(scope: .destination(destination.id))
        XCTAssertTrue(after.isEmpty, "The owed replay has to happen eventually.")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertFalse(
            loaded[0].isReplayPending,
            "And it must be forgotten once it has, or it replays for ever."
        )
    }

    func testTheMarkerIsClearedOnceTheReplayHasHappened() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        try await engine.save(endpoint(.sinceStartOfToday), now: now)
        let loaded = try await engine.destinations()
        var destination = try XCTUnwrap(loaded.first)

        destination.deliveryWindow = .sinceThirtyDaysAgo
        try await engine.save(destination, now: now)

        let saved = try await engine.destination(id: destination.id)
        XCTAssertEqual(saved?.isReplayPending, false)
        XCTAssertEqual(saved?.deliveryWindow, .sinceThirtyDaysAgo)
    }

    private func commitACursor(_ store: HozzStore, for id: UUID) async throws {
        try await store.commit(
            [
                PendingAnchorCommit(
                    type: try XCTUnwrap(
                        HealthTypeKey(rawValue: "HKQuantityTypeIdentifierStepCount")
                    ),
                    baseAnchor: nil,
                    anchor: AnchorToken(data: Data([1, 2, 3])),
                    coverage: .draining,
                    addedRecordCount: 4,
                    addedObservedCount: 4
                )
            ],
            scope: .destination(id)
        )
    }

    // MARK: - The setting survives a build that cannot read it

    func testAnUnknownWindowKeepsTheDestinationAndTheSetting() throws {
        let stored = Data(
            """
            {
              "id": "8B2E7F6A-1C2D-4E5F-9A0B-1C2D3E4F5A6B",
              "name": "My server",
              "kind": "restAPI",
              "deliveryWindow": "sinceTheDawnOfTime",
              "createdAt": 760000000
            }
            """.utf8
        )
        let destination = try JSONDecoder().decode(Destination.self, from: stored)

        XCTAssertEqual(destination.name, "My server")
        XCTAssertFalse(destination.isUsable)
        XCTAssertEqual(
            destination.unsupportedSettings["deliveryWindow"],
            "sinceTheDawnOfTime"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(destination))
                as? [String: Any]
        )
        XCTAssertEqual(
            object["deliveryWindow"] as? String,
            "sinceTheDawnOfTime",
            "A build that cannot read the setting must not erode it either."
        )
    }

    func testADestinationSavedBeforeWindowsExistedIsUnbounded() throws {
        let older = Data(
            """
            {
              "id": "8B2E7F6A-1C2D-4E5F-9A0B-1C2D3E4F5A6B",
              "name": "My computer",
              "kind": "folder",
              "createdAt": 760000000
            }
            """.utf8
        )
        let destination = try JSONDecoder().decode(Destination.self, from: older)

        XCTAssertTrue(destination.isUsable)
        XCTAssertEqual(
            destination.deliveryWindow,
            .sinceLastDelivery,
            "An upgrade must not start excluding readings nobody asked to exclude."
        )
    }
}

/// Keeps what actually reached the wire.
actor CapturingChannel: DeliveryChannel {
    private var sent: [Data] = []

    func payloads() -> [Data] {
        sent
    }

    func deliver(
        _ batch: DeliveryBatch,
        to destination: Destination
    ) async throws -> DeliveryReceipt {
        sent.append(batch.payload)
        return DeliveryReceipt(
            destinationID: destination.id,
            attemptedAt: .now,
            recordCount: batch.recordCount,
            byteCount: UInt64(batch.payload.count),
            state: .delivered,
            detail: "HTTP 200"
        )
    }
}
