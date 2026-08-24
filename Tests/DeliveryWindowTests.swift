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

    /// A day boundary is the user's midnight, not UTC's. On this date New York
    /// is four hours behind UTC, so local midnight is 04:00 UTC — and a reading
    /// at 02:00 UTC on the 22nd is still the 21st where the user lives.
    func testDaysAreTheUsersDaysRatherThanUTCDays() {
        // 2026-08-22T02:00:00Z, computed from components in UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let twoAMUTC = utc.date(
            from: DateComponents(year: 2026, month: 8, day: 22, hour: 2)
        )!

        XCTAssertFalse(
            DeliveryWindow.sinceStartOfToday.admits(
                twoAMUTC,
                now: now,
                calendar: calendar
            ),
            "02:00 UTC on the 22nd is still the 21st in New York."
        )
        XCTAssertTrue(
            DeliveryWindow.sinceStartOfYesterday.admits(
                twoAMUTC,
                now: now,
                calendar: calendar
            )
        )
    }

    func testAReadingExactlyOnTheFloorIsAdmittedAndOneAnInstantEarlierIsNot() {
        let floor = midnight(august: 22)

        XCTAssertTrue(
            DeliveryWindow.sinceStartOfToday.admits(
                floor,
                now: now,
                calendar: calendar
            ),
            "Midnight belongs to the day that starts at it."
        )
        XCTAssertFalse(
            DeliveryWindow.sinceStartOfToday.admits(
                floor.addingTimeInterval(-0.001),
                now: now,
                calendar: calendar
            ),
            "A millisecond before midnight is the previous day."
        )
    }

    /// A floor has no upper bound, on purpose. A sample HealthKit gains while a
    /// sync is already running is dated after the moment the pass started, and
    /// an upper bound would exclude it and let the cursor commit past it.
    func testAReadingNewerThanTheSyncItselfIsNeverExcluded() {
        let duringTheSync = now.addingTimeInterval(90)
        let tomorrow = now.addingTimeInterval(86_400)

        for window in DeliveryWindow.allCases {
            XCTAssertTrue(
                window.admits(duringTheSync, now: now, calendar: calendar),
                "\(window.rawValue) must not reject a reading for being too new."
            )
            XCTAssertTrue(
                window.admits(tomorrow, now: now, calendar: calendar),
                "\(window.rawValue) must not reject a reading dated ahead."
            )
        }
    }

    /// The one record shape that carries no date is a tombstone. Holding one
    /// back would leave a receiver showing a reading the user deleted.
    func testARecordWithNoDateIsAlwaysAdmitted() {
        for window in DeliveryWindow.allCases {
            XCTAssertTrue(
                window.admits(nil, now: now, calendar: calendar),
                "\(window.rawValue) must not exclude a record it cannot date."
            )
        }
    }

    /// A floor that ends before today would deliver nothing at all, for ever:
    /// readings dated today are drained today, and by the time they fell inside
    /// such a window the cursor would be past them.
    func testNoWindowEverExcludesTodaysReadings() {
        let thisMorning = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 22, hour: 8)
        )!
        for window in DeliveryWindow.allCases {
            XCTAssertTrue(
                window.admits(thisMorning, now: now, calendar: calendar),
                "\(window.rawValue) would starve a destination permanently."
            )
        }
    }

    // MARK: - Coverage, which is what decides whether history replays

    func testCoverageIsTheOrderTheFloorsActuallyHave() {
        let cases: [(DeliveryWindow, DeliveryWindow, Bool)] = [
            (.sinceLastDelivery, .sinceThirtyDaysAgo, true),
            (.sinceLastDelivery, .sinceStartOfToday, true),
            (.sinceThirtyDaysAgo, .sinceSevenDaysAgo, true),
            (.sinceThirtyDaysAgo, .sinceLastDelivery, false),
            (.sinceSevenDaysAgo, .sinceStartOfYesterday, true),
            (.sinceSevenDaysAgo, .sinceThirtyDaysAgo, false),
            (.sinceStartOfYesterday, .sinceStartOfToday, true),
            (.sinceStartOfToday, .sinceStartOfYesterday, false),
            (.sinceStartOfToday, .sinceStartOfToday, true)
        ]
        for (wider, narrower, expected) in cases {
            XCTAssertEqual(
                wider.covers(narrower),
                expected,
                "\(wider.rawValue) covers \(narrower.rawValue) should be \(expected)."
            )
        }
    }

    /// Not a restatement of the table above: this checks the property the table
    /// is supposed to encode, against floors computed from the calendar, and at
    /// two different moments — because the old window was in force over past
    /// days while the new one is judged today.
    func testCoverageAgreesWithTheFloorsAtAnyMoment() {
        let bounded = DeliveryWindow.allCases.filter(\.isBounded)
        let moments = [
            now,
            now.addingTimeInterval(-40 * 86_400),
            // Across a daylight-saving change, where a day is not 86,400
            // seconds long.
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9))!
        ]

        for moment in moments {
            for wider in bounded {
                for narrower in bounded {
                    guard
                        let a = wider.floor(now: moment, calendar: calendar),
                        let b = narrower.floor(now: moment, calendar: calendar)
                    else {
                        continue
                    }
                    XCTAssertEqual(
                        wider.covers(narrower),
                        a <= b,
                        "\(wider.rawValue) vs \(narrower.rawValue) disagrees with "
                            + "the dates at \(moment)."
                    )
                }
            }
        }
    }

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
            destination: Destination(name: "n", kind: .restAPI),
            now: now,
            calendar: calendar
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
            destination: Destination(name: "n", kind: .restAPI),
            now: now,
            calendar: calendar
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
            destination: Destination(name: "n", kind: .restAPI),
            now: now,
            calendar: calendar
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
            destination: Destination(name: "n", kind: .restAPI),
            now: now,
            calendar: calendar
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
                destination: Destination(name: "n", kind: .restAPI),
                now: now,
                calendar: calendar
            )
        ) { error in
            XCTAssertEqual(error as? DeliveryError, .windowNotApplicable)
        }
    }

    // MARK: - Through the engine

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
        let destination = endpoint(.sinceStartOfToday)
        try await engine.save(destination)

        _ = try await engine.deliver(batch(fourDays), to: destination, now: now)

        let sent = await channel.payloads()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(identifiers(in: sent[0]), ["d22"])
    }

    func testTheReceiptSaysHowManyReadingsTheWindowLeftOut() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [.restAPI: CapturingChannel()])
        let destination = endpoint(.sinceStartOfToday)
        try await engine.save(destination)

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
        let destination = endpoint(.sinceStartOfToday)
        try await engine.save(destination)

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
        var destination = endpoint(.sinceStartOfToday)
        try await engine.save(destination)
        try await commitACursor(store, for: destination.id)
        let before = try await store.streamRecords(scope: .destination(destination.id))
        XCTAssertFalse(before.isEmpty)

        destination.deliveryWindow = .sinceSevenDaysAgo
        try await engine.save(destination)

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
        var destination = endpoint(.sinceLastDelivery)
        try await engine.save(destination)
        try await commitACursor(store, for: destination.id)

        destination.deliveryWindow = .sinceStartOfToday
        try await engine.save(destination)

        let after = try await store.streamRecords(scope: .destination(destination.id))
        XCTAssertFalse(
            after.isEmpty,
            "Raising the floor excludes nothing that was already sent."
        )
    }

    func testAnOrdinaryReSaveDoesNotThrowAwayTheCursors() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        var destination = endpoint(.sinceStartOfToday)
        try await engine.save(destination)
        try await commitACursor(store, for: destination.id)

        destination.name = "Renamed"
        try await engine.save(destination)

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
        var destination = endpoint(.sinceStartOfToday)
        try await engine.save(destination)

        destination.deliveryWindow = .sinceThirtyDaysAgo
        try await engine.save(destination)

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
