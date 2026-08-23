import Foundation
@testable import HozzMCP
import HozzReceive
import XCTest

/// The analysis tools feed a language model, which will narrate a confident
/// story around any number handed to it. So these tests are mostly about what
/// the tools *refuse* to say: a slope through nine days, a correlation between
/// two unrelated series, and a day the watch was off reported as a collapsed
/// reading are all worse than no answer, because someone might act on them.
final class HealthAnalysisTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "analysis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let restingHeartRate = "HKQuantityTypeIdentifierRestingHeartRate"
    private let steps = "HKQuantityTypeIdentifierStepCount"
    private let day: TimeInterval = 86_400

    // MARK: - Fixtures

    private func record(
        _ id: String,
        _ type: String,
        _ date: Date,
        _ value: Double,
        _ unit: String
    ) -> [String: Any] {
        [
            "kind": "quantity", "id": id, "type": type,
            "startDate": ISO8601DateFormatter().string(from: date),
            "endDate": ISO8601DateFormatter().string(from: date),
            "quantity": ["unit": unit, "value": value],
            "source": ["name": "Apple Watch"]
        ]
    }

    private func store(_ objects: [[String: Any]]) async throws -> IngestStore {
        let store = try IngestStore(directory: root.appending(path: "store"))
        guard !objects.isEmpty else {
            return store
        }
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
    ) async throws -> String {
        let server = MCPServer(store: store)
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ]
        let payload = try JSONSerialization.data(withJSONObject: message)
        let response = await server.handle(payload)
        let reply = try XCTUnwrap(response)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        )
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    /// Repeatable pseudo-noise, so a failure is always reproducible.
    private struct Noise {
        private var seed = 42.0
        mutating func next() -> Double {
            seed = (seed * 7.7 + 3.1).truncatingRemainder(dividingBy: 10)
            return seed - 5
        }
    }

    // MARK: - Trend

    func testARealTrendIsReportedWithItsUncertainty() async throws {
        var noise = Noise()
        var objects: [[String: Any]] = []
        let base = Date.now.addingTimeInterval(-day)
        for index in 0..<120 {
            let date = base.addingTimeInterval(-Double(119 - index) * day)
            for reading in 0..<6 {
                objects.append(
                    record(
                        "hr-\(index)-\(reading)",
                        restingHeartRate,
                        date.addingTimeInterval(Double(reading) * 3_600),
                        52 + Double(index) * 0.03 + noise.next() * 0.4,
                        "count/min"
                    )
                )
            }
        }

        let text = try await call(
            try await store(objects),
            "analyse_health_trend",
            ["type": restingHeartRate, "days": 200]
        )

        XCTAssertTrue(text.contains("Rising"), text)
        XCTAssertTrue(
            text.contains("95% interval"),
            "A slope without its uncertainty invites overstatement: \(text)"
        )
        XCTAssertTrue(text.contains("120 days with data"), text)
    }

    /// The important one. A flat series still produces a non-zero slope, and a
    /// naive tool would hand over "-26 steps per week" for a model to call a
    /// decline.
    func testAFlatSeriesIsReportedAsNoDetectableChange() async throws {
        var noise = Noise()
        var objects: [[String: Any]] = []
        let base = Date.now.addingTimeInterval(-day)
        for index in 0..<120 {
            let date = base.addingTimeInterval(-Double(119 - index) * day)
            for reading in 0..<4 {
                objects.append(
                    record(
                        "st-\(index)-\(reading)",
                        steps,
                        date.addingTimeInterval(Double(reading) * 3_600),
                        2_000 + noise.next() * 120,
                        "count"
                    )
                )
            }
        }

        let text = try await call(
            try await store(objects),
            "analyse_health_trend",
            ["type": steps, "days": 200]
        )

        XCTAssertTrue(text.contains("No detectable change"), text)
        XCTAssertTrue(text.contains("spans zero"), text)
        XCTAssertTrue(
            text.contains("Do not describe this as rising or falling"),
            "The output has to forbid the claim, not merely omit it: \(text)"
        )
    }

    func testTooFewDaysRefusesToReportADirection() async throws {
        var objects: [[String: Any]] = []
        let base = Date.now.addingTimeInterval(-day)
        for index in 0..<8 {
            objects.append(
                record(
                    "hr-\(index)",
                    restingHeartRate,
                    base.addingTimeInterval(-Double(index) * day),
                    50 + Double(index),
                    "count/min"
                )
            )
        }

        let text = try await call(
            try await store(objects),
            "analyse_health_trend",
            ["type": restingHeartRate, "days": 30]
        )

        XCTAssertTrue(text.contains("at least 14 days"), text)
        XCTAssertTrue(text.contains("No direction should be reported"), text)
        XCTAssertFalse(text.contains("Rising"), text)
    }

    // MARK: - Correlation

    func testTwoUnrelatedTypesAreNotReportedAsRelated() async throws {
        var noise = Noise()
        var objects: [[String: Any]] = []
        let base = Date.now.addingTimeInterval(-day)
        for index in 0..<120 {
            let date = base.addingTimeInterval(-Double(119 - index) * day)
            objects.append(
                record(
                    "hr-\(index)",
                    restingHeartRate,
                    date,
                    54 + noise.next() * 0.5,
                    "count/min"
                )
            )
            objects.append(
                record("st-\(index)", steps, date, 2_000 + noise.next() * 150, "count")
            )
        }

        let text = try await call(
            try await store(objects),
            "compare_health_types",
            ["first": restingHeartRate, "second": steps, "days": 200]
        )

        XCTAssertTrue(text.contains("No detectable relationship"), text)
        XCTAssertTrue(text.contains("includes zero"), text)
        XCTAssertTrue(text.contains("Do not describe these as related"), text)
    }

    func testTooFewSharedDaysRefusesToCorrelate() async throws {
        var objects: [[String: Any]] = []
        let base = Date.now.addingTimeInterval(-day)
        for index in 0..<10 {
            let date = base.addingTimeInterval(-Double(index) * day)
            objects.append(
                record("hr-\(index)", restingHeartRate, date, 54, "count/min")
            )
            objects.append(record("st-\(index)", steps, date, 2_000, "count"))
        }

        let text = try await call(
            try await store(objects),
            "compare_health_types",
            ["first": restingHeartRate, "second": steps, "days": 60]
        )

        XCTAssertTrue(text.contains("at least 28 shared days"), text)
        XCTAssertTrue(
            text.contains("no relationship should be reported either way"),
            text
        )
    }

    /// The backfill sends one type at a time, so a missing type usually means
    /// "not synced yet". Answering zero, or erroring, would both be wrong.
    func testAnUnsyncedTypeSaysSoRatherThanReportingNothing() async throws {
        var objects: [[String: Any]] = []
        let base = Date.now.addingTimeInterval(-day)
        for index in 0..<40 {
            objects.append(
                record(
                    "hr-\(index)",
                    restingHeartRate,
                    base.addingTimeInterval(-Double(index) * day),
                    54,
                    "count/min"
                )
            )
        }

        let text = try await call(
            try await store(objects),
            "compare_health_types",
            ["first": restingHeartRate, "second": steps, "days": 200]
        )

        XCTAssertTrue(text.contains("has reached this Mac yet"), text)
        XCTAssertTrue(
            text.contains("not evidence that you have no such data"),
            "Absent because unsynced is not absent because none exists: \(text)"
        )
        XCTAssertTrue(text.contains(restingHeartRate), "It lists what has arrived.")
    }

    // MARK: - Anomalies

    /// A genuine spike must be found, and a day the watch was off must not be
    /// reported as a collapsed reading. They look identical to any detector
    /// that ignores how much was recorded.
    func testAWearGapIsNotReportedAsAnUnusualReading() async throws {
        var noise = Noise()
        var objects: [[String: Any]] = []
        let base = Date.now.addingTimeInterval(-day)

        for index in 0..<120 {
            let date = base.addingTimeInterval(-Double(119 - index) * day)
            // Day 99 is a wear gap: the watch was off, leaving one stray
            // reading far below the usual value.
            guard index != 99 else {
                objects.append(
                    record("hr-gap", restingHeartRate, date, 31, "count/min")
                )
                continue
            }
            for reading in 0..<6 {
                objects.append(
                    record(
                        "hr-\(index)-\(reading)",
                        restingHeartRate,
                        date.addingTimeInterval(Double(reading) * 3_600),
                        54 + noise.next() * 0.4,
                        "count/min"
                    )
                )
            }
        }
        // A real, well-measured spike.
        let spikeDate = base.addingTimeInterval(-40 * day)
        for reading in 0..<6 {
            objects.append(
                record(
                    "hr-spike-\(reading)",
                    restingHeartRate,
                    spikeDate.addingTimeInterval(Double(reading) * 3_600),
                    95,
                    "count/min"
                )
            )
        }

        let text = try await call(
            try await store(objects),
            "find_health_anomalies",
            ["type": restingHeartRate, "days": 200]
        )

        XCTAssertTrue(text.contains("Unusual days:"), text)
        XCTAssertTrue(
            text.contains("above usual"),
            "The genuine spike has to be found: \(text)"
        )
        XCTAssertFalse(
            text.contains("31") && text.contains("below usual"),
            "A day the watch was off must never be reported as a low reading: \(text)"
        )
        XCTAssertTrue(
            text.contains("not worn"),
            "The wear gap is reported as itself: \(text)"
        )
        XCTAssertTrue(
            text.contains("must not be reported as unusual values"),
            text
        )
    }

    func testNoBaselineRefusesToJudgeADayAsUnusual() async throws {
        var objects: [[String: Any]] = []
        let base = Date.now.addingTimeInterval(-day)
        for index in 0..<6 {
            objects.append(
                record(
                    "hr-\(index)",
                    restingHeartRate,
                    base.addingTimeInterval(-Double(index) * day),
                    54,
                    "count/min"
                )
            )
        }

        let text = try await call(
            try await store(objects),
            "find_health_anomalies",
            ["type": restingHeartRate, "days": 30]
        )

        XCTAssertTrue(text.contains("at least 14 days"), text)
        XCTAssertTrue(text.contains("what usual is"), text)
    }

    // MARK: - The statistics themselves

    /// Consecutive days resemble each other, so treating each as independent
    /// evidence is what turns three weeks of data into a false certainty.
    func testAutocorrelatedSeriesAreWorthFewerIndependentDays() {
        // A slow drift: each day very like the last.
        let smooth = (0..<100).map { Double($0) * 0.1 }
        // Alternating: no self-similarity at lag one.
        let jagged = (0..<100).map { $0.isMultiple(of: 2) ? 1.0 : -1.0 }

        let smoothEffective = HealthStatistics.effectiveSampleSize(smooth, smooth)
        let jaggedEffective = HealthStatistics.effectiveSampleSize(jagged, jagged)

        XCTAssertLessThan(
            smoothEffective,
            20,
            "A hundred nearly identical days are not a hundred observations."
        )
        XCTAssertGreaterThan(jaggedEffective, smoothEffective)
    }

    /// The median absolute deviation is used precisely so one extreme day
    /// cannot inflate the spread and hide the days beside it.
    func testOneExtremeDayDoesNotMaskTheOthers() throws {
        var values = (0..<30).map {
            HealthStatistics.DailyValue(
                day: Double($0),
                value: 50 + Double($0 % 3),
                recordCount: 6
            )
        }
        values[10] = HealthStatistics.DailyValue(day: 10, value: 500, recordCount: 6)
        values[20] = HealthStatistics.DailyValue(day: 20, value: 70, recordCount: 6)

        let report = try XCTUnwrap(HealthStatistics.anomalies(values))
        let flagged = Set(report.outliers.map(\.day))

        XCTAssertTrue(flagged.contains(10))
        XCTAssertTrue(
            flagged.contains(20),
            "A standard deviation inflated by day 10 would have hidden day 20."
        )
    }
}
