import Foundation
import HozzMCP
@testable import HozzReceive
import XCTest

/// Health computes aggregates on the workout sample it already hands over —
/// average, minimum and maximum heart rate, energy, distance — and they were
/// arriving at the Mac and sitting unread in `raw`. A workout rendered as an
/// empty row, so "what was my average heart rate on that run?" could not be
/// answered at all.
final class WorkoutDetailTests: XCTestCase {
    private var root: URL!
    private let workoutType = "HKWorkoutTypeIdentifier"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "workout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func run(at date: Date) -> [String: Any] {
        [
            "kind": "workout", "id": "w-1", "type": workoutType,
            "startDate": ISO8601DateFormatter().string(from: date),
            "endDate": ISO8601DateFormatter().string(from: date.addingTimeInterval(2_700)),
            "activityType": 37, "duration": 2_700.0, "events": [],
            "statistics": [
                [
                    "type": "HKQuantityTypeIdentifierHeartRate",
                    "unit": "count/min",
                    "average": 152.4, "minimum": 98.0, "maximum": 178.0
                ],
                [
                    "type": "HKQuantityTypeIdentifierActiveEnergyBurned",
                    "unit": "kcal", "sum": 412.0
                ]
            ],
            "source": ["name": "Apple Watch"]
        ]
    }

    private func triathlon(at date: Date) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        func leg(_ id: String, _ type: Int, _ offset: Double, average: Double) -> [String: Any] {
            [
                "id": id, "activityType": type,
                "startDate": iso.string(from: date.addingTimeInterval(offset)),
                "statistics": [
                    [
                        "type": "HKQuantityTypeIdentifierHeartRate",
                        "unit": "count/min", "average": average
                    ]
                ]
            ]
        }
        return [
            "kind": "workout", "id": "w-2", "type": workoutType,
            "startDate": iso.string(from: date),
            "endDate": iso.string(from: date.addingTimeInterval(7_200)),
            "activityType": 82, "duration": 7_200.0, "events": [],
            "statistics": [
                [
                    "type": "HKQuantityTypeIdentifierHeartRate",
                    "unit": "count/min", "average": 141.0
                ]
            ],
            "activities": [
                leg("leg-1", 46, 0, average: 128),
                leg("leg-2", 13, 1_800, average: 145),
                leg("leg-3", 37, 4_500, average: 162)
            ],
            "source": ["name": "Apple Watch"]
        ]
    }

    private func store(_ objects: [[String: Any]]) async throws -> IngestStore {
        let store = try IngestStore(directory: root.appending(path: "store"))
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
        _ arguments: [String: Any] = [:]
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

    /// The question someone actually asks, which previously had no answer.
    func testAWorkoutReportsWhatHealthComputedAboutIt() async throws {
        let store = try await store([run(at: Date.now.addingTimeInterval(-86_400))])
        let text = try await call(store, "list_workouts")

        XCTAssertTrue(text.contains("Running"), text)
        XCTAssertTrue(
            text.contains("average 152.40"),
            "The average heart rate is the question: \(text)"
        )
        XCTAssertTrue(text.contains("min 98"), text)
        XCTAssertTrue(text.contains("max 178"), text)
        XCTAssertTrue(text.contains("total 412 kcal"), text)
    }

    /// A triathlon is one workout and three efforts, and the overall average
    /// of 141 describes none of the legs.
    func testEachLegOfAMultiSportWorkoutKeepsItsOwnFigures() async throws {
        let store = try await store([triathlon(at: Date.now.addingTimeInterval(-86_400))])
        let text = try await call(store, "list_workouts")

        XCTAssertTrue(text.contains("Leg 1: Swimming"), text)
        XCTAssertTrue(text.contains("Leg 2: Cycling"), text)
        XCTAssertTrue(text.contains("Leg 3: Running"), text)
        XCTAssertTrue(text.contains("average 128"), text)
        XCTAssertTrue(text.contains("average 162"), text)

        let workouts = try await store.workouts()
        XCTAssertEqual(workouts.first?.activities.count, 3)
        XCTAssertEqual(
            workouts.first?.activities.map(\.activityType),
            [46, 13, 37],
            "The legs stay in the order they were performed."
        )
    }

    /// A workout keeps its sample row so it still appears in type lists and
    /// counts, and its own number is how long it lasted.
    func testAWorkoutStaysAChartableSampleWithItsDurationAsTheValue() async throws {
        let store = try await store([run(at: Date.now.addingTimeInterval(-86_400))])

        let samples = try await store.samples(type: workoutType, limit: 5)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.value, 2_700)
        XCTAssertEqual(samples.first?.unit, "sec")

        // And it is still counted as a type, which dropping the row would have
        // silently prevented.
        let types = try await call(store, "list_health_types")
        XCTAssertTrue(types.contains(workoutType), types)
    }

    /// Health does not compute every figure for every quantity, and a zero
    /// average heart rate would read as a measurement.
    func testAFigureHealthDidNotComputeIsOmittedRatherThanZeroed() async throws {
        var workout = run(at: Date.now.addingTimeInterval(-86_400))
        workout["statistics"] = [
            [
                "type": "HKQuantityTypeIdentifierActiveEnergyBurned",
                "unit": "kcal", "sum": 412.0
            ]
        ]
        let store = try await store([workout])
        let text = try await call(store, "list_workouts")

        XCTAssertTrue(text.contains("total 412"), text)
        XCTAssertFalse(
            text.contains("average 0"),
            "An uncomputed average must not appear as zero: \(text)"
        )
        XCTAssertFalse(text.contains("min 0"), text)
    }

    /// A workout Health recorded no statistics for is different from one Hozz
    /// failed to read.
    func testAWorkoutWithNoStatisticsSaysSo() async throws {
        var workout = run(at: Date.now.addingTimeInterval(-86_400))
        workout["statistics"] = []
        workout["activities"] = [
            [
                "id": "leg-1", "activityType": 37,
                "startDate": ISO8601DateFormatter().string(
                    from: Date.now.addingTimeInterval(-86_400)
                ),
                "statistics": []
            ]
        ]
        let store = try await store([workout])
        let text = try await call(store, "list_workouts")

        XCTAssertTrue(text.contains("recorded no statistics"), text)
    }

    /// Delivering the same workout twice must not double its statistics.
    func testARedeliveredWorkoutDoesNotDuplicateItsStatistics() async throws {
        let date = Date.now.addingTimeInterval(-86_400)
        let store = try await store([run(at: date)])
        _ = try await store.ingest(
            try BatchParser.parse(
                {
                    var data = try! JSONSerialization.data(
                        withJSONObject: run(at: date),
                        options: [.sortedKeys]
                    )
                    data.append(0x0A)
                    return data
                }()
            ),
            idempotencyKey: "second"
        )

        let workouts = try await store.workouts()
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(
            workouts.first?.statistics.count,
            2,
            "A replayed workout overwrites its statistics rather than appending."
        )
    }

    func testNoWorkoutsSaysItMayNotHaveSyncedYet() async throws {
        let store = try IngestStore(directory: root.appending(path: "store"))
        let text = try await call(store, "list_workouts")
        XCTAssertTrue(text.contains("not have arrived yet"), text)
    }
}
