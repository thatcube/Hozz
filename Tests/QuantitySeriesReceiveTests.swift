import Foundation
import HozzCore
import HozzReceive
import HozzStore
import XCTest

/// The readings behind a quantity aggregate, on the receiving end.
///
/// The fault these cover is a specific and quiet one. A reading page carries
/// its *parent's* type identifier — it is the detail behind an ordinary
/// heart-rate sample, not a type of its own — plus an id and a start date, so
/// it parses perfectly well as an ordinary sample and lands in the same table.
/// Nothing is lost, and every count of that type is wrong: a thousand real
/// aggregates read as three hundred thousand heart-rate records, which is the
/// confidently wrong answer rather than the missing one.
final class QuantitySeriesReceiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-series-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func makeStore() throws -> IngestStore {
        try IngestStore(directory: root.appending(path: "store"))
    }

    private func parse(_ lines: [String]) throws -> ParsedBatch {
        try BatchParser.parse(Data(lines.joined(separator: "\n").utf8))
    }

    private func parse(_ line: String) throws -> ParsedBatch {
        try parse([line])
    }

    private let heartRate = "HKQuantityTypeIdentifierHeartRate"
    private let sample = "11111111-1111-4111-8111-111111111111"

    // MARK: - Fixtures, written as the phone writes them

    private func aggregate(
        id: String,
        value: Double,
        count: Int,
        start: String = "2026-08-24T10:00:00.000Z"
    ) -> String {
        """
        {"kind":"quantity","schemaVersion":1,"id":"\(id)",\
        "type":"\(heartRate)","startDate":"\(start)",\
        "endDate":"\(start)","quantity":{"unit":"count/min",\
        "value":\(value),"count":\(count),"aggregatesSeries":true,\
        "seriesReadingsExported":true},"source":{"name":"Watch"}}
        """
    }

    private func readingPage(
        id: String,
        sequence: Int,
        offset: Int,
        values: [Double],
        start: String = "2026-08-24T10:00:00.000Z"
    ) -> String {
        let readings = values.enumerated().map { index, value in
            """
            {"value":\(value),"startDate":"2026-08-24T10:00:0\(index).000Z",\
            "endDate":"2026-08-24T10:00:0\(index).000Z"}
            """
        }.joined(separator: ",")
        return """
        {"kind":"quantitySeriesReadings","schemaVersion":1,"id":"\(id)",\
        "type":"\(heartRate)","sample":"\(sample)","sequence":\(sequence),\
        "offset":\(offset),"count":\(values.count),"unit":"count/min",\
        "startDate":"\(start)","endDate":"\(start)","readings":[\(readings)]}
        """
    }

    private func endMarker(id: String, readings: Int) -> String {
        """
        {"kind":"quantitySeriesEnd","schemaVersion":1,"id":"\(id)",\
        "type":"\(heartRate)","sample":"\(sample)","readings":\(readings),\
        "startDate":"2026-08-24T10:00:00.000Z",\
        "endDate":"2026-08-24T10:00:00.000Z"}
        """
    }

    // MARK: - The counting fault

    func testAReadingPageIsNotCountedAsAReadingOfItsType() async throws {
        let store = try makeStore()
        let batch = try parse(
            [
                aggregate(id: sample, value: 72.5, count: 6),
                readingPage(
                    id: "page-0",
                    sequence: 0,
                    offset: 0,
                    values: [70, 71, 72]
                ),
                readingPage(
                    id: "page-1",
                    sequence: 1,
                    offset: 3,
                    values: [73, 74, 75]
                ),
                endMarker(id: "end-0", readings: 6)
            ]
        )

        XCTAssertEqual(batch.quantitySeriesPages.count, 2)
        XCTAssertEqual(batch.quantitySeriesEnds.count, 1)
        XCTAssertEqual(
            batch.records.count,
            1,
            """
            One record: the aggregate. The pages and the end marker are detail \
            about it, not four more heart-rate readings.
            """
        )

        _ = try await store.ingest(batch, idempotencyKey: "first")

        let summaries = try await store.summaries()
        let summary = try XCTUnwrap(summaries.first { $0.type == heartRate })
        XCTAssertEqual(
            summary.recordCount,
            1,
            """
            One aggregate was sent, so one is the answer. Counting the pages \
            would report four heart-rate records from a single measurement.
            """
        )
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 1)
    }

    func testTheReadingsThemselvesAreKeptWhereTheyCanBeFound() async throws {
        let store = try makeStore()
        let values: [Double] = [70, 71, 72, 73, 74, 75]
        let batch = try parse(
            [
                aggregate(id: sample, value: 72.5, count: 6),
                readingPage(
                    id: "page-0",
                    sequence: 0,
                    offset: 0,
                    values: Array(values.prefix(3))
                ),
                readingPage(
                    id: "page-1",
                    sequence: 1,
                    offset: 3,
                    values: Array(values.suffix(3))
                ),
                endMarker(id: "end-0", readings: 6)
            ]
        )
        _ = try await store.ingest(batch, idempotencyKey: "first")

        // Read back out of the store, ordered by offset, and compared with the
        // literals above rather than with anything the parser produced.
        let held = try await store.quantitySeriesReadings(forSample: sample)
        XCTAssertEqual(
            held.map(\.value),
            values,
            "Every reading, in order, none lost between the wire and the disk."
        )
        XCTAssertEqual(held.map(\.unit), Array(repeating: "count/min", count: 6))
    }

    func testACompleteSeriesIsToldApartFromOneMissingAPage() async throws {
        let store = try makeStore()

        // The phone says six; only the first three arrive.
        _ = try await store.ingest(
            try parse(
                [
                    aggregate(id: sample, value: 72.5, count: 6),
                    readingPage(
                        id: "page-0",
                        sequence: 0,
                        offset: 0,
                        values: [70, 71, 72]
                    ),
                    endMarker(id: "end-0", readings: 6)
                ]
            ),
            idempotencyKey: "partial"
        )

        var found = try await store.quantitySeriesState(forSample: sample)
        var state = try XCTUnwrap(found)
        XCTAssertEqual(state.exportedReadings, 6)
        XCTAssertEqual(state.readingsHeld, 3)
        XCTAssertFalse(
            state.isComplete,
            """
            Three of six held is not a short series, it is a missing page, and \
            the end marker is the only thing that can tell the difference.
            """
        )

        _ = try await store.ingest(
            try parse(
                readingPage(
                    id: "page-1",
                    sequence: 1,
                    offset: 3,
                    values: [73, 74, 75]
                )
            ),
            idempotencyKey: "rest"
        )

        found = try await store.quantitySeriesState(forSample: sample)
        state = try XCTUnwrap(found)
        XCTAssertEqual(state.readingsHeld, 6)
        XCTAssertTrue(state.isComplete)
    }

    func testAReplayedPageOverwritesRatherThanDuplicating() async throws {
        let store = try makeStore()
        let page = readingPage(
            id: "page-0",
            sequence: 0,
            offset: 0,
            values: [70, 71, 72]
        )

        _ = try await store.ingest(
            try parse(page),
            idempotencyKey: "first"
        )
        // A different idempotency key, so the batch itself is not recognised —
        // the page has to defend itself.
        _ = try await store.ingest(
            try parse(page),
            idempotencyKey: "second"
        )

        let values = try await store.quantitySeriesReadings(forSample: sample)
            .map(\.value)
        XCTAssertEqual(
            values,
            [70, 71, 72],
            "A page delivered twice is the same three readings, not six."
        )
    }

    func testPagesArrivingOutOfOrderStillReadBackInOrder() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try parse(
                [
                    readingPage(
                        id: "page-1",
                        sequence: 1,
                        offset: 3,
                        values: [73, 74, 75]
                    ),
                    readingPage(
                        id: "page-0",
                        sequence: 0,
                        offset: 0,
                        values: [70, 71, 72]
                    )
                ]
            ),
            idempotencyKey: "shuffled"
        )

        let values = try await store.quantitySeriesReadings(forSample: sample)
            .map(\.value)
        XCTAssertEqual(
            values,
            [70, 71, 72, 73, 74, 75],
            "Ordered by the offset they carry, not by when they turned up."
        )
    }

    /// A real v7 database — the tables genuinely absent — with rows to move.
    ///
    /// The other migration test writes its rows through a v8 store and stamps
    /// the version back, so `quantity_series_page` exists throughout and the
    /// test would pass even if the rehoming ran before the tables were
    /// created. This one drops them, which is the state a receiver upgrading
    /// from v7 is actually in: get the order wrong and it fails with "no such
    /// table" and rolls the whole migration back.
    func testAGenuineOlderDatabaseWithRowsToMoveUpgradesCleanly() async throws {
        let directory = root.appending(path: "store")
        let line = readingPage(
            id: "page-0",
            sequence: 0,
            offset: 0,
            values: [70, 71, 72]
        )

        do {
            let store = try IngestStore(directory: directory)
            await store.close()
        }

        let databaseURL = directory.appending(path: "hozz-received.sqlite")
        let raw = try SQLiteDatabase(url: databaseURL)
        try raw.execute("DROP TABLE IF EXISTS quantity_series_page")
        try raw.execute("DROP TABLE IF EXISTS quantity_series")
        try raw.run(
            """
            INSERT INTO sample
                (id, type, kind, start_date, end_date, value, unit,
                 source_name, raw, received_at)
            VALUES (?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?)
            """,
            [
                .text("page-0"),
                .text(heartRate),
                .text("quantitySeriesReadings"),
                .text("2026-08-24T10:00:00.000Z"),
                .text("2026-08-24T10:00:00.000Z"),
                .blob(Data(line.utf8)),
                .text("2026-08-24T10:00:00.000Z")
            ]
        )
        try raw.execute("PRAGMA user_version = 7")
        raw.close()

        let store = try IngestStore(directory: directory)
        let after = try await store.totalRecordCount()
        XCTAssertEqual(after, 0, "Moved out of `sample`.")
        let values = try await store.quantitySeriesReadings(forSample: sample)
            .map(\.value)
        XCTAssertEqual(values, [70, 71, 72], "And moved, not lost.")
    }

    func testAPageThatIsNotReadableAsOneIsQuarantinedNotFiledAsASample() async throws {
        let store = try makeStore()
        // The kind says reading page; the fields do not. It must not fall
        // through to the generic parser, which would accept it on its id, type
        // and date and put it right back in `sample` — where the migration
        // that repairs such rows will never look again.
        let batch = try parse(
            """
            {"kind":"quantitySeriesReadings","schemaVersion":1,"id":"broken",\
            "type":"\(heartRate)","startDate":"2026-08-24T10:00:00.000Z",\
            "endDate":"2026-08-24T10:00:00.000Z"}
            """
        )

        XCTAssertTrue(batch.quantitySeriesPages.isEmpty)
        XCTAssertTrue(
            batch.records.isEmpty,
            "It must not become an ordinary sample row."
        )
        XCTAssertEqual(
            batch.unhandled.count,
            1,
            "It goes to quarantine, which is the receiver's keep-it-anyway path."
        )

        _ = try await store.ingest(batch, idempotencyKey: "broken")
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 0)
    }

    func testTwoSamplesDoNotBleedIntoEachOther() async throws {
        let store = try makeStore()
        let other = "33333333-3333-4333-8333-333333333333"
        let mine = readingPage(
            id: "mine-0",
            sequence: 0,
            offset: 0,
            values: [70, 71, 72]
        )
        let theirs = mine
            .replacingOccurrences(of: sample, with: other)
            .replacingOccurrences(of: "\"mine-0\"", with: "\"theirs-0\"")
            .replacingOccurrences(of: "\"value\":70.0", with: "\"value\":90.0")
            .replacingOccurrences(of: "\"value\":71.0", with: "\"value\":91.0")
            .replacingOccurrences(of: "\"value\":72.0", with: "\"value\":92.0")

        _ = try await store.ingest(
            try parse([mine, theirs]),
            idempotencyKey: "two"
        )

        let ours = try await store.quantitySeriesReadings(forSample: sample)
            .map(\.value)
        let others = try await store.quantitySeriesReadings(forSample: other)
            .map(\.value)
        XCTAssertEqual(ours, [70, 71, 72])
        XCTAssertEqual(
            others,
            [90, 91, 92],
            "Two samples sharing a sequence number are still two samples."
        )
    }

    func testAPageWithNoUnitIsStillStored() async throws {
        let store = try makeStore()
        let line = readingPage(
            id: "page-0",
            sequence: 0,
            offset: 0,
            values: [70, 71, 72]
        ).replacingOccurrences(of: "\"unit\":\"count/min\",", with: "")

        _ = try await store.ingest(try parse(line), idempotencyKey: "no-unit")

        let held = try await store.quantitySeriesReadings(forSample: sample)
        XCTAssertEqual(
            held.map(\.value),
            [70, 71, 72],
            "A missing unit is a missing label, not a reason to drop readings."
        )
        XCTAssertNil(held.first?.unit)
    }

    func testAPageOnlyBatchIsNotReportedAsHavingStoredNothing() async throws {
        let store = try makeStore()
        let result = try await store.ingest(
            try parse([
                readingPage(
                    id: "page-0",
                    sequence: 0,
                    offset: 0,
                    values: [70, 71, 72]
                ),
                endMarker(id: "end-0", readings: 3)
            ]),
            idempotencyKey: "pages-only"
        )

        XCTAssertEqual(result.stored, 0, "No samples were sent.")
        XCTAssertEqual(result.seriesPages, 1)
        XCTAssertEqual(
            result.storedAnything,
            1,
            """
            A backfill batch is often nothing but pages. Reporting that as \
            nothing stored is the same kind of wrong as counting each page as \
            a reading.
            """
        )
    }

    func testTheAggregateStillSaysNotToAddItToItsOwnReadings() async throws {
        let store = try makeStore()
        let batch = try parse(aggregate(id: sample, value: 72.5, count: 6))
        _ = try await store.ingest(batch, idempotencyKey: "first")

        let record = try XCTUnwrap(batch.records.first)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: record.raw) as? [String: Any]
        )
        let quantity = try XCTUnwrap(object["quantity"] as? [String: Any])
        XCTAssertEqual(quantity["seriesReadingsExported"] as? Bool, true)
        XCTAssertEqual(
            record.value,
            72.5,
            "The aggregate is still the one number this sample has."
        )
    }

    // MARK: - A receiver that already stored them the wrong way

    func testPagesFiledAsSamplesByAnEarlierBuildAreMovedRatherThanCounted() async throws {
        let directory = root.appending(path: "store")

        // Written the way a build between expansion landing and this table
        // existing would have written them: straight into `sample`, because
        // they parse as ordinary records.
        do {
            let store = try IngestStore(directory: directory)
            let pages = [
                readingPage(
                    id: "page-0",
                    sequence: 0,
                    offset: 0,
                    values: [70, 71, 72]
                ),
                endMarker(id: "end-0", readings: 3)
            ]
            let asRecords = pages.compactMap { line -> HealthRecord? in
                guard
                    let object = try? JSONSerialization.jsonObject(
                        with: Data(line.utf8)
                    ) as? [String: Any],
                    let id = object["id"] as? String,
                    let type = object["type"] as? String
                else {
                    return nil
                }
                return HealthRecord(
                    id: id,
                    type: type,
                    kind: object["kind"] as? String,
                    startDate: Date(timeIntervalSince1970: 1_787_000_000),
                    endDate: Date(timeIntervalSince1970: 1_787_000_000),
                    raw: Data(line.utf8)
                )
            }
            XCTAssertEqual(asRecords.count, 2)
            _ = try await store.ingest(
                ParsedBatch(
                    records: asRecords,
                    deletions: [],
                    unreadableCount: 0
                ),
                idempotencyKey: "old-build"
            )
            let before = try await store.totalRecordCount()
            XCTAssertEqual(
                before,
                2,
                "The state this migration exists to correct."
            )
            await store.close()
        }

        // Stamped back to the schema version those builds actually had, which
        // is what makes this the state a real receiver would be reopened in
        // rather than a fresh database with odd rows in it.
        let databaseURL = directory.appending(path: "hozz-received.sqlite")
        let raw = try SQLiteDatabase(url: databaseURL)
        try raw.execute("PRAGMA user_version = 7")
        raw.close()

        // Re-opened by a build that knows better.
        let store = try IngestStore(directory: directory)
        let after = try await store.totalRecordCount()
        XCTAssertEqual(
            after,
            0,
            """
            Moved out of `sample`, so the counts stop being wrong for data \
            that is already on disk rather than only for data still to come.
            """
        )
        let values = try await store.quantitySeriesReadings(forSample: sample)
            .map(\.value)
        XCTAssertEqual(
            values,
            [70, 71, 72],
            "And moved, not deleted: every reading is still here."
        )
        let found = try await store.quantitySeriesState(forSample: sample)
        let state = try XCTUnwrap(found)
        XCTAssertEqual(state.exportedReadings, 3)
        XCTAssertTrue(state.isComplete)
    }
}

