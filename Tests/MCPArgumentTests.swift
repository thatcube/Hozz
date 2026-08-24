import Foundation
import HozzMCP
import HozzReceive
import XCTest

/// Covers two ways `aggregate_health_data` answered confidently and wrongly.
///
/// Both were found by probing the shipped tool rather than by reading it, and
/// both share a shape: something the app already knew, copied and drifted.
///
/// Expectations here are worked out by hand from the fixture. Where a count is
/// asserted it is a count somebody has actually done — not a second call to the
/// code under test, which could only ever prove the copy agrees with itself.
final class MCPArgumentTests: XCTestCase {
    private var root: URL!

    /// A zone behind UTC, so a bare date read as UTC would visibly capture the
    /// wrong samples rather than coincidentally agreeing.
    private let zone = TimeZone(identifier: "America/New_York")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-mcp-args-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Harness

    private func store(_ objects: [[String: Any]]) async throws -> IngestStore {
        let store = try IngestStore(directory: root.appending(path: "store"))
        guard !objects.isEmpty else { return store }
        var data = Data()
        for object in objects {
            data.append(
                try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                )
            )
            data.append(0x0A)
        }
        _ = try await store.ingest(
            try BatchParser.parse(data),
            idempotencyKey: UUID().uuidString
        )
        return store
    }

    private func call(
        _ store: IngestStore,
        _ name: String,
        _ arguments: [String: Any]
    ) async throws -> [String: Any] {
        let server = MCPServer(store: store)
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ]
        let data = try JSONSerialization.data(withJSONObject: message)
        let raw = await server.handle(data)
        let reply = try XCTUnwrap(raw)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        )
    }

    /// The text of a successful reply.
    private func text(_ response: [String: Any]) throws -> String {
        let result = try XCTUnwrap(
            response["result"] as? [String: Any],
            "expected a result, got \(response)"
        )
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    /// Whether the reply is an error, and what it said.
    private func failure(_ response: [String: Any]) -> String? {
        if let error = response["error"] as? [String: Any] {
            return error["message"] as? String
        }
        // A tool may also report failure inside a successful envelope.
        if let result = response["result"] as? [String: Any],
           result["isError"] as? Bool == true,
           let content = result["content"] as? [[String: Any]] {
            return content.first?["text"] as? String
        }
        return nil
    }

    private func steps(_ id: String, _ utc: String, _ value: Double) -> [String: Any] {
        [
            "kind": "quantity", "id": id,
            "type": "HKQuantityTypeIdentifierStepCount",
            "startDate": utc, "endDate": utc,
            "quantity": ["unit": "count", "value": value]
        ]
    }

    private func standHour(
        _ id: String,
        _ start: Date,
        stood: Bool
    ) -> [String: Any] {
        [
            "kind": "category", "id": id,
            "type": "HKCategoryTypeIdentifierAppleStandHour",
            "startDate": Timestamps.text(from: start),
            "endDate": Timestamps.text(
                from: start.addingTimeInterval(3600)
            ),
            // 0 is stood, 1 is idle.
            "value": stood ? 0 : 1
        ]
    }

    private func local(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0
    ) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.timeZone = zone
        return try XCTUnwrap(calendar.date(from: components))
    }

    // MARK: - A bare date is a date, not nothing

    /// A date without a time filters, rather than being silently discarded.
    ///
    /// This is the bug in its plainest form: `from: 2026-08-01` parsed to
    /// nothing, the filter was dropped, and four years of history came back.
    /// An assistant asked "how many steps last week" then reported 2022.
    func testABareDateActuallyFiltersInsteadOfReturningEverything() async throws {
        let store = try await store([
            steps("old", "2022-02-19T15:00:00.000Z", 111),
            steps("new", "2026-08-17T15:00:00.000Z", 222)
        ])

        let reply = try await call(store, "aggregate_health_data", [
            "type": "HKQuantityTypeIdentifierStepCount",
            "bucket": "day",
            "from": "2026-08-01"
        ])
        let body = try text(reply)

        XCTAssertTrue(body.contains("222"), body)
        XCTAssertFalse(
            body.contains("111"),
            "the 2022 sample is before the requested start:\n\(body)"
        )
        XCTAssertFalse(body.contains("2022-02-19"), body)
    }

    /// An upper bound given as a bare date includes that whole day.
    ///
    /// The tool documents its range as inclusive, and nobody saying "to the
    /// 17th" means "up to midnight on the 17th".
    func testABareEndDateIncludesTheWholeOfThatDay() async throws {
        let store = try await store([
            // 23:00 local on 17 August, which is 03:00 UTC on the 18th.
            steps("late", "2026-08-18T03:00:00.000Z", 500),
            steps("next", "2026-08-19T15:00:00.000Z", 900)
        ])

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKQuantityTypeIdentifierStepCount",
                "bucket": "day",
                "to": "2026-08-17"
            ])
        )

        XCTAssertTrue(
            body.contains("500"),
            "an evening on the 17th is still the 17th:\n\(body)"
        )
        XCTAssertFalse(body.contains("900"), body)
    }

    /// A bare date is read in the zone the buckets are built in.
    func testABareDateIsReadLocallyNotAsUTC() async throws {
        // 02:00 UTC on 1 August is 22:00 local on 31 July, so a start of
        // "2026-08-01" must exclude it.
        let store = try await store([
            steps("july", "2026-08-01T02:00:00.000Z", 42),
            steps("august", "2026-08-01T16:00:00.000Z", 84)
        ])

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKQuantityTypeIdentifierStepCount",
                "bucket": "day",
                "from": "2026-08-01"
            ])
        )

        XCTAssertTrue(body.contains("84"), body)
        XCTAssertFalse(
            body.contains("42"),
            "22:00 on 31 July is not on or after 1 August:\n\(body)"
        )
    }

    /// A full timestamp still means exactly what it says.
    func testAFullTimestampIsUnchanged() async throws {
        let store = try await store([
            steps("old", "2022-02-19T15:00:00.000Z", 111),
            steps("new", "2026-08-17T15:00:00.000Z", 222)
        ])

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKQuantityTypeIdentifierStepCount",
                "bucket": "day",
                "from": "2026-08-01T00:00:00Z"
            ])
        )

        XCTAssertTrue(body.contains("222"), body)
        XCTAssertFalse(body.contains("111"), body)
    }

    /// Something nobody could have meant is refused, by name.
    func testAnUnreadableDateIsRefusedRatherThanIgnored() async throws {
        let store = try await store([
            steps("old", "2022-02-19T15:00:00.000Z", 111)
        ])

        for bad in ["last tuesday", "2026-13-45", "17/08/2026", "2026-02-31"] {
            let reply = try await call(store, "aggregate_health_data", [
                "type": "HKQuantityTypeIdentifierStepCount",
                "from": bad
            ])
            let message = try XCTUnwrap(
                failure(reply),
                "\"\(bad)\" was accepted rather than refused"
            )
            XCTAssertTrue(
                message.contains("from"),
                "the message should name the argument: \(message)"
            )
            XCTAssertTrue(
                message.contains(bad),
                "the message should quote what could not be read: \(message)"
            )
        }
    }

    /// A misspelled bucket is refused, listing the ones that exist.
    ///
    /// It used to fall through to `day`, so "weekly" quietly answered daily.
    func testAnUnknownBucketIsRefusedWithTheValidOnes() async throws {
        let store = try await store([
            steps("a", "2026-08-17T15:00:00.000Z", 10)
        ])

        let reply = try await call(store, "aggregate_health_data", [
            "type": "HKQuantityTypeIdentifierStepCount",
            "bucket": "weekly"
        ])
        let message = try XCTUnwrap(failure(reply))
        XCTAssertTrue(message.contains("bucket"), message)
        XCTAssertTrue(message.contains("week"), message)
        XCTAssertTrue(message.contains("month"), message)
    }

    /// An absent argument is still absent, not an error.
    func testOmittingTheRangeStillReturnsEverything() async throws {
        let store = try await store([
            steps("old", "2022-02-19T15:00:00.000Z", 111),
            steps("new", "2026-08-17T15:00:00.000Z", 222)
        ])

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKQuantityTypeIdentifierStepCount"
            ])
        )
        XCTAssertTrue(body.contains("111"), body)
        XCTAssertTrue(body.contains("222"), body)
    }

    /// An explicit JSON `null` means "no bound", not a broken argument.
    ///
    /// A model filling a schema emits one for every optional property it has
    /// no value for. `JSONSerialization` decodes it to `NSNull`, which is not
    /// `nil`, so the first version of the strict parsing refused every one of
    /// them and failed calls that were perfectly well formed.
    func testAnExplicitNullIsTreatedAsNoBound() async throws {
        let store = try await store([
            steps("old", "2022-02-19T15:00:00.000Z", 111),
            steps("new", "2026-08-17T15:00:00.000Z", 222)
        ])

        let arguments = try JSONSerialization.jsonObject(
            with: Data(
                """
                {"type":"HKQuantityTypeIdentifierStepCount",
                 "bucket":null,"from":null,"to":null}
                """.utf8
            )
        ) as? [String: Any]
        let body = try text(
            await call(store, "aggregate_health_data", try XCTUnwrap(arguments))
        )

        XCTAssertTrue(body.contains("111"), body)
        XCTAssertTrue(body.contains("222"), body)
    }

    /// A range the wrong way round is named, not answered as an empty archive.
    func testABackwardsRangeIsRefusedRatherThanReportedEmpty() async throws {
        let store = try await store([
            steps("a", "2026-08-17T15:00:00.000Z", 10)
        ])

        let reply = try await call(store, "aggregate_health_data", [
            "type": "HKQuantityTypeIdentifierStepCount",
            "from": "2026-08-17",
            "to": "2026-08-01"
        ])
        let message = try XCTUnwrap(
            failure(reply),
            "a backwards range must not read as \"you have no data\""
        )
        XCTAssertTrue(message.contains("wrong way round"), message)
    }

    /// A clock component nobody could have meant is refused.
    ///
    /// Hour and minute were range-checked and seconds were not, so
    /// `09:30:abc` was read as half past nine and `09:30:3600` as half past
    /// ten — silently discarding or reinterpreting the very thing this parsing
    /// exists to catch.
    func testAnUnreadableSecondsFieldIsRefused() async throws {
        let store = try await store([
            steps("a", "2026-08-17T15:00:00.000Z", 10)
        ])

        for bad in ["2026-08-17T09:30:abc", "2026-08-17T09:30:99",
                    "2026-08-17T09:30:3600", "2026-08-17T25:00:00"] {
            let reply = try await call(store, "aggregate_health_data", [
                "type": "HKQuantityTypeIdentifierStepCount",
                "from": bad
            ])
            XCTAssertNotNil(
                failure(reply),
                "\"\(bad)\" was accepted rather than refused"
            )
        }
    }

    /// A local wall clock that is well formed still works.
    func testAWellFormedLocalTimestampIsAccepted() async throws {
        let store = try await store([
            // 08:00 and 18:00 local on 17 August.
            steps("morning", "2026-08-17T12:00:00.000Z", 10),
            steps("evening", "2026-08-17T22:00:00.000Z", 20)
        ])

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKQuantityTypeIdentifierStepCount",
                "from": "2026-08-17T13:00:00"
            ])
        )
        XCTAssertTrue(body.contains("20"), body)
        XCTAssertFalse(body.contains(", 10,"), body)
    }

    /// `list_health_samples` inherits the same range handling.
    func testSampleListingHonoursABareDateRange() async throws {
        let store = try await store([
            steps("old", "2022-02-19T15:00:00.000Z", 111),
            steps("new", "2026-08-17T15:00:00.000Z", 222)
        ])

        let body = try text(
            await call(store, "list_health_samples", [
                "type": "HKQuantityTypeIdentifierStepCount",
                "from": "2026-08-01"
            ])
        )
        XCTAssertTrue(body.contains("222"), body)
        XCTAssertFalse(body.contains("111"), body)
    }

    // MARK: - A workout is as long as it lasted

    /// A workout's value is its length, so a day of workouts totals.
    ///
    /// Classifying workouts as occurrences lost the total — the thing that
    /// answers "how long do I work out" — and, because a workout sample
    /// carries the unit `sec`, printed the *count* of workouts labelled as
    /// seconds.
    func testWorkoutsTotalTheirDurationRatherThanCounting() async throws {
        let store = try await store([
            workout("w1", try local(2026, 8, 17, 7), seconds: 1800),
            workout("w2", try local(2026, 8, 17, 18), seconds: 2700)
        ])

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKWorkoutTypeIdentifier",
                "bucket": "day"
            ])
        )

        XCTAssertTrue(body.contains("sum"), "a day of workouts has a length")
        XCTAssertTrue(
            body.contains("4500"),
            "1800 + 2700 seconds, added by hand:\n\(body)"
        )
        XCTAssertFalse(
            body.contains("enumeration cases"),
            "a workout's value is a duration, not an enumeration:\n\(body)"
        )
    }

    private func workout(
        _ id: String,
        _ start: Date,
        seconds: Double
    ) -> [String: Any] {
        [
            "kind": "workout", "id": id,
            "type": "HKWorkoutTypeIdentifier",
            "startDate": Timestamps.text(from: start),
            "endDate": Timestamps.text(
                from: start.addingTimeInterval(seconds)
            ),
            "duration": seconds,
            "activityType": 52
        ]
    }

    // MARK: - A stand hour is an hour stood

    /// Stand hours report hours stood, and never the sum of the stored values.
    ///
    /// `HKCategoryValueAppleStandHour` is 0 for stood and 1 for idle, so a day
    /// where somebody stood in fourteen of twenty-four hours summed to 10 — and
    /// an assistant reading "sum: 10" says "you stood for ten hours", which is
    /// the exact opposite of what happened.
    func testStandHoursReportHoursStoodNotTheSumOfTheirValues() async throws {
        var samples: [[String: Any]] = []
        // Fourteen stood, ten idle, counted by hand.
        for hour in 0..<24 {
            samples.append(
                standHour(
                    "h\(hour)",
                    try local(2026, 8, 17, hour),
                    stood: hour < 14
                )
            )
        }
        let store = try await store(samples)

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKCategoryTypeIdentifierAppleStandHour",
                "bucket": "day"
            ])
        )

        XCTAssertTrue(
            body.contains("2026-08-17, 14, 24"),
            "expected fourteen hours stood out of twenty-four samples:\n\(body)"
        )
        XCTAssertFalse(
            body.contains("sum"),
            "there is no meaningful sum of enumeration cases:\n\(body)"
        )
        XCTAssertFalse(body.contains("average"), body)
        XCTAssertTrue(
            body.lowercased().contains("stood"),
            "the reply must say what the number counts:\n\(body)"
        )
    }

    /// A day recorded with no standing in it is nought, not missing.
    func testADayOfOnlyIdleHoursReportsZeroStoodRatherThanNothing() async throws {
        var samples: [[String: Any]] = []
        for hour in 0..<24 {
            samples.append(
                standHour("h\(hour)", try local(2026, 8, 17, hour), stood: false)
            )
        }
        let store = try await store(samples)

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKCategoryTypeIdentifierAppleStandHour",
                "bucket": "day"
            ])
        )

        XCTAssertTrue(
            body.contains("2026-08-17, 0, 24"),
            "a fully recorded, entirely seated day is zero stood:\n\(body)"
        )
    }

    /// Sleep is reported as minutes asleep, and time awake is not sleep.
    func testSleepIsReportedAsMinutesAsleep() async throws {
        let store = try await store([
            // Two hours of core sleep.
            [
                "kind": "category", "id": "core",
                "type": "HKCategoryTypeIdentifierSleepAnalysis",
                "startDate": Timestamps.text(from: try local(2026, 8, 17, 1)),
                "endDate": Timestamps.text(from: try local(2026, 8, 17, 3)),
                "value": 3
            ],
            // An hour awake, which is not sleep.
            [
                "kind": "category", "id": "awake",
                "type": "HKCategoryTypeIdentifierSleepAnalysis",
                "startDate": Timestamps.text(from: try local(2026, 8, 17, 3)),
                "endDate": Timestamps.text(from: try local(2026, 8, 17, 4)),
                "value": 2
            ]
        ])

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKCategoryTypeIdentifierSleepAnalysis",
                "bucket": "day"
            ])
        )

        XCTAssertTrue(body.contains("minutes"), body)
        XCTAssertTrue(
            body.contains("2026-08-17, 120, 2"),
            "two hours asleep out of two samples:\n\(body)"
        )
        XCTAssertFalse(body.contains("average"), body)
    }

    // MARK: - One night counted once

    /// Two devices describing one night report that night once.
    ///
    /// A watch and a phone each write a record for the same stretch. Adding
    /// their durations reports sixteen hours of sleep, which reads as an
    /// unusually good night rather than as an error — the worst way for a
    /// number to be wrong.
    func testANightRecordedTwiceIsNotCountedTwice() async throws {
        let store = try await store([
            sleep("watch", from: try local(2026, 8, 17, 23), hours: 8, value: 3),
            sleep("phone", from: try local(2026, 8, 17, 23), hours: 8, value: 1)
        ])

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKCategoryTypeIdentifierSleepAnalysis",
                "bucket": "day"
            ])
        )

        XCTAssertTrue(
            body.contains("2026-08-17, 480, 2"),
            "eight hours from two records of the same night:\n\(body)"
        )
        XCTAssertFalse(body.contains("960"), "that would be counting it twice")
        XCTAssertTrue(
            body.contains("merged rather than added"),
            "the reply should say how overlaps are handled:\n\(body)"
        )
    }

    /// Partly overlapping records cover the union, not the sum and not one.
    func testPartlyOverlappingRecordsCoverTheirUnion() async throws {
        let store = try await store([
            // 23:00–03:00 and 01:00–07:00 overlap by two hours.
            sleep("a", from: try local(2026, 8, 17, 23), hours: 4, value: 3),
            sleep("b", from: try local(2026, 8, 18, 1), hours: 6, value: 4)
        ])

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKCategoryTypeIdentifierSleepAnalysis",
                "bucket": "day"
            ])
        )

        // 23:00 to 07:00 is eight hours. The second record starts after
        // midnight, so it belongs to the 18th — the same attribution the
        // Markdown export uses — and each day's own union is taken.
        XCTAssertTrue(body.contains("2026-08-17, 240"), body)
        XCTAssertTrue(body.contains("2026-08-18, 360"), body)
    }

    /// Records that do not overlap still add up.
    func testSeparateStretchesStillAdd() async throws {
        let store = try await store([
            sleep("first", from: try local(2026, 8, 17, 1), hours: 2, value: 3),
            sleep("nap", from: try local(2026, 8, 17, 14), hours: 1, value: 3)
        ])

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKCategoryTypeIdentifierSleepAnalysis",
                "bucket": "day"
            ])
        )
        XCTAssertTrue(
            body.contains("2026-08-17, 180, 2"),
            "two hours and one hour, apart, is three:\n\(body)"
        )
    }

    /// Touching stretches are one stretch, not two with a gap.
    func testTouchingStretchesAreOneStretch() async throws {
        let store = try await store([
            sleep("core", from: try local(2026, 8, 17, 1), hours: 2, value: 3),
            sleep("rem", from: try local(2026, 8, 17, 3), hours: 1, value: 5)
        ])

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKCategoryTypeIdentifierSleepAnalysis",
                "bucket": "day"
            ])
        )
        XCTAssertTrue(body.contains("2026-08-17, 180, 2"), body)
    }

    /// Awake time inside a night is still not sleep, even when it overlaps.
    func testAwakeStretchesAreNotUnionedIntoSleep() async throws {
        let store = try await store([
            sleep("asleep", from: try local(2026, 8, 17, 1), hours: 4, value: 3),
            // An hour awake in the middle of it.
            sleep("awake", from: try local(2026, 8, 17, 2), hours: 1, value: 2)
        ])

        let body = try text(
            await call(store, "aggregate_health_data", [
                "type": "HKCategoryTypeIdentifierSleepAnalysis",
                "bucket": "day"
            ])
        )
        XCTAssertTrue(
            body.contains("2026-08-17, 240, 2"),
            "four hours staged asleep; the awake record adds nothing:\n\(body)"
        )
    }

    private func sleep(
        _ id: String,
        from start: Date,
        hours: Double,
        value: Int
    ) -> [String: Any] {
        [
            "kind": "category", "id": id,
            "type": "HKCategoryTypeIdentifierSleepAnalysis",
            "startDate": Timestamps.text(from: start),
            "endDate": Timestamps.text(
                from: start.addingTimeInterval(hours * 3600)
            ),
            "value": value
        ]
    }

    // MARK: - The classification the tools share

    /// Types the hand-kept list had drifted past are totalled, not averaged.
    ///
    /// `HealthMeasure` knew dietary protein accumulates; the private list
    /// beside it did not, so a day's protein was reported as the mean of each
    /// thing eaten.
    func testACumulativeTypeAbsentFromTheOldListIsTotalled() async throws {
        // Twenty days, because the trend tool refuses to fit a line through
        // fewer than fourteen and is right to.
        var samples: [[String: Any]] = []
        for day in 1...20 {
            for (index, grams) in [20.0, 40.0].enumerated() {
                samples.append([
                    "kind": "quantity", "id": "p\(day)-\(index)",
                    "type": "HKQuantityTypeIdentifierDietaryProtein",
                    "startDate": Timestamps.text(
                        from: try local(2026, 8, day, 8 + index * 5)
                    ),
                    "endDate": Timestamps.text(
                        from: try local(2026, 8, day, 8 + index * 5)
                    ),
                    "quantity": ["unit": "g", "value": grams]
                ])
            }
        }
        let store = try await store(samples)

        let body = try text(
            await call(store, "analyse_health_trend", [
                "type": "HKQuantityTypeIdentifierDietaryProtein",
                "days": 400
            ])
        )

        XCTAssertTrue(
            body.contains("daily total"),
            "protein accumulates through a day:\n\(body)"
        )
        XCTAssertFalse(body.contains("daily average"), body)
    }

    /// And a measured type is still an average.
    func testAMeasuredTypeIsStillReportedAsAnAverage() async throws {
        var samples: [[String: Any]] = []
        for day in 1...20 {
            samples.append([
                "kind": "quantity", "id": "h\(day)",
                "type": "HKQuantityTypeIdentifierRestingHeartRate",
                "startDate": Timestamps.text(from: try local(2026, 8, day, 8)),
                "endDate": Timestamps.text(from: try local(2026, 8, day, 8)),
                "quantity": ["unit": "count/min", "value": 58.0 + Double(day % 4)]
            ])
        }
        let store = try await store(samples)

        let body = try text(
            await call(store, "analyse_health_trend", [
                "type": "HKQuantityTypeIdentifierRestingHeartRate",
                "days": 400
            ])
        )
        XCTAssertTrue(body.contains("daily average"), body)
        XCTAssertFalse(body.contains("daily total"), body)
    }
}
