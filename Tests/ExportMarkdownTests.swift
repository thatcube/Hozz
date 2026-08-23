import Foundation
import HozzAcquire
import HozzCore
import HozzHealthFake
import HozzStore
import XCTest
@testable import HozzHealth

/// The daily-notes export throws most of the data away on purpose. These tests
/// hold it to the two things that makes acceptable: the summary it does keep
/// has to be right, and it has to say plainly that the rest is gone.
final class ExportMarkdownTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let steps = "HKQuantityTypeIdentifierStepCount"
    private let heartRate = "HKQuantityTypeIdentifierHeartRate"
    private let sleep = "HKCategoryTypeIdentifierSleepAnalysis"
    private let newYork = TimeZone(identifier: "America/New_York")!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    // MARK: - Fixtures

    private func quantity(
        id: String = UUID().uuidString.lowercased(),
        type: String,
        start: String,
        end: String? = nil,
        value: Double,
        unit: String = "count"
    ) -> [String: Any] {
        [
            "kind": "quantity",
            "schemaVersion": 1,
            "id": id,
            "type": type,
            "startDate": start,
            "endDate": end ?? start,
            "quantity": ["unit": unit, "value": value, "description": "\(value) \(unit)"],
            "source": ["name": "Apple Watch", "bundleIdentifier": "com.apple.health"],
            "metadata": [:]
        ]
    }

    private func sleepSegment(
        start: String,
        end: String,
        value: Int
    ) -> [String: Any] {
        [
            "kind": "category",
            "schemaVersion": 1,
            "id": UUID().uuidString.lowercased(),
            "type": sleep,
            "startDate": start,
            "endDate": end,
            "value": value,
            "source": ["name": "Apple Watch", "bundleIdentifier": "com.apple.health"],
            "metadata": [:]
        ]
    }

    private func workout(
        start: String,
        end: String,
        activityType: Int,
        duration: Double
    ) -> [String: Any] {
        [
            "kind": "workout",
            "schemaVersion": 1,
            "id": UUID().uuidString.lowercased(),
            "type": "HKWorkoutTypeIdentifier",
            "startDate": start,
            "endDate": end,
            "activityType": activityType,
            "duration": duration,
            "events": [],
            "source": ["name": "Apple Watch", "bundleIdentifier": "com.apple.workout"],
            "metadata": [:]
        ]
    }

    private func write(lines: [[String: Any]]) throws -> URL {
        let url = directory.url.appending(path: "spool-\(UUID().uuidString).ndjson")
        var data = Data()
        for line in lines {
            data.append(
                try JSONSerialization.data(
                    withJSONObject: line,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            )
            data.append(0x0A)
        }
        try data.write(to: url)
        return url
    }

    @discardableResult
    private func build(
        _ lines: [[String: Any]],
        timeZone: TimeZone? = nil
    ) throws -> (entries: [String: Data], statistics: ExportMarkdownStatistics) {
        let source = try write(lines: lines)
        let destination = directory.url.appending(path: "notes-\(UUID().uuidString).zip")
        let archive = try ZipStreamWriter(
            destinationURL: destination,
            modifiedAt: Date(timeIntervalSince1970: 1_767_225_600)
        )
        let statistics = try ExportMarkdownWriter.write(
            readingFrom: source,
            into: archive,
            metadata: ExportMarkdownWriter.Metadata(
                runID: UUID(),
                startedAt: Date(timeIntervalSince1970: 1_767_225_600),
                timeZone: timeZone ?? newYork
            )
        )
        _ = try archive.finish()
        return (try ExportArtifactReader.readZipEntries(at: destination), statistics)
    }

    private func note(_ entries: [String: Data], _ day: String) throws -> String {
        String(
            decoding: try XCTUnwrap(
                entries["Daily/\(day).md"],
                "There is no note for \(day). Entries: \(entries.keys.sorted())"
            ),
            as: UTF8.self
        )
    }

    // MARK: - One note per day

    func testEachDayGetsOneNoteNamedAfterIt() throws {
        let (entries, statistics) = try build([
            quantity(type: steps, start: "2026-01-02T15:00:00.000Z", value: 400),
            quantity(type: steps, start: "2026-01-02T18:00:00.000Z", value: 600),
            quantity(type: steps, start: "2026-01-04T18:00:00.000Z", value: 120)
        ])

        XCTAssertEqual(statistics.notesWritten, 2)
        XCTAssertEqual(statistics.retainedDays, 2)
        XCTAssertNotNil(entries["Daily/2026-01-02.md"])
        XCTAssertNotNil(entries["Daily/2026-01-04.md"])
        XCTAssertNil(
            entries["Daily/2026-01-03.md"],
            "A day with no records is not a note saying nothing happened."
        )
        XCTAssertNotNil(entries["README.md"])
        XCTAssertNotNil(entries["export-log.ndjson"])
    }

    func testTheNoteLeadsWithTheDaysTotals() throws {
        let (entries, _) = try build([
            quantity(type: steps, start: "2026-01-02T15:00:00.000Z", value: 4_200),
            quantity(type: steps, start: "2026-01-02T18:00:00.000Z", value: 4_221),
            quantity(
                type: "HKQuantityTypeIdentifierDistanceWalkingRunning",
                start: "2026-01-02T15:00:00.000Z",
                value: 6_200,
                unit: "m"
            ),
            quantity(
                type: "HKQuantityTypeIdentifierRestingHeartRate",
                start: "2026-01-02T09:00:00.000Z",
                value: 54,
                unit: "count/min"
            )
        ])
        let text = try note(entries, "2026-01-02")

        XCTAssertTrue(text.contains("# Friday, 2 January 2026"), text)
        XCTAssertTrue(text.contains("**8,421 steps**"), text)
        XCTAssertTrue(text.contains("**6.20 km**"), text)
        XCTAssertTrue(text.contains("Resting heart rate **54 bpm**"), text)
    }

    /// Dataview reads front matter, so the numbers have to be there as numbers
    /// and the keys have to say what they measure.
    func testFrontMatterCarriesTheNumbersDataviewWouldQuery() throws {
        let (entries, _) = try build([
            quantity(type: steps, start: "2026-01-02T15:00:00.000Z", value: 8_421),
            quantity(
                type: heartRate,
                start: "2026-01-02T15:00:00.000Z",
                value: 70,
                unit: "count/min"
            ),
            quantity(
                type: heartRate,
                start: "2026-01-02T16:00:00.000Z",
                value: 80,
                unit: "count/min"
            ),
            workout(
                start: "2026-01-02T13:00:00.000Z",
                end: "2026-01-02T13:45:00.000Z",
                activityType: 37,
                duration: 2_700
            )
        ])
        let text = try note(entries, "2026-01-02")
        let frontMatter = text
            .components(separatedBy: "---\n")[1]
            .split(separator: "\n")
            .map(String.init)

        XCTAssertTrue(text.hasPrefix("---\n"))
        XCTAssertTrue(frontMatter.contains("date: 2026-01-02"))
        XCTAssertTrue(frontMatter.contains("weekday: \"Friday\""))
        XCTAssertTrue(frontMatter.contains("time_zone: \"America/New_York\""))
        XCTAssertTrue(frontMatter.contains("steps: 8421"))
        XCTAssertTrue(
            frontMatter.contains("heart_rate_count_per_min: 75"),
            "A heart rate is averaged, not summed: \(frontMatter)"
        )
        XCTAssertTrue(frontMatter.contains("workouts: 1"))
        XCTAssertTrue(frontMatter.contains("workout_minutes: 45"))
        XCTAssertTrue(
            frontMatter.contains("lossy: true"),
            "The note has to admit what it is: \(frontMatter)"
        )
    }

    func testWorkoutsAreNamedRatherThanNumbered() throws {
        let (entries, _) = try build([
            workout(
                start: "2026-01-02T13:00:00.000Z",
                end: "2026-01-02T13:45:00.000Z",
                activityType: 37,
                duration: 2_700
            ),
            workout(
                start: "2026-01-02T18:30:00.000Z",
                end: "2026-01-02T19:00:00.000Z",
                activityType: 57,
                duration: 1_800
            )
        ])
        let text = try note(entries, "2026-01-02")

        XCTAssertTrue(text.contains("## Workouts"), text)
        XCTAssertTrue(text.contains("| 08:00 | Running | 45 m |"), text)
        XCTAssertTrue(text.contains("| 13:30 | Yoga | 30 m |"), text)
        XCTAssertTrue(text.contains("2 workouts totalling **1 h 15 m**"), text)
    }

    /// An activity Hozz has no name for is reported as the number Health gave,
    /// which is honest, rather than as "Other", which is a guess.
    func testAnUnknownActivityIsReportedAsItsNumber() {
        XCTAssertEqual(ExportMarkdownWriter.activityName(37), "Running")
        XCTAssertEqual(ExportMarkdownWriter.activityName(9_999), "Activity 9999")
        XCTAssertEqual(ExportMarkdownWriter.activityName(nil), "Workout")
    }

    // MARK: - Days, and which one a night belongs to

    /// A UTC day would put an evening in New York on the following morning.
    func testDaysFollowTheExportsTimeZoneRatherThanUTC() throws {
        let (entries, _) = try build(
            [
                // 20:00 on the 2nd in New York, which is the 3rd in UTC.
                quantity(type: steps, start: "2026-01-03T01:00:00.000Z", value: 500)
            ],
            timeZone: newYork
        )
        XCTAssertNotNil(entries["Daily/2026-01-02.md"])
        XCTAssertNil(entries["Daily/2026-01-03.md"])

        let (utcEntries, _) = try build(
            [quantity(type: steps, start: "2026-01-03T01:00:00.000Z", value: 500)],
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertNotNil(utcEntries["Daily/2026-01-03.md"])
    }

    /// Last night's sleep belongs to the morning you woke up, not to two notes
    /// either side of midnight.
    func testSleepIsFiledUnderTheDayItEnded() throws {
        let (entries, _) = try build([
            // 23:00 on the 2nd to 03:00 on the 3rd, New York time.
            sleepSegment(
                start: "2026-01-03T04:00:00.000Z",
                end: "2026-01-03T08:00:00.000Z",
                value: 1
            ),
            // 03:00 to 06:30 on the 3rd.
            sleepSegment(
                start: "2026-01-03T08:00:00.000Z",
                end: "2026-01-03T11:30:00.000Z",
                value: 4
            )
        ])

        XCTAssertNil(
            entries["Daily/2026-01-02.md"],
            "A night that ended on the 3rd should not also be filed on the 2nd."
        )
        let text = try note(entries, "2026-01-03")
        XCTAssertTrue(text.contains("Asleep for **7 h 30 m**"), text)
        XCTAssertTrue(text.contains("from 2 segments"), text)
        XCTAssertTrue(
            text.contains("filed under the day you woke up"),
            "The note has to explain the rule it used: \(text)"
        )
        XCTAssertTrue(text.contains("sleep_hours: 7.50"), text)
    }

    /// Sleep stage codes are an enumeration. Summing them would produce a
    /// number that looks like data and means nothing.
    func testCategoryCodesAreCountedButNotSummed() throws {
        let (entries, _) = try build([
            sleepSegment(
                start: "2026-01-03T08:00:00.000Z",
                end: "2026-01-03T09:00:00.000Z",
                value: 4
            ),
            sleepSegment(
                start: "2026-01-03T09:00:00.000Z",
                end: "2026-01-03T10:00:00.000Z",
                value: 5
            )
        ])
        let text = try note(entries, "2026-01-03")
        let row = try XCTUnwrap(
            text.split(separator: "\n").first { $0.contains("Sleep Analysis") }
        )

        XCTAssertTrue(row.contains("| 2 |"), "The readings are counted: \(row)")
        XCTAssertFalse(
            row.contains("| 9 |"),
            "Adding up sleep stage codes would be meaningless: \(row)"
        )
    }

    /// The same argument applies to a measurement that is sampled rather than
    /// accumulated: a day's heart rate has an average, not a total.
    func testAMeasuredTypeShowsAnAverageAndNoTotal() throws {
        let (entries, _) = try build([
            quantity(
                type: heartRate,
                start: "2026-01-02T15:00:00.000Z",
                value: 70,
                unit: "count/min"
            ),
            quantity(
                type: heartRate,
                start: "2026-01-02T16:00:00.000Z",
                value: 80,
                unit: "count/min"
            ),
            quantity(type: steps, start: "2026-01-02T16:00:00.000Z", value: 300),
            quantity(type: steps, start: "2026-01-02T17:00:00.000Z", value: 700)
        ])
        let text = try note(entries, "2026-01-02")
        let lines = text.split(separator: "\n").map(String.init)
        let heart = try XCTUnwrap(lines.first { $0.contains("| Heart Rate |") })
        let step = try XCTUnwrap(lines.first { $0.contains("| Step Count |") })

        XCTAssertEqual(
            heart,
            "| Heart Rate | 2 |  | 75 | 70 | 80 | count/min |",
            "150 is the sum of two heart rates and means nothing."
        )
        XCTAssertEqual(
            step,
            "| Step Count | 2 | 1,000 | 500 | 300 | 700 | count |",
            "Steps do accumulate, so the total is the number that matters."
        )
    }

    // MARK: - Honest about what it dropped

    func testEveryNoteSaysWhatItLeftOut() throws {
        let (entries, _) = try build([
            quantity(type: steps, start: "2026-01-02T15:00:00.000Z", value: 400)
        ])
        let text = try note(entries, "2026-01-02")

        XCTAssertTrue(text.contains("It keeps totals, not records"), text)
        XCTAssertTrue(
            text.contains("NDJSON, JSON, or SQLite"),
            "A lossy format should say where the whole thing lives: \(text)"
        )
    }

    func testTheArchiveExplainsItselfAndReportsWhatItCouldNotFile() throws {
        let (entries, statistics) = try build([
            [
                "kind": "manifest",
                "schemaVersion": 1,
                "run": "run-1",
                "catalogVersion": 3,
                "createdAt": "2026-01-01T00:00:00.000Z",
                "coverage": "authorization-scoped",
                "attemptedTypes": 2,
                "catalogTypes": 100
            ],
            quantity(type: steps, start: "2026-01-02T15:00:00.000Z", value: 400),
            ["kind": "deletion", "schemaVersion": 1, "id": "gone-1", "type": steps],
            [
                "kind": "typeSummary",
                "schemaVersion": 1,
                "type": heartRate,
                "records": 0,
                "queries": 1,
                "encodingErrors": 0,
                "state": "authorizationIndeterminate"
            ]
        ])

        XCTAssertEqual(statistics.deletionsSeen, 1)
        let readme = String(
            decoding: try XCTUnwrap(entries["README.md"]),
            as: UTF8.self
        )
        XCTAssertTrue(readme.contains("summary, not your data"), readme)
        XCTAssertTrue(readme.contains("America/New_York"), readme)
        XCTAssertTrue(
            readme.contains("Deletions (no day to file them under) | 1"),
            "A deletion has no day, so it is reported rather than dropped: \(readme)"
        )
        XCTAssertTrue(
            readme.contains("Heart Rate"),
            "Per-type coverage belongs in the summary too: \(readme)"
        )
        XCTAssertTrue(readme.contains("authorizationIndeterminate"), readme)

        // The run's own records travel with the archive, the way CSV carries
        // them, so what the notes leave out is still in the file.
        let log = try ExportArtifactReader.lines(
            in: try XCTUnwrap(entries["export-log.ndjson"])
        )
        XCTAssertEqual(log.count, 2)
        XCTAssertEqual(log.first?["kind"] as? String, "manifest")
    }

    func testAnUnreadableLineIsCountedRatherThanIgnored() throws {
        let url = directory.url.appending(path: "broken.ndjson")
        var data = try JSONSerialization.data(
            withJSONObject: quantity(
                type: steps,
                start: "2026-01-02T15:00:00.000Z",
                value: 400
            )
        )
        data.append(0x0A)
        data.append(Data("{not json\n".utf8))
        try data.write(to: url)

        let destination = directory.url.appending(path: "notes.zip")
        let archive = try ZipStreamWriter(destinationURL: destination, modifiedAt: .now)
        let statistics = try ExportMarkdownWriter.write(
            readingFrom: url,
            into: archive,
            metadata: ExportMarkdownWriter.Metadata(runID: UUID(), startedAt: .now)
        )
        _ = try archive.finish()

        XCTAssertEqual(statistics.unreadableLines, 1)
        let readme = String(
            decoding: try ExportArtifactReader.readZipEntries(at: destination)["README.md"] ?? Data(),
            as: UTF8.self
        )
        XCTAssertTrue(readme.contains("could not read | 1"), readme)
    }

    func testTheFormatDeclaresItselfLossy() {
        XCTAssertTrue(HealthExportFormat.markdown.isLossy)
        XCTAssertTrue(HealthExportFormat.csv.isLossy)
        XCTAssertFalse(HealthExportFormat.sqlite.isLossy)
        XCTAssertFalse(HealthExportFormat.ndjson.isLossy)
    }

    // MARK: - Bounded memory

    /// The summaries held between reading and writing must grow with how much
    /// calendar an export covers, never with how many records it contains.
    func testMemoryTracksDaysCoveredRatherThanRecordsRead() throws {
        func statistics(records: Int, perDay: Int) throws -> ExportMarkdownStatistics {
            var lines: [[String: Any]] = []
            for index in 0..<records {
                let day = (index / perDay) + 1
                lines.append(
                    quantity(
                        id: "sample-\(index)",
                        type: steps,
                        start: String(format: "2026-03-%02dT15:00:00.000Z", day),
                        value: 1
                    )
                )
            }
            return try build(lines).statistics
        }

        let few = try statistics(records: 300, perDay: 100)
        let many = try statistics(records: 3_000, perDay: 1_000)

        XCTAssertEqual(few.retainedDays, 3)
        XCTAssertEqual(
            many.retainedDays,
            few.retainedDays,
            "Ten times the records over the same three days must cost the same."
        )
        XCTAssertEqual(many.retainedTotals, few.retainedTotals)
        XCTAssertEqual(many.samplesSummarised, 3_000)
    }

    // MARK: - Through the engine

    func testAnExportRunProducesDailyNotes() async throws {
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let type = HealthTypeKey(steps)
        let source = ScriptedHealthDataSource(
            streams: [
                type: (0..<4).map { index in
                    HealthChange.upsert(
                        CapturedHealthObject(
                            id: UUID(),
                            type: type,
                            canonicalPayload: try! JSONSerialization.data(
                                withJSONObject: quantity(
                                    id: "step-\(index)",
                                    type: steps,
                                    start: "2026-01-02T15:00:00.000Z",
                                    value: 100
                                ),
                                options: [.sortedKeys, .withoutEscapingSlashes]
                            )
                        )
                    )
                }
            ]
        )
        let engine = HealthExportEngine(
            store: store,
            source: source,
            types: [type],
            batchSize: 2,
            lease: ExportWriterLease()
        )

        guard
            case .completed(let result) = try await engine.export(
                format: .markdown,
                progress: { _ in }
            )
        else {
            return XCTFail("The run should have completed.")
        }

        XCTAssertEqual(result.fileURL.pathExtension, "zip")
        let entries = try ExportArtifactReader.readZipEntries(at: result.fileURL)
        let names = Set(entries.keys)
        XCTAssertTrue(names.contains("README.md"))
        XCTAssertTrue(names.contains("export-log.ndjson"))
        XCTAssertEqual(
            names.filter { $0.hasPrefix("Daily/") },
            ["Daily/2026-01-02.md"]
        )

        let text = String(
            decoding: try XCTUnwrap(entries["Daily/2026-01-02.md"]),
            as: UTF8.self
        )
        XCTAssertTrue(text.contains("**400 steps**"), text)
    }
}
