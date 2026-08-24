import Foundation
@testable import HozzDeliver
import HozzCore
import HozzStore
import XCTest

/// What a delivery window does, and — more importantly — what it is not allowed
/// to do.
///
/// The dangerous case here is not a window that excludes too much. It is a
/// window that excludes a reading quietly, reports the delivery as complete, and
/// leaves that reading unreachable for ever, because the acquisition cursor has
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

    private func local(
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0
    ) -> Date {
        calendar.date(
            from: DateComponents(
                year: 2026,
                month: 8,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    // MARK: - The ranges are the ones a person would draw

    /// Every boundary below is written as a date in its own right, not derived
    /// from the range being tested.
    func testEachWindowCoversTheDaysItsNameClaims() {
        XCTAssertNil(
            DeliveryWindow.sinceLastDelivery.range(now: now, calendar: calendar),
            "The default is the absence of a range, not a very wide one."
        )

        XCTAssertEqual(
            DeliveryWindow.today.range(now: now, calendar: calendar),
            DateInterval(start: local(22), end: now)
        )
        XCTAssertEqual(
            DeliveryWindow.yesterday.range(now: now, calendar: calendar),
            DateInterval(start: local(21), end: local(22))
        )
        XCTAssertEqual(
            DeliveryWindow.previousDayAndToday.range(now: now, calendar: calendar),
            DateInterval(start: local(21), end: now)
        )
        XCTAssertEqual(
            DeliveryWindow.previous7Days.range(now: now, calendar: calendar),
            DateInterval(start: local(15), end: now)
        )
    }

    /// A day boundary is the user's midnight, not UTC's. On this date New York
    /// is four hours behind UTC, so local midnight is 04:00 UTC — and a reading
    /// at 02:00 UTC belongs to yesterday, not today.
    func testDaysAreTheUsersDaysRatherThanUTCDays() {
        let twoAMUTC = Date(timeIntervalSince1970: 1_787_364_000)

        XCTAssertFalse(
            DeliveryWindow.today.admits(twoAMUTC, now: now, calendar: calendar),
            "02:00 UTC on the 22nd is still the 21st in New York."
        )
        XCTAssertTrue(
            DeliveryWindow.yesterday.admits(twoAMUTC, now: now, calendar: calendar)
        )
    }

    func testAReadingOnEitherSideOfTheBoundaryLandsInOneWindowOnly() {
        let justBeforeMidnight = local(21, 23, 59)
        let midnight = local(22)

        XCTAssertTrue(
            DeliveryWindow.yesterday.admits(
                justBeforeMidnight,
                now: now,
                calendar: calendar
            )
        )
        XCTAssertFalse(
            DeliveryWindow.today.admits(
                justBeforeMidnight,
                now: now,
                calendar: calendar
            )
        )
        XCTAssertTrue(
            DeliveryWindow.today.admits(midnight, now: now, calendar: calendar)
        )
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

    // MARK: - Coverage, which is what decides whether history replays

    func testCoverageIsThePartialOrderTheWindowsActuallyHave() {
        let cases: [(DeliveryWindow, DeliveryWindow, Bool)] = [
            (.sinceLastDelivery, .previous7Days, true),
            (.sinceLastDelivery, .today, true),
            (.previous7Days, .previousDayAndToday, true),
            (.previous7Days, .today, true),
            (.previous7Days, .yesterday, true),
            (.previous7Days, .sinceLastDelivery, false),
            (.previousDayAndToday, .today, true),
            (.previousDayAndToday, .yesterday, true),
            (.previousDayAndToday, .previous7Days, false),
            (.today, .today, true),
            (.today, .yesterday, false),
            (.yesterday, .today, false),
            (.today, .previousDayAndToday, false)
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
    /// is supposed to encode, against ranges computed from the calendar.
    func testCoverageAgreesWithTheRangesThemselves() {
        let bounded: [DeliveryWindow] = [
            .today, .yesterday, .previousDayAndToday, .previous7Days
        ]
        for wider in bounded {
            for narrower in bounded {
                guard let a = wider.range(now: now, calendar: calendar),
                      let b = narrower.range(now: now, calendar: calendar)
                else {
                    continue
                }
                let containsRange = a.start <= b.start && a.end >= b.end
                XCTAssertEqual(
                    wider.covers(narrower),
                    containsRange,
                    "\(wider.rawValue) vs \(narrower.rawValue) disagrees with the dates."
                )
            }
        }
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

    func testABoundedWindowKeepsExactlyTheRecordsInsideIt() throws {
        let result = try DeliveryWindow.previousDayAndToday.apply(
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
        let result = try DeliveryWindow.today.apply(
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
        let onlyOld = Data(
            """
            {"id":"old","kind":"quantity","startDate":"2020-01-01T12:00:00.000Z"}

            """.utf8
        )
        let result = try DeliveryWindow.today.apply(
            to: batch(onlyOld),
            destination: Destination(name: "n", kind: .restAPI),
            now: now,
            calendar: calendar
        )

        XCTAssertNil(result.batch)
        XCTAssertEqual(result.excludedRecords, 1)
    }

    /// A payload this build cannot take apart must not be delivered whole. That
    /// would send readings the user asked to leave out and call it a success.
    func testAnUnreadablePayloadIsRefusedRatherThanSentUnfiltered() {
        let opaque = Data("not a record at all\n".utf8)

        XCTAssertThrowsError(
            try DeliveryWindow.today.apply(
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

    func testTheChannelNeverSeesRecordsTheWindowExcluded() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = CapturingChannel()
        let engine = DeliveryEngine(store: store, channels: [.restAPI: channel])
        var destination = Destination(
            name: "Home server",
            kind: .restAPI,
            endpointURL: URL(string: "https://example.com/health"),
            deliveryWindow: .today
        )
        destination.deliveryWindow = .today
        try await engine.save(destination)

        _ = try await engine.deliver(batch(fourDays), to: destination, now: now)

        let sent = await channel.payloads()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(identifiers(in: sent[0]), ["d22"])
    }

    func testTheReceiptSaysHowManyReadingsTheWindowLeftOut() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [.restAPI: CapturingChannel()])
        let destination = Destination(
            name: "Home server",
            kind: .restAPI,
            endpointURL: URL(string: "https://example.com/health"),
            deliveryWindow: .today
        )
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
        let destination = Destination(
            name: "Home server",
            kind: .restAPI,
            endpointURL: URL(string: "https://example.com/health"),
            deliveryWindow: .today
        )
        try await engine.save(destination)

        let old = Data(
            """
            {"id":"old","kind":"quantity","startDate":"2020-01-01T12:00:00.000Z"}

            """.utf8
        )
        let receipt = try await engine.deliver(batch(old), to: destination, now: now)

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

    /// The guarantee that makes a bounded window safe to offer at all.
    ///
    /// A narrow window excludes old readings and the cursor moves past them.
    /// Widening it clears the cursors, so those readings are read again and
    /// delivered. Without this, choosing "Today" once would silently make every
    /// earlier reading unreachable for that destination for good.
    func testWideningTheWindowClearsTheCursorsSoSkippedReadingsComeBack() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        var destination = Destination(
            name: "Home server",
            kind: .restAPI,
            endpointURL: URL(string: "https://example.com/health"),
            deliveryWindow: .today
        )
        try await engine.save(destination)
        try await commitACursor(store, for: destination.id)
        let before = try await store.streamRecords(scope: .destination(destination.id))
        XCTAssertFalse(before.isEmpty)

        destination.deliveryWindow = .previous7Days
        try await engine.save(destination)

        let after = try await store.streamRecords(scope: .destination(destination.id))
        XCTAssertTrue(
            after.isEmpty,
            "Widening has to replay, or the skipped readings never arrive."
        )
    }

    func testMovingBetweenTwoWindowsThatDoNotOverlapAlsoReplays() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        var destination = Destination(
            name: "Home server",
            kind: .restAPI,
            endpointURL: URL(string: "https://example.com/health"),
            deliveryWindow: .today
        )
        try await engine.save(destination)
        try await commitACursor(store, for: destination.id)

        destination.deliveryWindow = .yesterday
        try await engine.save(destination)

        let after = try await store.streamRecords(scope: .destination(destination.id))
        XCTAssertTrue(
            after.isEmpty,
            "Yesterday's readings were skipped while the window said today."
        )
    }

    /// Narrowing throws nothing away that was already delivered, so re-reading
    /// years of Health for no reason would be a cost with no benefit.
    func testNarrowingTheWindowLeavesTheCursorsWhereTheyAre() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        var destination = Destination(
            name: "Home server",
            kind: .restAPI,
            endpointURL: URL(string: "https://example.com/health"),
            deliveryWindow: .sinceLastDelivery
        )
        try await engine.save(destination)
        try await commitACursor(store, for: destination.id)

        destination.deliveryWindow = .today
        try await engine.save(destination)

        let after = try await store.streamRecords(scope: .destination(destination.id))
        XCTAssertFalse(
            after.isEmpty,
            "Narrowing excludes nothing that was already sent."
        )
    }

    func testAnOrdinaryReSaveDoesNotThrowAwayTheCursors() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let engine = DeliveryEngine(store: store, channels: [:])
        var destination = Destination(
            name: "Home server",
            kind: .restAPI,
            endpointURL: URL(string: "https://example.com/health"),
            deliveryWindow: .today
        )
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
        XCTAssertTrue(
            try XCTUnwrap(destination.unsupportedDescription).contains("date")
                || XCTUnwrap(destination.unsupportedDescription).contains("window")
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
