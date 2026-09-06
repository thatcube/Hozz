import Foundation
import HozzCore
import HozzStore
@testable import HozzReceive
import XCTest

/// Covers the desktop side: understanding whatever the phone sends, and storing
/// it so the same batch arriving twice does not become two copies.
final class ReceiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-receive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() throws -> IngestStore {
        try IngestStore(directory: root.appending(path: "store"))
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(Timestamps.date(from: text))
    }

    // MARK: - Parsing

    func testNDJSONIsParsed() throws {
        let payload = Data(
            """
            {"id":"a","type":"HKQuantityTypeIdentifierStepCount","startDate":"2026-01-01T10:00:00.000Z","quantity":{"value":120,"unit":"count"},"source":{"name":"iPhone"}}
            {"id":"b","type":"HKQuantityTypeIdentifierStepCount","startDate":"2026-01-01T11:00:00.000Z","quantity":{"value":80,"unit":"count"}}
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.count, 2)
        XCTAssertEqual(batch.records.first?.value, 120)
        XCTAssertEqual(batch.records.first?.unit, "count")
        XCTAssertEqual(batch.records.first?.sourceName, "iPhone")
        XCTAssertEqual(batch.unreadableCount, 0)
    }

    func testAJSONArrayIsParsed() throws {
        let payload = Data(
            """
            [{"id":"a","type":"HKQuantityTypeIdentifierHeartRate","startDate":"2026-01-01T10:00:00.000Z","quantity":{"value":62,"unit":"count/min"}}]
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(batch.records.first?.value, 62)
    }

    func testAnInvalidTopLevelJSONArrayIsRejected() {
        for payload in [
            #"[{"id":"truncated"}"#,
            #"[1]"#
        ] {
            XCTAssertThrowsError(try BatchParser.parse(Data(payload.utf8))) { error in
                guard case BatchParseError.invalidTopLevelJSONArray = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testLeadingBOMIsRemovedBeforeJSONArrayClassification() throws {
        let batch = try BatchParser.parse(
            Data(
                (
                    "\u{FEFF}[{\"id\":\"a\",\"type\":\"steps\","
                        + "\"startDate\":\"2026-01-01T10:00:00.000Z\"}]"
                ).utf8
            )
        )

        XCTAssertEqual(batch.records.map(\.id), ["a"])
    }

    func testCSVIsParsed() throws {
        let payload = Data(
            """
            id,type,kind,startDate,endDate,value,unit,sourceName,deleted
            a,HKQuantityTypeIdentifierStepCount,quantity,2026-01-01T10:00:00.000Z,2026-01-01T10:01:00.000Z,120,count,iPhone,
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(batch.records.first?.value, 120, "CSV values arrive as text and must be converted.")
        XCTAssertEqual(batch.records.first?.type, "HKQuantityTypeIdentifierStepCount")
    }

    func testCSVCanonicalDeletionUsesTheLegacyAliasBridgeAndRemainsRetryable()
        async throws
    {
        let store = try makeStore()
        let date = "2026-01-01T10:00:00.000Z"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"\(date)","qty":120}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "old-step-count"
        )

        let unresolved = try BatchParser.parse(
            Data(
                """
                id,type,kind,startDate,endDate,value,unit,sourceName,deleted
                stable-step,HKQuantityTypeIdentifierStepCount,deletion,,,,,,true
                """.utf8
            )
        )
        XCTAssertEqual(unresolved.deletions.first?.type, "step_count")
        XCTAssertEqual(
            unresolved.deletions.first?.requiresLegacyAliasResolution,
            true
        )
        do {
            _ = try await store.ingest(
                unresolved,
                idempotencyKey: "csv-canonical-delete"
            )
            XCTFail("An unmatched canonical CSV deletion must stay retryable.")
        } catch is UnresolvedLegacyAliasError {
        }

        let corrected = try BatchParser.parse(
            Data(
                """
                id,type,kind,startDate,endDate,value,unit,sourceName,deleted
                step_count:\(date),HKQuantityTypeIdentifierStepCount,deletion,,,,,,true
                """.utf8
            )
        )
        let retry = try await store.ingest(
            corrected,
            idempotencyKey: "csv-canonical-delete"
        )
        XCTAssertFalse(
            retry.duplicate,
            "A rejected deletion must not leave a receipt that suppresses its retry."
        )
        let duplicate = try await store.ingest(
            corrected,
            idempotencyKey: "csv-canonical-delete"
        )
        XCTAssertTrue(duplicate.duplicate)
        let remaining = try await store.totalRecordCount()
        XCTAssertEqual(remaining, 0)
    }

    func testTheMetricsEnvelopeIsFlattened() throws {
        let payload = Data(
            """
            {"data":{"metrics":[{"name":"step_count","units":"count","data":[
              {"date":"2026-01-01T10:00:00.000Z","qty":120},
              {"date":"2026-01-01T11:00:00.000Z","qty":80}
            ]}],"deletions":[]}}
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.count, 2)
        XCTAssertEqual(batch.records.first?.unit, "count")
        XCTAssertEqual(
            batch.records.first?.id,
            "step_count:2026-01-01T10:00:00.000Z",
            "A shape with no sample id needs a derived one, or re-delivery duplicates."
        )
    }

    func testBooleanMetricRejectsTheWholeCompatibilityEnvelope() {
        XCTAssertThrowsError(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"not-a-number","date":"2026-01-01T10:00:00.000Z","qty":true}
                    ]}]}}
                    """.utf8
                )
            )
        ) { error in
            guard case BatchParseError.incompleteCompatibilityEnvelope(1) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHozzMetricsUseStableIdsAndKeepHeartAndSleepValues() async throws {
        let payload = Data(
            """
            {"data":{"metrics":[
              {"name":"heart_rate","units":"bpm","data":[
                {"id":"heart-1","date":"2026-01-01T10:00:00.000Z","Min":62,"Avg":62,"Max":62}]},
              {"name":"sleep_analysis","units":"hr","data":[
                {"id":"sleep-1","startDate":"2026-01-01T11:00:00.000Z","endDate":"2026-01-01T12:00:00.000Z","qty":1,"value":"REM","rawValue":5}]}
            ]}}
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.map(\.id), ["heart-1", "sleep-1"])
        XCTAssertEqual(batch.records.map(\.value), [62, 5])
        XCTAssertEqual(batch.records.map(\.kind), ["quantity", "category"])
        let sleepRaw = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(batch.records.last?.raw)
            ) as? [String: Any]
        )
        XCTAssertEqual((sleepRaw["rawValue"] as? NSNumber)?.doubleValue, 5)
        XCTAssertEqual((sleepRaw["qty"] as? NSNumber)?.doubleValue, 1)

        let store = try makeStore()
        _ = try await store.ingest(batch, idempotencyKey: "sleep-semantics")
        let sleepSamples = try await store.samples(type: "sleep_analysis")
        let sleep = try XCTUnwrap(sleepSamples.first)
        XCTAssertEqual(sleep.value, 5)
        XCTAssertEqual(sleep.endDate.timeIntervalSince(sleep.startDate), 3_600)
    }

    func testCompatibilityWorkoutWithoutDurationDoesNotInventOne() throws {
        let payload = Data(
            """
            {"data":{
              "metrics":[
                {"name":"heart_rate","units":"count/min","data":[
                  {"date":"2026-01-01T10:00:00.000Z","qty":62}]},
                {"name":"sleep_analysis","units":"count","data":[
                  {"date":"2026-01-01T11:00:00.000Z","endDate":"2026-01-01T12:00:00.000Z","qty":3}]}
              ],
              "workouts":[
                {"id":"workout-default","name":"Workout","start":"2026-01-01T13:00:00.000Z","end":"2026-01-01T13:30:00.000Z"}
              ]
            }}
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.map(\.value), [62, 3, nil])
        XCTAssertEqual(batch.records.map(\.kind), ["quantity", "category", "workout"])
        XCTAssertNil(batch.workoutDetails.first?.duration)
        XCTAssertEqual(batch.workoutDetails.first?.provenance, .compatibility)
    }

    func testMalformedStableIdentifierRejectsCompatibilityEnvelope() {
        XCTAssertThrowsError(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"steps","units":"count","data":[
                      {"id":7,"date":"2026-01-01T10:00:00.000Z","qty":1}
                    ]}]}}
                    """.utf8
                )
            )
        )
    }

    func testNonfiniteMetricRejectsCompatibilityEnvelope() {
        XCTAssertThrowsError(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"steps","units":"count","data":[
                      {"id":"not-finite","date":"2026-01-01T10:00:00.000Z","qty":"NaN"}
                    ]}]}}
                    """.utf8
                )
            )
        )
    }

    func testCompatibilityCollectionsWithoutMetricsAreRejected() {
        XCTAssertThrowsError(
            try BatchParser.parse(
                Data(#"{"data":{"workouts":[]}}"#.utf8)
            )
        )
    }

    func testHozzMetricsDateLessDeletionUsesStableId() throws {
        let payload = Data(
            """
            {"data":{"metrics":[],"deletions":[
              {"id":"gone","name":"step_count","type":"HKQuantityTypeIdentifierStepCount","date":""}
            ]}}
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.deletions, [
            HealthDeletion(
                id: "gone",
                type: "step_count",
                startDate: nil,
                requiresLegacyAliasResolution: true
            )
        ])
        XCTAssertEqual(batch.unreadableCount, 0)
    }

    func testStableDeletionDoesNotRemoveAnotherSampleAtTheSameTime() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
                try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"keep","date":"2026-01-01 10:00:00 +0000","qty":80},
                      {"id":"gone","date":"2026-01-01 10:00:00 +0000","qty":120}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "samples"
        )

        let result = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[],"deletions":[
                      {"id":"gone","name":"step_count","type":"step_count","date":"2026-01-01 10:00:00 +0000"}
                    ]}}
                    """.utf8
                )
            ),
            idempotencyKey: "deletion"
        )

        XCTAssertEqual(result.deleted, 1)
        let remaining = try await store.samples(type: "step_count")
        XCTAssertEqual(remaining.map(\.id), ["keep"])
    }

    func testStableDeletionCannotGuessPreUpgradeTimeAlias() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"\(date)","qty":120}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "legacy"
        )
        let deletion = try BatchParser.parse(
            Data(
                """
                {"data":{"metrics":[],"deletions":[
                  {"id":"stable","name":"step_count","type":"step_count","date":"\(date)"}
                ]}}
                """.utf8
            )
        )

        for key in ["delete-1", "delete-2"] {
            do {
                _ = try await store.ingest(deletion, idempotencyKey: key)
                XCTFail("A timestamp alone cannot identify the stable record.")
            } catch is UnresolvedLegacyAliasError {
            }
        }
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 1)
    }

    func testDateLessStableDeletionRefusesToReceiptUnresolvedLegacyAlias() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"\(date)","qty":120}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "legacy-live"
        )
        let dateLess = try BatchParser.parse(
            Data(
                """
                {"data":{"metrics":[],"deletions":[
                  {"id":"stable","name":"step_count","type":"step_count","date":""}
                ]}}
                """.utf8
            )
        )

        do {
            _ = try await store.ingest(dateLess, idempotencyKey: "stable-delete")
            XCTFail("An unresolved legacy alias must keep the batch retryable.")
        } catch is UnresolvedLegacyAliasError {
        }
        let stillLive = try await store.totalRecordCount()
        XCTAssertEqual(stillLive, 1)

        let dated = try BatchParser.parse(
            Data(
                """
                {"data":{"metrics":[],"deletions":[
                  {"id":"stable","name":"step_count","type":"step_count","date":"\(date)"}
                ]}}
                """.utf8
            )
        )
        do {
            _ = try await store.ingest(
                dated,
                idempotencyKey: "stable-delete"
            )
            XCTFail("Adding a date still cannot prove a stable identity.")
        } catch is UnresolvedLegacyAliasError {
        }
        let remaining = try await store.totalRecordCount()
        XCTAssertEqual(remaining, 1)
    }

    func testSameBatchStableReplacementCanResolveAliasBeforeDateLessDelete() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"\(date)","qty":120}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "legacy-before-mixed"
        )
        let mixed = try BatchParser.parse(
            Data(
                """
                {"data":{
                  "metrics":[{"name":"step_count","units":"count","data":[
                    {"id":"stable","date":"\(date)","qty":120}
                  ]}],
                  "deletions":[
                    {"id":"stable","name":"step_count","type":"step_count","date":""}
                  ]
                }}
                """.utf8
            )
        )

        let result = try await store.ingest(
            mixed,
            idempotencyKey: "mixed-resolution"
        )

        XCTAssertFalse(result.duplicate)
        XCTAssertEqual(result.deleted, 1)
        let remaining = try await store.totalRecordCount()
        XCTAssertEqual(remaining, 0)
    }

    func testExistingStableRecordAllowsDateLessDeleteDespiteUnrelatedLegacyAlias() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"2026-01-01 09:00:00 +0000","qty":10},
                      {"id":"stable","date":"2026-01-01 10:00:00 +0000","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "mixed-identities"
        )
        let deletion = try BatchParser.parse(
            Data(
                """
                {"data":{"metrics":[],"deletions":[
                  {"id":"stable","name":"step_count","type":"step_count","date":""}
                ]}}
                """.utf8
            )
        )

        let result = try await store.ingest(
            deletion,
            idempotencyKey: "delete-stable-only"
        )

        XCTAssertEqual(result.deleted, 1)
        let remaining = try await store.samples(type: "step_count")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining[0].id.hasPrefix("step_count:"))
    }

    func testFreshDateLessStableDeletionSuppressesLaterStableAndLegacyRecords() async throws {
        let store = try makeStore()
        let deletion = try BatchParser.parse(
            Data(
                """
                {"data":{"metrics":[],"deletions":[
                  {"id":"late","name":"step_count","type":"step_count","date":""}
                ]}}
                """.utf8
            )
        )
        let first = try await store.ingest(
            deletion,
            idempotencyKey: "late-delete"
        )
        XCTAssertFalse(first.duplicate)

        let delayedLegacy = try BatchParser.parse(
            Data(
                """
                {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                  {"date":"2026-01-01 10:00:00 +0000","qty":20}
                ]}]}}
                """.utf8
            )
        )
        do {
            _ = try await store.ingest(
                delayedLegacy,
                idempotencyKey: "late-legacy"
            )
            XCTFail("An unresolved old identity must not bypass a fresh tombstone.")
        } catch is UnresolvedLegacyAliasError {
        }

        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"late","date":"2026-01-01 10:00:00 +0000","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "late-upsert"
        )
        let retry = try await store.ingest(
            deletion,
            idempotencyKey: "late-delete"
        )

        XCTAssertTrue(retry.duplicate)
        let finalCount = try await store.totalRecordCount()
        XCTAssertEqual(finalCount, 0)

        do {
            _ = try await store.ingest(
                delayedLegacy,
                idempotencyKey: "late-legacy"
            )
            XCTFail("A stable tombstone cannot prove a legacy timestamp identity.")
        } catch is UnresolvedLegacyAliasError {
        }
        let afterLegacy = try await store.totalRecordCount()
        XCTAssertEqual(afterLegacy, 0)
    }

    func testGenericTombstonePreventsDelayedStableUpsert() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"late","type":"steps","kind":"deletion","deleted":true}
                    """.utf8
                )
            ),
            idempotencyKey: "generic-delete"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"late","type":"steps","kind":"quantity","startDate":"2026-01-01T10:00:00.000Z","quantity":{"value":20,"unit":"count"}}
                    """.utf8
                )
            ),
            idempotencyKey: "delayed-upsert"
        )

        let finalCount = try await store.totalRecordCount()
        XCTAssertEqual(finalCount, 0)
    }

    func testStableDeletionPreventsDelayedLegacyAliasFromResurrecting() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"stable","date":"2026-01-01 05:00:00 -0500","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "stable-before-delete"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[],"deletions":[
                      {"id":"stable","name":"step_count","type":"step_count","date":""}
                    ]}}
                    """.utf8
                )
            ),
            idempotencyKey: "stable-delete"
        )

        do {
            _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"\(date)","qty":20}
                    ]}]}}
                    """.utf8
                )
                ),
                idempotencyKey: "delayed-legacy"
            )
            XCTFail("An offset-only legacy identity must remain retryable.")
        } catch is UnresolvedLegacyAliasError {
        }

        let finalCount = try await store.totalRecordCount()
        XCTAssertEqual(finalCount, 0)
    }

    func testEquivalentTimestampLegacyAliasCannotBypassRetirement() async throws {
        let store = try makeStore()
        do {
            _ = try await store.ingest(
                try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"stable","date":"2026-01-01 05:00:00 -0500","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "stable-offset"
        )

        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"2026-01-01 10:00:00 +0000","qty":20}
                    ]}]}}
                    """.utf8
                )
                ),
                idempotencyKey: "legacy-offset"
            )
            XCTFail("A delayed offset alias has no proven stable identity.")
        } catch is UnresolvedLegacyAliasError {
        }

        let records = try await store.samples(type: "step_count")
        XCTAssertEqual(records.map(\.id), ["stable"])
    }

    func testEquivalentLiveAndRetiredOffsetAliasesAreNeverGuessedInEitherOrder()
        async throws
    {
        for tombstoneFirst in [false, true] {
            let directory = root.appending(
                path: tombstoneFirst ? "tombstone-first" : "live-first"
            )
            let store = try IngestStore(directory: directory)
            let liveAlias = try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"2026-01-01 05:00:00 -0500","qty":20}
                    ]}]}}
                    """.utf8
                )
            )
            let retiredAlias = try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[],"deletions":[
                      {"name":"step_count","date":"2026-01-01 10:00:00 +0000"}
                    ]}}
                    """.utf8
                )
            )
            if tombstoneFirst {
                _ = try await store.ingest(
                    retiredAlias,
                    idempotencyKey: "retired-first"
                )
                _ = try await store.ingest(
                    liveAlias,
                    idempotencyKey: "live-second"
                )
            } else {
                _ = try await store.ingest(
                    liveAlias,
                    idempotencyKey: "live-first"
                )
                _ = try await store.ingest(
                    retiredAlias,
                    idempotencyKey: "retired-second"
                )
            }
            await store.close()

            let database = try SQLiteDatabase(
                url: directory.appending(path: "hozz-received.sqlite")
            )
            try database.run(
                """
                INSERT INTO sample_alias_signature
                    (stable_id, type, kind, start_time, end_time,
                     value, unit, source_name)
                VALUES (
                    'stable-offset', 'step_count', 'quantity',
                    '2026-01-01T10:00:00.000Z',
                    '2026-01-01T10:00:00.000Z',
                    20, 'count', NULL
                )
                """
            )
            database.close()

            let reopened = try IngestStore(directory: directory)
            let stable = try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"stable-offset",
                       "date":"2026-01-01 11:00:00 +0100","qty":20}
                    ]}]}}
                    """.utf8
                )
            )

            do {
                _ = try await reopened.ingest(
                    stable,
                    idempotencyKey: "stable-third"
                )
                XCTFail(
                    "Equivalent live and retired aliases must remain ambiguous "
                        + "when tombstoneFirst=\(tombstoneFirst)."
                )
            } catch is UnresolvedLegacyAliasError {
            }

            let records = try await reopened.samples(type: "step_count")
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(
                records.first?.id,
                "step_count:2026-01-01 05:00:00 -0500"
            )
            await reopened.close()

            let inspected = try SQLiteDatabase(
                url: directory.appending(path: "hozz-received.sqlite")
            )
            let mappingCount = try inspected.query(
                """
                SELECT COUNT(*) FROM sample_identity_alias
                WHERE stable_id = 'stable-offset'
                """,
                row: { $0.integer(0) }
            ).first
            inspected.close()
            XCTAssertEqual(mappingCount, 0)
        }
    }

    func testExactLegacyTombstoneSuppressesLaterStableCompatibilityUpsert() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[],"deletions":[
                      {"name":"step_count","date":"\(date)"}
                    ]}}
                    """.utf8
                )
            ),
            idempotencyKey: "legacy-time-delete"
        )

        let result = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"stable-after-delete","date":"\(date)","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "stable-after-time-delete"
        )

        XCTAssertEqual(result.stored, 0)
        let remaining = try await store.samples(type: "step_count")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testNormalizedLegacyRetirementRejectsAmbiguousStableCompatibilityUpsert() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[],"deletions":[
                      {"name":"step_count","date":"2026-01-01 10:00:00 +0000"}
                    ]}}
                    """.utf8
                )
            ),
            idempotencyKey: "normalized-time-delete"
        )
        let ambiguous = try BatchParser.parse(
            Data(
                """
                {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                  {"id":"stable-offset","date":"2026-01-01 05:00:00 -0500","qty":20}
                ]}]}}
                """.utf8
            )
        )

        for _ in 0..<2 {
            do {
                _ = try await store.ingest(
                    ambiguous,
                    idempotencyKey: "ambiguous-stable"
                )
                XCTFail("A normalized retirement without an exact alias is ambiguous.")
            } catch is UnresolvedLegacyAliasError {
            }
        }
        let remaining = try await store.samples(type: "step_count")
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSameTimestampDistinctSourceAndValueAreNotAliases() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"\(date)","qty":111,"source":"Watch"}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "watch-legacy"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"phone-stable","date":"\(date)","qty":222,"source":"Phone"}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "phone-stable"
        )

        let records = try await store.samples(type: "step_count")
        XCTAssertEqual(records.count, 2)
    }

    func testOneLegacyAliasCannotBeConsumedByTwoStableBatchRecords() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"\(date)","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "one-legacy"
        )
        let ambiguous = try BatchParser.parse(
            Data(
                """
                {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                  {"id":"stable-a","date":"\(date)","qty":20},
                  {"id":"stable-b","date":"\(date)","qty":20}
                ]}]}}
                """.utf8
            )
        )

        do {
            _ = try await store.ingest(ambiguous, idempotencyKey: "two-stable")
            XCTFail("An ambiguous batch must remain retryable.")
        } catch is UnresolvedLegacyAliasError {
        }

        let records = try await store.samples(type: "step_count")
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].id.hasPrefix("step_count:"))
    }

    func testMappedLegacyReplayCannotChangeFieldsAndResurrect() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"\(date)","qty":20,"source":"Watch"}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "mapped-legacy"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"stable","date":"\(date)","qty":20,"source":"Watch"}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "mapped-stable"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"\(date)","qty":999,"source":"Other"}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "mutated-legacy-replay"
        )

        let records = try await store.samples(type: "step_count")
        XCTAssertEqual(records.map(\.id), ["stable"])
        XCTAssertEqual(records.first?.value, 20)
    }

    func testTimestampDeletionPreservesUnmappedStableRecord() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"stable","type":"step_count","kind":"quantity","startDate":"2026-01-01T10:00:00.000Z","quantity":{"value":99,"unit":"count"}}
                    """.utf8
                )
            ),
            idempotencyKey: "unmapped-stable"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[],"deletions":[
                      {"name":"step_count","type":"step_count","date":"\(date)"}
                    ]}}
                    """.utf8
                )
            ),
            idempotencyKey: "legacy-only-delete"
        )

        let records = try await store.samples(type: "step_count")
        XCTAssertEqual(records.map(\.id), ["stable"])
    }

    func testPreMigrationStableRecordLazilyRetiresDelayedLegacyAlias() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"stable","date":"\(date)","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "stable-pre-migration"
        )
        await store.close()
        let database = try SQLiteDatabase(
            url: root.appending(path: "store/hozz-received.sqlite")
        )
        try database.execute(
            """
            DELETE FROM sample_identity_alias;
            DELETE FROM sample_alias_retirement;
            """
        )
        database.close()
        let reopened = try makeStore()

        do {
            _ = try await reopened.ingest(
                try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"2026-01-01 05:00:00 -0500","qty":20}
                    ]}]}}
                    """.utf8
                )
                ),
                idempotencyKey: "legacy-after-migration"
            )
            XCTFail("An upgrade cannot infer a delayed legacy identity.")
        } catch is UnresolvedLegacyAliasError {
        }

        let records = try await reopened.samples(type: "step_count")
        XCTAssertEqual(records.map(\.id), ["stable"])
    }

    func testTimestampDeletionTombstonesMappedStableIdentity() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        let stable = try BatchParser.parse(
            Data(
                """
                {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                  {"id":"stable","date":"\(date)","qty":20}
                ]}]}}
                """.utf8
            )
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"\(date)","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "legacy-before-stable-time-delete"
        )
        _ = try await store.ingest(stable, idempotencyKey: "stable-before-time-delete")
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[],"deletions":[
                      {"name":"step_count","type":"step_count","date":"\(date)"}
                    ]}}
                    """.utf8
                )
            ),
            idempotencyKey: "time-delete"
        )
        _ = try await store.ingest(stable, idempotencyKey: "stable-replay")

        let finalCount = try await store.totalRecordCount()
        XCTAssertEqual(finalCount, 0)
    }

    func testTombstonedStableArrivalDeletesAlreadyLiveLegacyAlias() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"\(date)","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "legacy-first"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"stable","type":"step_count","kind":"deletion","deleted":true}
                    """.utf8
                )
            ),
            idempotencyKey: "stable-tombstone"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"stable","date":"2026-01-01 05:00:00 -0500","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "stable-after-tombstone"
        )

        let finalCount = try await store.totalRecordCount()
        XCTAssertEqual(finalCount, 0)
    }

    func testTombstonedStableArrivalPreservesUnmatchedLegacySample() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"\(date)","qty":111,"source":"Watch"}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "unmatched-legacy"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"stable","type":"step_count","kind":"deletion","deleted":true}
                    """.utf8
                )
            ),
            idempotencyKey: "unmatched-stable-tombstone"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"stable","date":"\(date)","qty":222,"source":"Phone"}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "unmatched-stable-arrival"
        )

        let records = try await store.samples(type: "step_count")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.value, 111)
        XCTAssertEqual(records.first?.sourceName, "Watch")
    }

    func testDeletionReplayDoesNotRecreateResolvedLegacyBarrier() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"stable","date":"\(date)","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "stable-for-replay"
        )
        let deletion = try BatchParser.parse(
            Data(
                """
                {"data":{"metrics":[],"deletions":[
                  {"id":"stable","name":"step_count","type":"step_count","date":""}
                ]}}
                """.utf8
            )
        )
        _ = try await store.ingest(deletion, idempotencyKey: "delete-once")
        _ = try await store.ingest(deletion, idempotencyKey: "delete-again")

        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"2026-01-02 10:00:00 +0000","qty":30}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "unrelated-legacy"
        )

        let records = try await store.samples(type: "step_count")
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].id.hasPrefix("step_count:"))
    }

    func testAudiogramTombstoneRemovesHeaderAndPoints() async throws {
        let store = try makeStore()
        let audiogram = ReceivedAudiogram(
            id: "hearing-test",
            startDate: try date("2026-01-01T10:00:00.000Z"),
            endDate: nil,
            sourceName: "iPhone",
            points: [
                .init(
                    frequency: 1_000,
                    ear: "left",
                    sensitivity: 20,
                    unit: "dBHL",
                    masked: false,
                    clamped: false
                )
            ],
            raw: Data(#"{"kind":"audiogram"}"#.utf8)
        )
        _ = try await store.ingest(
            ParsedBatch(
                records: [],
                deletions: [],
                audiograms: [audiogram],
                unreadableCount: 0
            ),
            idempotencyKey: "audiogram"
        )
        let storedAudiograms = try await store.audiograms()
        XCTAssertEqual(storedAudiograms.count, 1)

        let result = try await store.ingest(
            ParsedBatch(
                records: [],
                deletions: [.init(id: "hearing-test")],
                unreadableCount: 0
            ),
            idempotencyKey: "audiogram-delete"
        )

        XCTAssertEqual(result.deleted, 0)
        let remainingAudiograms = try await store.audiograms()
        XCTAssertTrue(remainingAudiograms.isEmpty)

        _ = try await store.ingest(
            ParsedBatch(
                records: [],
                deletions: [],
                audiograms: [audiogram],
                unreadableCount: 0
            ),
            idempotencyKey: "delayed-audiogram"
        )
        let afterDelayedAudiogram = try await store.audiograms()
        XCTAssertTrue(afterDelayedAudiogram.isEmpty)
    }

    func testStableMetricIdAtomicallyReplacesLegacyAlias() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"2026-01-01 10:00:00 +0000","qty":120}]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "legacy"
        )

        let result = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"stable","date":"2026-01-01 05:00:00 -0500","qty":120}]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "stable"
        )

        XCTAssertEqual(result.stored, 1)
        let samples = try await store.samples(type: "step_count")
        XCTAssertEqual(samples.map(\.id), ["stable"])
    }

    /// A connection test is a valid request carrying no samples. Reporting it
    /// as unreadable would tell the user their setup is broken at exactly the
    /// moment they are checking that it works.
    func testAConnectionTestIsRecognisedRatherThanRejected() {
        let payload = Data(#"{"kind":"hozzConnectionTest","schemaVersion":1}"#.utf8)

        XCTAssertThrowsError(try BatchParser.parse(payload)) { error in
            guard case BatchParseError.connectionTest = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testConnectionTestRequiresTheExactParsedObject() throws {
        let batch = try BatchParser.parse(
            Data(
                #"{"kind":"hozzConnectionTest","schemaVersion":1,"record":"not a probe"}"#
                    .utf8
            )
        )

        XCTAssertEqual(batch.unhandled.count, 1)
    }

    func testUnreadableLinesAreCountedNotDiscardedSilently() throws {
        let payload = Data(
            """
            {"id":"a","type":"T","startDate":"2026-01-01T10:00:00.000Z"}
            this is not json
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(batch.unreadableCount, 1, "A dropped line must be visible.")
    }

    /// Regression: Hozz's own encoder marks a removed sample with
    /// `kind: "deletion"` and no dates. The parser only understood a `deleted`
    /// flag, so its own NDJSON deletions were counted as unreadable, answered
    /// 200, and never resent — the sample stayed on the receiver forever and
    /// kept being served to an assistant as live data.
    func testHozzsOwnDeletionShapeIsUnderstood() throws {
        let payload = Data(
            #"{"id":"gone","kind":"deletion","schemaVersion":1,"type":"HKQuantityTypeIdentifierStepCount"}"#.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.deletions.count, 1, "A kind=deletion line is a deletion.")
        XCTAssertEqual(batch.deletions.first?.id, "gone")
        XCTAssertEqual(batch.deletions.first?.type, "step_count")
        XCTAssertEqual(
            batch.deletions.first?.requiresLegacyAliasResolution,
            true
        )
        XCTAssertEqual(batch.unreadableCount, 0, "It must not be counted as junk.")
    }

    func testCanonicalDeletionRefusesReceiptWhileLegacyAliasIsUnresolved() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"2026-01-01 10:00:00 +0000","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "canonical-delete-legacy"
        )
        let deletion = try BatchParser.parse(
            Data(
                #"{"id":"canonical-id","kind":"deletion","schemaVersion":1,"type":"HKQuantityTypeIdentifierStepCount"}"#
                    .utf8
            )
        )

        for _ in 0..<2 {
            do {
                _ = try await store.ingest(
                    deletion,
                    idempotencyKey: "canonical-delete"
                )
                XCTFail("The old timestamp identity has not been resolved.")
            } catch is UnresolvedLegacyAliasError {
            }
        }
        let remaining = try await store.totalRecordCount()
        XCTAssertEqual(remaining, 1)
    }

    func testCanonicalDeletionRemovesSafelyResolvedCompatibilityAlias() async throws {
        let store = try makeStore()
        let date = "2026-01-01 10:00:00 +0000"
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"\(date)","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "canonical-delete-old"
        )
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"id":"canonical-id","date":"\(date)","qty":20}
                    ]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "canonical-delete-bridge"
        )

        let result = try await store.ingest(
            try BatchParser.parse(
                Data(
                    #"{"id":"canonical-id","kind":"deletion","schemaVersion":1,"type":"HKQuantityTypeIdentifierStepCount"}"#
                        .utf8
                )
            ),
            idempotencyKey: "canonical-delete-resolved"
        )

        XCTAssertEqual(result.deleted, 1)
        let remaining = try await store.totalRecordCount()
        XCTAssertEqual(remaining, 0)
    }

    func testCanonicalDeletionBlocksDelayedLegacyAlias() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    #"{"id":"canonical-id","kind":"deletion","schemaVersion":1,"type":"HKQuantityTypeIdentifierStepCount"}"#
                        .utf8
                )
            ),
            idempotencyKey: "canonical-delete-first"
        )
        let delayedLegacy = try BatchParser.parse(
            Data(
                """
                {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                  {"date":"2026-01-01 10:00:00 +0000","qty":20}
                ]}]}}
                """.utf8
            )
        )

        do {
            _ = try await store.ingest(
                delayedLegacy,
                idempotencyKey: "canonical-delete-delayed-legacy"
            )
            XCTFail("A delayed legacy identity must not bypass the tombstone.")
        } catch is UnresolvedLegacyAliasError {
        }
        let remaining = try await store.totalRecordCount()
        XCTAssertEqual(remaining, 0)
    }

    func testAnNDJSONDeletionActuallyRemovesTheSample() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(#"{"id":"a","type":"S","startDate":"2026-01-01T10:00:00.000Z","value":1}"#.utf8)
            ),
            idempotencyKey: "k1"
        )

        let result = try await store.ingest(
            try BatchParser.parse(
                Data(#"{"id":"a","kind":"deletion","schemaVersion":1,"type":"S"}"#.utf8)
            ),
            idempotencyKey: "k2"
        )

        XCTAssertEqual(result.deleted, 1)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 0)
    }

    /// Regression: workouts travel in their own key of the metrics envelope.
    /// They were dropped without even counting as unreadable, so the receiver
    /// answered 200 and the phone never sent them again.
    func testWorkoutsInTheMetricsEnvelopeKeepDuration() async throws {
        let payload = Data(
            """
            {"data":{"metrics":[],"workouts":[
              {"id":"w1","name":"Workout","start":"2026-01-01T10:00:00.000Z","end":"2026-01-01T11:00:00.000Z","duration":3600}
            ]}}
            """.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.records.count, 1, "A workout must not vanish.")
        XCTAssertEqual(batch.records.first?.id, "w1")
        XCTAssertEqual(batch.records.first?.kind, "workout")
        XCTAssertEqual(batch.records.first?.value, 3_600)
        XCTAssertEqual(batch.records.first?.unit, "sec")
        XCTAssertEqual(batch.workoutDetails.first?.duration, 3_600)

        let store = try makeStore()
        _ = try await store.ingest(batch, idempotencyKey: "workout-duration")
        let samples = try await store.samples(type: "workout")
        let workouts = try await store.workouts()
        XCTAssertEqual(samples.first?.value, 3_600)
        XCTAssertEqual(workouts.first?.duration, 3_600)
    }

    func testStableWorkoutTypeReplacesLegacyNameIdentity() async throws {
        let store = try makeStore()
        let start = try date("2026-01-01T10:00:00.000Z")
        let end = try date("2026-01-01T11:00:00.000Z")
        _ = try await store.ingest(
            ParsedBatch(
                records: [
                    HealthRecord(
                        id: "w1",
                        type: "Running",
                        kind: "workout",
                        startDate: start,
                        endDate: end,
                        value: 3_600,
                        unit: "sec",
                        raw: Data()
                    )
                ],
                deletions: [],
                unreadableCount: 0
            ),
            idempotencyKey: "legacy-workout"
        )
        let upgraded = try BatchParser.parse(
            Data(
                """
                {"data":{"metrics":[],"workouts":[
                  {"id":"w1","name":"Running","start":"2026-01-01T10:00:00.000Z","end":"2026-01-01T11:00:00.000Z","duration":3600}
                ]}}
                """.utf8
            )
        )

        _ = try await store.ingest(upgraded, idempotencyKey: "stable-workout")

        let legacy = try await store.samples(type: "Running")
        let current = try await store.samples(type: "workout")
        let total = try await store.totalRecordCount()
        XCTAssertTrue(legacy.isEmpty)
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(total, 1)
    }

    func testCompatibilityWorkoutPreservesCanonicalSampleAndRicherDetail() async throws {
        let store = try makeStore()
        let canonical = Data(
            #"{"kind":"workout","id":"shared-workout","type":"HKWorkoutTypeIdentifier","startDate":"2026-01-01T10:00:00.123Z","endDate":"2026-01-01T11:00:00.987Z","activityType":37,"duration":3599.75,"statistics":[{"type":"HKQuantityTypeIdentifierHeartRate","unit":"count/min","average":152,"minimum":98,"maximum":178}],"source":{"name":"Apple Watch"}}"#.utf8
        )
        _ = try await store.ingest(
            try BatchParser.parse(canonical),
            idempotencyKey: "canonical-workout"
        )

        let compatibility = Data(
            """
            {"data":{"metrics":[],"workouts":[
              {"id":"shared-workout","name":"Running",
               "start":"2026-01-01T10:00:00.000Z",
               "end":"2026-01-01T11:01:00.000Z","source":"Legacy Exporter"}
            ]}}
            """.utf8
        )
        let compatibilityBatch = try BatchParser.parse(compatibility)
        XCTAssertNil(compatibilityBatch.workoutDetails.first?.duration)
        _ = try await store.ingest(
            compatibilityBatch,
            idempotencyKey: "compatibility-workout"
        )

        let canonicalSamples = try await store.samples(
            type: "HKWorkoutTypeIdentifier"
        )
        XCTAssertEqual(canonicalSamples.map(\.id), ["shared-workout"])
        XCTAssertEqual(canonicalSamples.first?.value, 3_599.75)
        XCTAssertEqual(canonicalSamples.first?.sourceName, "Apple Watch")
        let compatibilitySamples = try await store.samples(type: "workout")
        XCTAssertTrue(compatibilitySamples.isEmpty)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 1)

        let workouts = try await store.workouts()
        let workout = try XCTUnwrap(workouts.first)
        XCTAssertEqual(
            workout.startDate.timeIntervalSince1970,
            try date("2026-01-01T10:00:00.123Z").timeIntervalSince1970,
            accuracy: 0.002
        )
        let workoutEnd = try XCTUnwrap(workout.endDate)
        XCTAssertEqual(
            workoutEnd.timeIntervalSince1970,
            try date("2026-01-01T11:00:00.987Z").timeIntervalSince1970,
            accuracy: 0.002
        )
        XCTAssertEqual(workout.activityType, 37)
        XCTAssertEqual(workout.duration, 3_599.75)
        XCTAssertEqual(workout.sourceName, "Apple Watch")
        XCTAssertEqual(workout.statistics.count, 1)
        XCTAssertEqual(workout.statistics.first?.average, 152)
    }

    func testHistoricalWorkoutAliasRetiresWhenSameIDRunningArrives() async throws {
        let store = try makeStore()
        let start = try date("2026-01-01T10:00:00.000Z")
        let end = try date("2026-01-01T11:00:00.000Z")
        _ = try await store.ingest(
            ParsedBatch(
                records: [
                    HealthRecord(
                        id: "historical-workout",
                        type: "Workout",
                        kind: "workout",
                        startDate: start,
                        endDate: end,
                        value: 3_600,
                        unit: "sec",
                        sourceName: "Historical exporter",
                        raw: Data()
                    )
                ],
                deletions: [],
                unreadableCount: 0
            ),
            idempotencyKey: "historical-workout"
        )
        let running = Data(
            """
            {"data":{"metrics":[],"workouts":[
              {"id":"historical-workout","name":"Running",
               "start":"2026-01-01T10:00:00.000Z",
               "end":"2026-01-01T11:00:00.000Z",
               "duration":3600,"source":"Current exporter"}
            ]}}
            """.utf8
        )

        _ = try await store.ingest(
            try BatchParser.parse(running),
            idempotencyKey: "running-workout"
        )

        let historical = try await store.samples(type: "Workout")
        let current = try await store.samples(type: "workout")
        XCTAssertTrue(historical.isEmpty)
        XCTAssertEqual(current.map(\.id), ["historical-workout"])
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 1)
        let workouts = try await store.workouts()
        XCTAssertEqual(workouts.map(\.id), ["historical-workout"])
        XCTAssertEqual(workouts.first?.duration, 3_600)
        XCTAssertEqual(workouts.first?.sourceName, "Current exporter")
    }

    func testCanonicalWorkoutSupersedesEarlierCompatibilityFields() async throws {
        let store = try makeStore()
        let compatibility = Data(
            """
            {"data":{"metrics":[],"workouts":[
              {"id":"compatibility-first","name":"Running",
               "start":"2026-01-01T10:00:00.000Z",
               "end":"2026-01-01T11:01:00.000Z",
               "duration":3660,"source":"Legacy Exporter"}
            ]}}
            """.utf8
        )
        _ = try await store.ingest(
            try BatchParser.parse(compatibility),
            idempotencyKey: "compatibility-first"
        )
        let canonical = Data(
            #"{"kind":"workout","id":"compatibility-first","type":"HKWorkoutTypeIdentifier","startDate":"2026-01-01T10:00:00.123Z","endDate":"2026-01-01T11:00:00.987Z","activityType":37,"duration":3599.75,"statistics":[],"source":{"name":"Apple Watch"}}"#.utf8
        )

        _ = try await store.ingest(
            try BatchParser.parse(canonical),
            idempotencyKey: "canonical-second"
        )

        let workouts = try await store.workouts()
        let workout = try XCTUnwrap(workouts.first)
        XCTAssertEqual(
            workout.startDate.timeIntervalSince1970,
            try date("2026-01-01T10:00:00.123Z").timeIntervalSince1970,
            accuracy: 0.002
        )
        let workoutEnd = try XCTUnwrap(workout.endDate)
        XCTAssertEqual(
            workoutEnd.timeIntervalSince1970,
            try date("2026-01-01T11:00:00.987Z").timeIntervalSince1970,
            accuracy: 0.002
        )
        XCTAssertEqual(workout.activityType, 37)
        XCTAssertEqual(workout.duration, 3_599.75)
        XCTAssertEqual(workout.sourceName, "Apple Watch")
        let compatibilitySamples = try await store.samples(type: "workout")
        let canonicalSamples = try await store.samples(
            type: "HKWorkoutTypeIdentifier"
        )
        XCTAssertTrue(compatibilitySamples.isEmpty)
        XCTAssertEqual(canonicalSamples.map(\.id), ["compatibility-first"])
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 1)
    }

    func testWorkoutDeletionRemovesAllWorkoutOwnedRows() async throws {
        let store = try makeStore()
        let start = try date("2026-01-01T10:00:00.000Z")
        let end = try date("2026-01-01T11:00:00.000Z")
        let statistic = ReceivedWorkoutDetail.Statistic(
            type: "heart-rate",
            unit: "count/min",
            sum: nil,
            average: 150,
            minimum: 120,
            maximum: 180
        )
        let detail = ReceivedWorkoutDetail(
            id: "workout-delete",
            startDate: start,
            endDate: end,
            activityType: 37,
            duration: 3_600,
            sourceName: "Watch",
            statistics: [statistic],
            activities: [
                .init(
                    id: "workout-leg",
                    activityType: 37,
                    startDate: start,
                    endDate: end,
                    statistics: [statistic]
                )
            ]
        )
        _ = try await store.ingest(
            ParsedBatch(
                records: [
                    HealthRecord(
                        id: "workout-delete",
                        type: "workout",
                        kind: "workout",
                        startDate: start,
                        endDate: end,
                        value: 3_600,
                        unit: "sec",
                        raw: Data()
                    )
                ],
                deletions: [],
                workoutDetails: [detail],
                unreadableCount: 0
            ),
            idempotencyKey: "workout-live"
        )
        let beforeDeletion = try await store.workouts()
        XCTAssertEqual(beforeDeletion.count, 1)

        _ = try await store.ingest(
            ParsedBatch(
                records: [
                    HealthRecord(
                        id: "workout-delete",
                        type: "workout",
                        kind: "workout",
                        startDate: start,
                        endDate: end,
                        value: 3_600,
                        unit: "sec",
                        raw: Data()
                    )
                ],
                deletions: [
                    HealthDeletion(id: "workout-delete", type: "workout")
                ],
                workoutDetails: [detail],
                unreadableCount: 0
            ),
            idempotencyKey: "workout-delete"
        )

        let remainingWorkouts = try await store.workouts()
        let remainingSamples = try await store.samples(type: "workout")
        XCTAssertTrue(remainingWorkouts.isEmpty)
        XCTAssertTrue(remainingSamples.isEmpty)
    }

    func testDeletionsAreParsed() throws {
        let payload = Data(
            #"{"id":"gone","type":"HKQuantityTypeIdentifierStepCount","deleted":true}"#.utf8
        )

        let batch = try BatchParser.parse(payload)

        XCTAssertEqual(batch.deletions.count, 1)
        XCTAssertEqual(batch.deletions.first?.id, "gone")
    }

    // MARK: - Storage

    func testRecordsAreStoredAndCounted() async throws {
        let store = try makeStore()
        let batch = try BatchParser.parse(
            Data(
                """
                {"id":"a","type":"S","startDate":"2026-01-01T10:00:00.000Z","value":1}
                {"id":"b","type":"S","startDate":"2026-01-01T11:00:00.000Z","value":2}
                """.utf8
            )
        )

        let result = try await store.ingest(batch, idempotencyKey: "key-1")

        XCTAssertEqual(result.stored, 2)
        XCTAssertFalse(result.duplicate)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 2)
    }

    /// The phone retries a delivery it never got an answer for. Without this,
    /// every dropped connection would permanently double a day's data.
    func testTheSameBatchArrivingTwiceIsStoredOnce() async throws {
        let store = try makeStore()
        let batch = try BatchParser.parse(
            Data(#"{"id":"a","type":"S","startDate":"2026-01-01T10:00:00.000Z","value":1}"#.utf8)
        )

        _ = try await store.ingest(batch, idempotencyKey: "same-key")
        let second = try await store.ingest(batch, idempotencyKey: "same-key")

        XCTAssertTrue(second.duplicate)
        XCTAssertEqual(second.stored, 0)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 1)
    }

    /// Re-sending a corrected sample must update it, not add a second copy.
    func testResendingASampleUpdatesItInPlace() async throws {
        let store = try makeStore()
        let first = try BatchParser.parse(
            Data(#"{"id":"a","type":"S","startDate":"2026-01-01T10:00:00.000Z","value":1}"#.utf8)
        )
        let corrected = try BatchParser.parse(
            Data(#"{"id":"a","type":"S","startDate":"2026-01-01T10:00:00.000Z","value":99}"#.utf8)
        )

        _ = try await store.ingest(first, idempotencyKey: "k1")
        _ = try await store.ingest(corrected, idempotencyKey: "k2")

        let samples = try await store.samples(type: "S")
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.value, 99)
    }

    /// Health is the user's record of their own body. A receiver that only ever
    /// accumulates would keep showing data they deliberately deleted.
    func testADeletionRemovesAStoredSample() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(#"{"id":"a","type":"S","startDate":"2026-01-01T10:00:00.000Z","value":1}"#.utf8)
            ),
            idempotencyKey: "k1"
        )

        let result = try await store.ingest(
            try BatchParser.parse(Data(#"{"id":"a","type":"S","deleted":true}"#.utf8)),
            idempotencyKey: "k2"
        )

        XCTAssertEqual(result.deleted, 1)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 0)
    }

    /// The metrics shape has no sample id, so its deletions can only be matched
    /// the same way its upserts were keyed.
    func testAMetricsDeletionMatchesByTypeAndDate() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[{"name":"step_count","units":"count","data":[
                      {"date":"2026-01-01T10:00:00.000Z","qty":120}]}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "k1"
        )

        let result = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"data":{"metrics":[],"deletions":[
                      {"name":"step_count","date":"2026-01-01T10:00:00.000Z"}]}}
                    """.utf8
                )
            ),
            idempotencyKey: "k2"
        )

        XCTAssertEqual(result.deleted, 1)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 0)
    }

    // MARK: - Knowing whether it is working

    /// The question the user actually has is "is this working", and an answer
    /// that resets whenever the app relaunches cannot answer it.
    func testADeliveryIsRememberedAcrossRestarts() async throws {
        let directory = root.appending(path: "store")
        let store = try IngestStore(directory: directory)
        let when = try date("2026-05-01T10:00:00.000Z")

        try await store.noteDelivery(from: "Brandos iPhone", records: 120, at: when)
        await store.close()

        let reopened = try IngestStore(directory: directory)
        let devices = try await reopened.devices()

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.name, "Brandos iPhone")
        XCTAssertEqual(devices.first?.lastSeenAt, when)
        XCTAssertEqual(devices.first?.deliveredRecords, 120)
    }

    /// Repeated deliveries move the clock forward and accumulate, rather than
    /// each one looking like a new device.
    func testRepeatedDeliveriesUpdateTheSameDevice() async throws {
        let store = try makeStore()
        let first = try date("2026-05-01T10:00:00.000Z")
        let second = try date("2026-05-01T18:00:00.000Z")

        try await store.noteDelivery(from: "Brandos iPhone", records: 100, at: first)
        try await store.noteDelivery(from: "Brandos iPhone", records: 50, at: second)

        let devices = try await store.devices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.firstSeenAt, first, "The first sighting is kept.")
        XCTAssertEqual(devices.first?.lastSeenAt, second)
        XCTAssertEqual(devices.first?.deliveredRecords, 150)
    }

    func testDevicesComeBackMostRecentlyHeardFromFirst() async throws {
        let store = try makeStore()
        try await store.noteDelivery(
            from: "Old phone", records: 1, at: try date("2026-01-01T10:00:00.000Z")
        )
        try await store.noteDelivery(
            from: "New phone", records: 1, at: try date("2026-06-01T10:00:00.000Z")
        )

        let devices = try await store.devices()
        XCTAssertEqual(devices.map(\.name), ["New phone", "Old phone"])
    }

    // MARK: - Questions the data should be able to answer

    func testSummariesDescribeEachType() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"a","type":"Steps","startDate":"2026-01-01T10:00:00.000Z","value":10,"unit":"count"}
                    {"id":"b","type":"Steps","startDate":"2026-01-03T10:00:00.000Z","value":20,"unit":"count"}
                    {"id":"c","type":"Heart","startDate":"2026-01-02T10:00:00.000Z","value":60,"unit":"count/min"}
                    """.utf8
                )
            ),
            idempotencyKey: "k1"
        )

        let summaries = try await store.summaries()

        XCTAssertEqual(summaries.count, 2)
        let steps = try XCTUnwrap(summaries.first { $0.type == "Steps" })
        XCTAssertEqual(steps.recordCount, 2)
        XCTAssertEqual(steps.unit, "count")
        XCTAssertEqual(steps.earliest, try date("2026-01-01T10:00:00.000Z"))
        XCTAssertEqual(steps.latest, try date("2026-01-03T10:00:00.000Z"))
    }

    /// Both sum and average are reported, because which one is correct depends
    /// on the type: summing heart rate is meaningless and averaging steps
    /// understates a day. Collapsing them to one number invites a confidently
    /// wrong answer.
    func testDailyAggregationReportsSumAndAverageSeparately() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"a","type":"Steps","startDate":"2026-01-01T09:00:00.000Z","value":100}
                    {"id":"b","type":"Steps","startDate":"2026-01-01T18:00:00.000Z","value":300}
                    {"id":"c","type":"Steps","startDate":"2026-01-02T09:00:00.000Z","value":50}
                    """.utf8
                )
            ),
            idempotencyKey: "k1"
        )

        // Pinned to UTC so this asserts what it is about — that sum and average
        // are reported separately — rather than quietly also depending on the
        // zone the machine running it happens to be set to. Buckets are local
        // days, so on a machine far enough ahead of UTC the 18:00Z sample would
        // land on the 2nd and this would fail for a reason unrelated to its
        // subject. Local-day bucketing is covered directly in
        // `HealthDashboardTests`.
        let buckets = try await store.aggregate(
            type: "Steps",
            bucket: .day,
            timeZone: .gmt
        )

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].sum, 400)
        XCTAssertEqual(buckets[0].average, 200)
        XCTAssertEqual(buckets[0].minimum, 100)
        XCTAssertEqual(buckets[0].maximum, 300)
        XCTAssertEqual(buckets[0].count, 2)
        XCTAssertEqual(buckets[1].sum, 50)
    }

    func testAggregationCanBeBoundedByDate() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"a","type":"Steps","startDate":"2026-01-01T09:00:00.000Z","value":100}
                    {"id":"b","type":"Steps","startDate":"2026-02-01T09:00:00.000Z","value":300}
                    """.utf8
                )
            ),
            idempotencyKey: "k1"
        )

        let buckets = try await store.aggregate(
            type: "Steps",
            bucket: .day,
            from: try date("2026-01-15T00:00:00.000Z"),
            timeZone: .gmt
        )

        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].sum, 300)
    }

    func testSamplesComeBackNewestFirst() async throws {
        let store = try makeStore()
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"old","type":"S","startDate":"2026-01-01T09:00:00.000Z","value":1}
                    {"id":"new","type":"S","startDate":"2026-06-01T09:00:00.000Z","value":2}
                    """.utf8
                )
            ),
            idempotencyKey: "k1"
        )

        let samples = try await store.samples(type: "S")

        XCTAssertEqual(samples.map(\.id), ["new", "old"])
    }
}
