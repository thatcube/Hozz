import Foundation
import HozzReceive
import HozzStore
import XCTest

/// Every record kind the phone can emit has to survive the trip to the Mac.
///
/// This suite exists because the same bug has now happened twice. Deletions
/// were counted as unreadable, answered 200, and never resent, so a sample the
/// user removed stayed on the receiver forever. Characteristics were then
/// added with a deliberately different shape — no id, no type, no start date,
/// because a blood type is not a measurement taken at export time — and the
/// parser rejected every one of them for exactly the same reason.
///
/// The lesson is that the failure is silent by construction: the phone gets a
/// 200, advances its cursor, and never sends the record again. So the audit is
/// written down here as a test rather than performed once by hand.
final class ReceiverKindAuditTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> IngestStore {
        try IngestStore(directory: directory.url.appending(path: "store"))
    }

    private func payload(_ objects: [[String: Any]]) throws -> Data {
        var data = Data()
        for object in objects {
            data.append(
                try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            )
            data.append(0x0A)
        }
        return data
    }

    // MARK: - The record shapes the phone actually writes

    private func sampleShaped(
        kind: String,
        type: String,
        id: String = UUID().uuidString.lowercased()
    ) -> [String: Any] {
        var object: [String: Any] = [
            "kind": kind,
            "schemaVersion": 1,
            "id": id,
            "type": type,
            "startDate": "2026-01-02T15:00:00.000Z",
            "endDate": "2026-01-02T15:01:00.000Z",
            "source": ["name": "Apple Watch", "bundleIdentifier": "com.apple.health"],
            "metadata": [:]
        ]
        switch kind {
        case "quantity":
            object["quantity"] = ["unit": "count", "value": 412, "description": "412 count"]
        case "category":
            object["value"] = 1
        case "workout":
            object["activityType"] = 37
            object["duration"] = 2_700.0
            object["events"] = []
        case "correlation":
            object["members"] = [["id": "m-1", "type": "HKQuantityTypeIdentifierHeartRate"]]
        case "workoutRoute":
            object["workout"] = ["id": "w-1"]
        case "workoutRouteLocations":
            object["route"] = "r-1"
            object["sequence"] = 0
            object["locations"] = [["latitude": 51.5, "longitude": -0.1]]
        case "workoutRouteEnd":
            object["route"] = "r-1"
            object["locations"] = 1
        default:
            break
        }
        return object
    }

    /// The combined shape from `HealthCharacteristicsRecord`: no id, no type,
    /// no start date, one record holding every characteristic keyed by type.
    private func characteristicsRecord() -> [String: Any] {
        [
            "kind": "characteristics",
            "schemaVersion": 1,
            "catalogVersion": "2026.08.1",
            "readAt": "2026-01-02T15:00:00.000Z",
            "characteristics": [
                "HKCharacteristicTypeIdentifierDateOfBirth": [
                    "state": "known",
                    "value": "1985-03-04"
                ],
                "HKCharacteristicTypeIdentifierBloodType": [
                    "state": "known",
                    "value": "APositive",
                    "rawValue": 2
                ],
                "HKCharacteristicTypeIdentifierBiologicalSex": [
                    "state": "notSet",
                    "coverage": "authorizationIndeterminate"
                ]
            ]
        ]
    }

    // MARK: - The audit

    /// The one test that would have caught both bugs.
    func testEveryKindThePhoneEmitsIsStoredRatherThanDropped() async throws {
        let sampleKinds = [
            ("quantity", "HKQuantityTypeIdentifierStepCount"),
            ("category", "HKCategoryTypeIdentifierSleepAnalysis"),
            ("sample", "HKQuantityTypeIdentifierBodyMass"),
            ("workout", "HKWorkoutTypeIdentifier"),
            ("correlation", "HKCorrelationTypeIdentifierBloodPressure"),
            ("workoutRoute", "HKWorkoutRouteTypeIdentifier"),
            ("workoutRouteLocations", "HKWorkoutRouteTypeIdentifier"),
            ("workoutRouteEnd", "HKWorkoutRouteTypeIdentifier")
        ]

        var objects = sampleKinds.map { sampleShaped(kind: $0.0, type: $0.1) }
        objects.append(characteristicsRecord())
        objects.append([
            "kind": "deletion",
            "schemaVersion": 1,
            "id": "gone-1",
            "type": "HKQuantityTypeIdentifierStepCount"
        ])

        let batch = try BatchParser.parse(try payload(objects))

        // Every sample-shaped kind parses as a record.
        XCTAssertEqual(
            Set(batch.records.compactMap(\.kind)),
            Set(sampleKinds.map(\.0)),
            """
            A kind missing here is being dropped on the way to the Mac. \
            Parsed: \(batch.records.compactMap(\.kind).sorted())
            """
        )
        XCTAssertEqual(batch.deletions.count, 1)
        XCTAssertEqual(
            batch.characteristics.count,
            3,
            "Characteristics carry no id or start date and need their own path."
        )
        XCTAssertTrue(
            batch.unhandled.isEmpty,
            """
            Nothing should be uninterpretable yet: \
            \(batch.unhandled.map(\.reason))
            """
        )
        XCTAssertEqual(batch.unreadableCount, 0)

        // And every one of them reaches disk.
        let store = try makeStore()
        let result = try await store.ingest(batch, idempotencyKey: "audit-1")
        XCTAssertEqual(result.stored, sampleKinds.count)
        XCTAssertEqual(result.characteristics, 3)
        XCTAssertEqual(result.unhandled, 0)

        let storedKinds = Set(try await store.summaries().map(\.type))
        for (_, type) in sampleKinds {
            XCTAssertTrue(
                storedKinds.contains(type),
                "\(type) never reached the database."
            )
        }
    }

    /// The specific regression: this exact record used to be dropped whole.
    func testACharacteristicsRecordSurvivesParseAndStorage() async throws {
        let batch = try BatchParser.parse(try payload([characteristicsRecord()]))
        XCTAssertEqual(batch.characteristics.count, 3)
        XCTAssertEqual(batch.unreadableCount, 0)
        XCTAssertFalse(
            batch.isEmpty,
            "A batch of only characteristics is not an empty batch."
        )

        let store = try makeStore()
        let result = try await store.ingest(batch, idempotencyKey: "chars-1")
        XCTAssertEqual(result.characteristics, 3)

        let stored = try await store.characteristics()
        XCTAssertEqual(stored.count, 3)

        let blood = try XCTUnwrap(
            stored.first { $0.type == "HKCharacteristicTypeIdentifierBloodType" }
        )
        XCTAssertEqual(blood.value, "APositive")
        XCTAssertEqual(blood.rawValue, 2)
        XCTAssertEqual(blood.state, "known")
        XCTAssertTrue(blood.isKnown)
        XCTAssertEqual(blood.displayName, "Blood Type")
        XCTAssertNotNil(blood.readAt)

        // "Not set" is a real answer about the person, not a failed read, and
        // has to stay distinguishable from "declined to share".
        let sex = try XCTUnwrap(
            stored.first { $0.type == "HKCharacteristicTypeIdentifierBiologicalSex" }
        )
        XCTAssertEqual(sex.state, "notSet")
        XCTAssertNil(sex.value)
        XCTAssertFalse(sex.isKnown)
    }

    /// A person has one blood type, not a time series of them.
    func testRedeliveringCharacteristicsUpdatesRatherThanDuplicates() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(try payload([characteristicsRecord()])),
            idempotencyKey: "chars-1"
        )

        var updated = characteristicsRecord()
        updated["readAt"] = "2026-06-01T09:00:00.000Z"
        updated["characteristics"] = [
            "HKCharacteristicTypeIdentifierDateOfBirth": [
                "state": "known",
                "value": "1985-03-04"
            ],
            "HKCharacteristicTypeIdentifierBloodType": [
                "state": "known",
                "value": "APositive",
                "rawValue": 2
            ],
            // The person has since filled this one in.
            "HKCharacteristicTypeIdentifierBiologicalSex": [
                "state": "known",
                "value": "Male",
                "rawValue": 2
            ]
        ]

        // A different idempotency key, because this is a genuinely new
        // delivery rather than a retry of the old one.
        _ = try await store.ingest(
            try BatchParser.parse(try payload([updated])),
            idempotencyKey: "chars-2"
        )

        let stored = try await store.characteristics()
        XCTAssertEqual(
            stored.count,
            3,
            "Re-delivery must replace the facts, not append a second set."
        )
        let sex = try XCTUnwrap(
            stored.first { $0.type == "HKCharacteristicTypeIdentifierBiologicalSex" }
        )
        XCTAssertEqual(sex.value, "Male")
        XCTAssertEqual(sex.state, "known")
    }

    // MARK: - Nothing is accepted without being stored

    /// A record shape this Mac has never seen, which is what the next Health
    /// type will look like before the receiver learns about it.
    func testAnUnknownKindIsStoredRatherThanDiscarded() async throws {
        let future: [String: Any] = [
            "kind": "electrocardiogram",
            "schemaVersion": 1,
            "averageHeartRate": 62,
            "classification": "sinusRhythm",
            "voltages": [0.1, 0.2, 0.3]
        ]

        let batch = try BatchParser.parse(try payload([future]))
        XCTAssertTrue(batch.records.isEmpty)
        XCTAssertEqual(batch.unhandled.count, 1)
        XCTAssertEqual(batch.unhandled.first?.kind, "electrocardiogram")

        let store = try makeStore()
        let result = try await store.ingest(batch, idempotencyKey: "future-1")
        XCTAssertEqual(
            result.unhandled,
            1,
            "An unrecognised record is kept, because the phone will never resend it."
        )

        let summary = try await store.unhandledSummary()
        XCTAssertEqual(summary.first?.kind, "electrocardiogram")
        XCTAssertEqual(summary.first?.count, 1)

        // Refusing the batch instead would wedge: the phone would resend the
        // same bytes forever and block every record behind them.
        let quarantined = try await store.unhandledCount()
        XCTAssertEqual(quarantined, 1)
    }

    func testAnUnknownRecordArrivingTwiceIsStoredOnce() async throws {
        let future: [String: Any] = [
            "kind": "audiogram",
            "schemaVersion": 1,
            "sensitivityPoints": [["frequency": 1_000, "left": 5, "right": 10]]
        ]
        let store = try makeStore()

        _ = try await store.ingest(
            try BatchParser.parse(try payload([future])),
            idempotencyKey: "audio-1"
        )
        _ = try await store.ingest(
            try BatchParser.parse(try payload([future])),
            idempotencyKey: "audio-2"
        )

        let quarantined = try await store.unhandledCount()
        XCTAssertEqual(
            quarantined,
            1,
            "The same record delivered twice is one row, keyed by its content."
        )
    }

    /// A line that is not JSON has nothing to interpret, but the phone has
    /// already moved past it, so the bytes are kept rather than dropped.
    func testALineThatIsNotJSONIsQuarantinedRatherThanLost() async throws {
        var data = try payload([
            sampleShaped(kind: "quantity", type: "HKQuantityTypeIdentifierStepCount")
        ])
        data.append(Data("{this is not json\n".utf8))

        let batch = try BatchParser.parse(data)
        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(batch.unreadableCount, 1)
        XCTAssertEqual(
            batch.unhandled.count,
            1,
            "Unreadable must mean 'not interpreted', never 'thrown away'."
        )

        let store = try makeStore()
        let result = try await store.ingest(batch, idempotencyKey: "mixed-1")
        XCTAssertEqual(result.stored, 1)
        XCTAssertEqual(result.unhandled, 1)
        XCTAssertEqual(result.unreadable, 1)
    }

    /// The invariant the whole design rests on: every object delivered is
    /// either interpreted or quarantined, and the counts add up to what
    /// arrived. Nothing is silently absent.
    func testEveryDeliveredRecordIsAccountedFor() async throws {
        var objects: [[String: Any]] = [
            sampleShaped(kind: "quantity", type: "HKQuantityTypeIdentifierStepCount"),
            sampleShaped(kind: "workout", type: "HKWorkoutTypeIdentifier"),
            characteristicsRecord(),
            ["kind": "deletion", "id": "gone-1", "type": "HKQuantityTypeIdentifierStepCount"],
            ["kind": "somethingNew", "payload": "unknown"]
        ]
        objects.append(sampleShaped(kind: "category", type: "HKCategoryTypeIdentifierSleepAnalysis"))

        let batch = try BatchParser.parse(try payload(objects))
        let store = try makeStore()
        let result = try await store.ingest(batch, idempotencyKey: "accounted-1")

        // Three samples, one deletion, one unknown, and one characteristics
        // record that fans out into three facts.
        let accountedObjects =
            result.stored
            + batch.deletions.count
            + result.unhandled
            + 1
        XCTAssertEqual(
            accountedObjects,
            objects.count,
            """
            \(objects.count) records were delivered but only \
            \(accountedObjects) can be accounted for.
            """
        )
        XCTAssertEqual(result.stored, 3)
        XCTAssertEqual(result.characteristics, 3)
        XCTAssertEqual(result.unhandled, 1)
    }

    // MARK: - Upgrading an existing receiver

    /// Every Mac already running Hozz has a version 2 database with real data
    /// in it. The upgrade has to add the new tables without disturbing that.
    func testAVersionTwoDatabaseGainsTheNewTablesWithoutLosingData() async throws {
        let storeDirectory = directory.url.appending(path: "store")

        // A receiver as it exists today: schema 2, with a sample already in it.
        do {
            let store = try makeStore()
            _ = try await store.ingest(
                try BatchParser.parse(
                    try payload([
                        sampleShaped(
                            kind: "quantity",
                            type: "HKQuantityTypeIdentifierStepCount",
                            id: "existing-1"
                        )
                    ])
                ),
                idempotencyKey: "before-upgrade"
            )
            await store.close()
        }

        let databaseURL = storeDirectory.appending(path: "hozz-received.sqlite")
        let database = try SQLiteDatabase(url: databaseURL)
        try database.execute("DROP TABLE IF EXISTS characteristic")
        try database.execute("DROP TABLE IF EXISTS unhandled_record")
        try database.execute("PRAGMA user_version = 2")
        database.close()

        // Reopening runs the migration.
        let upgraded = try IngestStore(directory: storeDirectory)
        _ = try await upgraded.ingest(
            try BatchParser.parse(try payload([characteristicsRecord()])),
            idempotencyKey: "after-upgrade"
        )

        let migratedCharacteristics = try await upgraded.characteristics().count
        XCTAssertEqual(
            migratedCharacteristics,
            3,
            "The new table has to exist after upgrading, not only on a fresh install."
        )
        let survivingSamples = try await upgraded.totalRecordCount()
        XCTAssertEqual(
            survivingSamples,
            1,
            "The sample that was already there must survive the upgrade."
        )

        await upgraded.close()
        let reopened = try SQLiteDatabase(url: databaseURL)
        defer { reopened.close() }
        XCTAssertEqual(
            try reopened.query("PRAGMA user_version", row: { $0.integer(0) }).first,
            3
        )
    }
}