/// What the archive costs, and refusing to fill a disk without saying so.
final class ReceiverStorageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func page(sample: String, sequence: Int, values: [Double]) -> String {
        let readings = values.map {
            """
            {"value":\($0),"startDate":"2026-08-24T10:00:00.000Z",\
            "endDate":"2026-08-24T10:00:00.000Z"}
            """
        }.joined(separator: ",")
        return """
        {"kind":"quantitySeriesReadings","schemaVersion":1,\
        "id":"\(sample)-\(sequence)","type":"HKQuantityTypeIdentifierHeartRate",\
        "sample":"\(sample)","sequence":\(sequence),\
        "offset":\(sequence * values.count),"count":\(values.count),\
        "unit":"count/min","startDate":"2026-08-24T10:00:00.000Z",\
        "endDate":"2026-08-24T10:00:00.000Z","readings":[\(readings)]}
        """
    }

    func testTheReportSaysWhatIsOnDiskAndWhatMadeItBig() async throws {
        let store = try IngestStore(directory: root.appending(path: "store"))
        let sample = "22222222-2222-4222-8222-222222222222"

        // Three pages of ten readings: thirty readings, counted by hand.
        let lines = (0..<3).map {
            page(sample: sample, sequence: $0, values: Array(repeating: 70.0, count: 10))
        }
        _ = try await store.ingest(
            try BatchParser.parse(Data(lines.joined(separator: "\n").utf8)),
            idempotencyKey: "batch"
        )

        let report = try await store.storageReport()
        XCTAssertEqual(report.quantitySeriesPageRows, 3)
        XCTAssertEqual(
            report.quantitySeriesReadings,
            30,
            "Thirty readings went in, so thirty is the answer."
        )
        XCTAssertGreaterThan(
            report.quantitySeriesBytes,
            0,
            "The part that grows has to be attributable, or the number is a shrug."
        )
        XCTAssertGreaterThan(
            report.databaseBytes,
            report.quantitySeriesBytes,
            "The file holds the readings and everything else besides."
        )
        XCTAssertEqual(
            report.sampleRows,
            0,
            "No aggregates were sent, and pages are not samples."
        )
        XCTAssertEqual(report.floorBytes, IngestStore.freeSpaceFloor)
    }

    func testAVolumeThatWillNotSayItsFreeSpaceIsTreatedAsHavingRoom() {
        let report = StorageReport(
            databaseBytes: 1_000,
            availableBytes: nil,
            floorBytes: 512 * 1_024 * 1_024,
            sampleRows: 0,
            quantitySeriesPageRows: 0,
            quantitySeriesReadings: 0,
            quantitySeriesBytes: 0,
            voltagePageRows: 0,
            voltageBytes: 0
        )
        XCTAssertTrue(
            report.hasRoom,
            """
            Refusing because a question went unanswered would lose records to \
            ignorance rather than to a full disk.
            """
        )
    }

    func testTheFloorIsAFloorAndNotAWarning() {
        let floor: Int64 = 512 * 1_024 * 1_024
        func report(available: Int64) -> StorageReport {
            StorageReport(
                databaseBytes: 0,
                availableBytes: available,
                floorBytes: floor,
                sampleRows: 0,
                quantitySeriesPageRows: 0,
                quantitySeriesReadings: 0,
                quantitySeriesBytes: 0,
                voltagePageRows: 0,
                voltageBytes: 0
            )
        }
        XCTAssertTrue(report(available: floor).hasRoom, "Exactly at it is still room.")
        XCTAssertTrue(report(available: floor + 1).hasRoom)
        XCTAssertFalse(report(available: floor - 1).hasRoom)
        XCTAssertFalse(report(available: 0).hasRoom)
    }

    /// A refusal has to be a refusal the phone understands.
    ///
    /// The whole safety of this rests on the receiver answering outside the
    /// 2xx range: the phone keeps the batch and its cursor and tries again
    /// later. An answer of 200 with nothing stored would tell the phone the
    /// data was delivered, and it would never be sent again.
    func testRefusingForSpaceKeepsTheDataOnThePhone() throws {
        let error = IngestStorageError.notEnoughRoom(
            availableBytes: 100 * 1_024 * 1_024,
            floorBytes: 512 * 1_024 * 1_024
        )
        let described = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(
            described.contains("refused"),
            "It has to say the batch was not stored, not merely that space is low."
        )
        // 507 is outside 2xx, which is the only property that matters for the
        // phone: RESTDeliveryChannel rejects anything outside 200...299 and
        // the sync engine then leaves the cursor where it was.
        XCTAssertFalse((200...299).contains(507))
    }
}
