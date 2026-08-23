import Foundation
import HealthKit
import HozzAcquire
import HozzCatalog
import HozzCore
import HozzHealthFake
import HozzStore
import XCTest
@testable import HozzHealth

/// A workout used to export as an activity type and a duration: you could tell
/// that a run happened and nothing about how it went. Health carries its own
/// aggregates on the sample, so the detail costs no extra query — these tests
/// are about not losing or inventing any of it.
final class WorkoutStatisticsTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let workoutType = HealthTypeKey("HKWorkoutTypeIdentifier")

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private var heartRate: WorkoutStatistic {
        WorkoutStatistic(
            type: "HKQuantityTypeIdentifierHeartRate",
            unit: "count/min",
            sum: nil,
            average: 148.2,
            minimum: 96,
            maximum: 176
        )
    }

    private var energy: WorkoutStatistic {
        WorkoutStatistic(
            type: "HKQuantityTypeIdentifierActiveEnergyBurned",
            unit: "kcal",
            sum: 612.5,
            average: nil,
            minimum: nil,
            maximum: nil
        )
    }

    private var distance: WorkoutStatistic {
        WorkoutStatistic(
            type: "HKQuantityTypeIdentifierDistanceWalkingRunning",
            unit: "m",
            sum: 10_240,
            average: nil,
            minimum: nil,
            maximum: nil
        )
    }

    private func workoutObject(
        statistics: [WorkoutStatistic],
        segments: [WorkoutSegment] = []
    ) -> [String: Any] {
        var object: [String: Any] = [
            "kind": "workout",
            "schemaVersion": 1,
            "id": UUID().uuidString.lowercased(),
            "type": "HKWorkoutTypeIdentifier",
            "startDate": "2023-11-14T22:13:20.000Z",
            "endDate": "2023-11-14T23:13:20.000Z",
            "activityType": 37,
            "duration": 3_600.0,
            "events": [],
            "source": ["name": "Watch", "bundleIdentifier": "com.apple.health"]
        ]
        WorkoutEncoding.decorate(
            &object,
            statistics: statistics,
            segments: segments
        )
        return object
    }

    // MARK: - What Health offers, and only that

    func testAnAggregateHealthDoesNotOfferIsLeftOutRatherThanZeroed() throws {
        let object = workoutObject(statistics: [heartRate, energy])
        let statistics = try XCTUnwrap(object["statistics"] as? [[String: Any]])

        let heart = try XCTUnwrap(
            statistics.first { $0["type"] as? String == heartRate.type }
        )
        XCTAssertEqual(heart["average"] as? Double, 148.2)
        XCTAssertEqual(heart["minimum"] as? Double, 96)
        XCTAssertEqual(heart["maximum"] as? Double, 176)
        XCTAssertNil(
            heart["sum"],
            "Heart rate has no meaningful total, and zero would claim one."
        )

        let burned = try XCTUnwrap(
            statistics.first { $0["type"] as? String == energy.type }
        )
        XCTAssertEqual(burned["sum"] as? Double, 612.5)
        XCTAssertNil(
            burned["average"],
            "A cumulative type has no average to report."
        )
    }

    func testStatisticsCarryTheUnitTheSamplesUse() throws {
        let object = workoutObject(statistics: [heartRate, distance])
        let statistics = try XCTUnwrap(object["statistics"] as? [[String: Any]])

        XCTAssertEqual(
            Set(statistics.compactMap { $0["unit"] as? String }),
            ["count/min", "m"],
            "A workout average must be comparable with the type's samples."
        )
    }

    func testStatisticsSortSoTheSameWorkoutEncodesTheSameWay() throws {
        let forwards = workoutObject(statistics: [heartRate, energy, distance])
        let backwards = workoutObject(statistics: [distance, energy, heartRate])

        let first = (forwards["statistics"] as? [[String: Any]])?
            .compactMap { $0["type"] as? String }
        let second = (backwards["statistics"] as? [[String: Any]])?
            .compactMap { $0["type"] as? String }

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, first?.sorted())
    }

    func testAWorkoutWithNoStatisticsSaysSoWithAnEmptyList() throws {
        let object = workoutObject(statistics: [])

        XCTAssertEqual((object["statistics"] as? [[String: Any]])?.count, 0)
        XCTAssertNil(
            object["activities"],
            "A single-effort workout has no segments, and an empty list would suggest it did."
        )
    }

    // MARK: - Segments

    func testEachLegOfAWorkoutKeepsItsOwnFigures() throws {
        let swim = WorkoutSegment(
            id: UUID(),
            activityType: 46,
            startDate: Date(timeIntervalSince1970: 0),
            endDate: Date(timeIntervalSince1970: 900),
            statistics: [
                WorkoutStatistic(
                    type: "HKQuantityTypeIdentifierDistanceSwimming",
                    unit: "m",
                    sum: 1_500,
                    average: nil,
                    minimum: nil,
                    maximum: nil
                )
            ]
        )
        let ride = WorkoutSegment(
            id: UUID(),
            activityType: 13,
            startDate: Date(timeIntervalSince1970: 900),
            endDate: nil,
            statistics: [distance]
        )

        let object = workoutObject(
            statistics: [heartRate],
            segments: [swim, ride]
        )
        let activities = try XCTUnwrap(object["activities"] as? [[String: Any]])

        XCTAssertEqual(activities.count, 2)
        XCTAssertEqual(
            activities[0]["activityType"] as? UInt,
            46,
            "HealthKit's activity type is unsigned, and it stays that way."
        )
        XCTAssertEqual(
            ((activities[0]["statistics"] as? [[String: Any]])?.first)?["sum"]
                as? Double,
            1_500,
            "An average across three legs of a triathlon describes none of them."
        )
        XCTAssertNil(
            activities[1]["endDate"],
            "An activity still running has no end, and inventing one would date it."
        )
    }

    // MARK: - Through an export

    func testCSVCarriesTheFiguresASpreadsheetIsOpenedFor() async throws {
        let store = try makeStore()
        let object = workoutObject(
            statistics: [heartRate, energy, distance],
            segments: []
        )
        let id = try XCTUnwrap(object["id"] as? String)
        let engine = HealthExportEngine(
            store: store,
            source: ScriptedHealthDataSource(
                streams: [
                    workoutType: [
                        .upsert(
                            CapturedHealthObject(
                                id: try XCTUnwrap(UUID(uuidString: id)),
                                type: workoutType,
                                canonicalPayload: try JSONSerialization.data(
                                    withJSONObject: object,
                                    options: [.sortedKeys]
                                )
                            )
                        )
                    ]
                ]
            ),
            types: [workoutType],
            lease: ExportWriterLease()
        )

        let outcome = try await engine.export(format: .csv) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }
        let entries = try ExportArtifactReader.readZipEntries(at: result.fileURL)
        let csv = try XCTUnwrap(entries["Workout.csv"])
        let rows = String(decoding: csv, as: UTF8.self).split(separator: "\n")

        XCTAssertTrue(
            rows[0].contains("activeEnergyKcal,averageHeartRate,distanceMetres")
        )
        let fields = rows[1].split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertTrue(fields.contains("612.5"))
        XCTAssertTrue(fields.contains("148.2"))
        XCTAssertTrue(fields.contains("10240"))
    }

    /// A run has no swimming distance, and a blank says so rather than zero.
    func testADistanceAWorkoutDidNotRecordStaysBlank() {
        let statistics = [heartRate.object, energy.object]

        XCTAssertEqual(ExportTranscoder.distance(statistics), "")
        XCTAssertEqual(
            ExportTranscoder.statistic(
                statistics,
                type: "HKQuantityTypeIdentifierHeartRate",
                field: "sum"
            ),
            "",
            "An aggregate Health does not offer must not become a zero in a grid."
        )
    }

    func testTheDistanceColumnFindsWhicheverSportWasRecorded() {
        let swimming = WorkoutStatistic(
            type: "HKQuantityTypeIdentifierDistanceSwimming",
            unit: "m",
            sum: 1_500,
            average: nil,
            minimum: nil,
            maximum: nil
        )

        XCTAssertEqual(
            ExportTranscoder.distance([swimming.object]),
            "1500"
        )
        XCTAssertEqual(
            ExportTranscoder.distance([distance.object]),
            "10240"
        )
    }
}
