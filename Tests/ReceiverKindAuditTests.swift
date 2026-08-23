import Foundation
@testable import HozzReceive
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

    /// ECG and hearing-test records, which the phone emits and which the
    /// receiver reads into their own tables rather than into `sample`.
    private func seriesRecords() -> [[String: Any]] {
        [
            [
                "kind": "electrocardiogram", "schemaVersion": 1, "id": "ecg-1",
                "type": "HKDataTypeIdentifierElectrocardiogram",
                "startDate": "2026-01-02T15:00:00.000Z",
                "endDate": "2026-01-02T15:00:30.000Z",
                "classification": ["name": "sinusRhythm", "rawValue": 1],
                "numberOfVoltageMeasurements": 1,
                "source": ["name": "Apple Watch"]
            ],
            [
                "kind": "electrocardiogramVoltages", "schemaVersion": 1,
                "id": "ecg-1-v-0",
                "type": "HKDataTypeIdentifierElectrocardiogram",
                "sample": "ecg-1", "sequence": 0, "offset": 0, "count": 1,
                "startDate": "2026-01-02T15:00:00.000Z",
                "endDate": "2026-01-02T15:00:00.002Z",
                "voltages": [["timeSinceStart": 0.0, "volts": 0.0001]]
            ],
            [
                "kind": "electrocardiogramEnd", "schemaVersion": 1,
                "id": "ecg-1-end",
                "type": "HKDataTypeIdentifierElectrocardiogram",
                "sample": "ecg-1", "voltages": 1,
                "startDate": "2026-01-02T15:00:00.000Z",
                "endDate": "2026-01-02T15:00:30.000Z"
            ],
            [
                "kind": "audiogram", "schemaVersion": 1, "id": "audio-1",
                "type": "HKDataTypeIdentifierAudiogram",
                "startDate": "2026-02-01T10:00:00.000Z",
                "endDate": "2026-02-01T10:05:00.000Z",
                "source": ["name": "Mimi"],
                "sensitivityPoints": [
                    [
                        "frequency": ["unit": "Hz", "value": 1_000.0],
                        "ears": [
                            [
                                "ear": "left",
                                "sensitivity": ["unit": "dBHL", "value": 15.0]
                            ]
                        ]
                    ]
                ]
            ]
        ]
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

    /// Kinds the phone's encoder can actually produce today.
    ///
    /// This list is the audit's claim, so it only holds kinds something
    /// upstream can really emit. `correlation` is deliberately not here: the
    /// `HKCorrelation` branch in the encoder is unreachable, because
    /// `encode(sample:)` is only called from anchored queries over
    /// `typesByKey`, correlation types are never in it, and an anchored query
    /// on a quantity or category type cannot return an `HKCorrelation`. The
    /// receiver would handle one, which is worth keeping and is covered
    /// separately below — but listing it here would make this test read as
    /// proof of end-to-end coverage that does not exist.
    private static let kindsThePhoneEmits = [
        ("quantity", "HKQuantityTypeIdentifierStepCount"),
        ("category", "HKCategoryTypeIdentifierSleepAnalysis"),
        ("sample", "HKQuantityTypeIdentifierBodyMass"),
        ("workout", "HKWorkoutTypeIdentifier"),
        ("workoutRoute", "HKWorkoutRouteTypeIdentifier"),
        ("workoutRouteLocations", "HKWorkoutRouteTypeIdentifier"),
        ("workoutRouteEnd", "HKWorkoutRouteTypeIdentifier")
    ]

    /// The one test that would have caught both bugs.
    func testEveryKindThePhoneEmitsIsStoredRatherThanDropped() async throws {
        let sampleKinds = Self.kindsThePhoneEmits

        var objects = sampleKinds.map { sampleShaped(kind: $0.0, type: $0.1) }
        objects.append(characteristicsRecord())
        // Emitted too, but deliberately not stored as generic samples: an ECG
        // has no single value and its pages are not readings. They are audited
        // in ReceiverSeriesTests, and named here so this list stays a complete
        // account of what the phone can send.
        objects.append(contentsOf: seriesRecords())
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
            batch.electrocardiograms.count,
            1,
            "An ECG is one reading, read into its own shape rather than sample."
        )
        XCTAssertEqual(batch.voltagePages.count, 1)
        XCTAssertEqual(batch.audiograms.count, 1)
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

    /// The receiver accepts deliveries from anything a user points at it —
    /// its own parser says so, and the Mac also watches a folder — so handling
    /// a correlation is worth keeping even though Hozz's own phone app cannot
    /// currently produce one. This is defensive coverage, not evidence that
    /// correlations are exported.
    func testACorrelationWouldBeStoredIfSomeProducerSentOne() async throws {
        let batch = try BatchParser.parse(
            try payload([
                sampleShaped(
                    kind: "correlation",
                    type: "HKCorrelationTypeIdentifierBloodPressure"
                )
            ])
        )
        XCTAssertEqual(batch.records.first?.kind, "correlation")

        let store = try makeStore()
        let result = try await store.ingest(batch, idempotencyKey: "correlation-1")
        XCTAssertEqual(result.stored, 1)
        XCTAssertEqual(result.unhandled, 0)
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

    // Migration is covered properly in SchemaMigrationTests, which builds a
    // genuine database at each historical version and opens it with today's
    // code.
    //
    // The test that used to live here claimed to do that and did not: it built
    // a store at the *current* schema, dropped two tables, and set
    // user_version = 2. Every other table still existed, so every
    // CREATE TABLE IF NOT EXISTS was a no-op and it passed while exercising
    // almost none of the upgrade path. It also hid a real defect — a v3
    // database could not be opened at all — which the replacement found
    // immediately. A test whose name claims coverage it does not provide is
    // worse than no test, because it stops anyone writing the real one.
}
