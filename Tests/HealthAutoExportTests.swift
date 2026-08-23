import Foundation
@testable import HozzDeliver
import XCTest

/// Covers the opt-in schema that matches another exporter's field names, and
/// the guarantee that turning it on is the only thing that changes anything.
final class HealthAutoExportTests: XCTestCase {
    private let timeZone = TimeZone(secondsFromGMT: -8 * 3_600)!

    private func record(
        type: String = "HKQuantityTypeIdentifierStepCount",
        kind: String = "quantity",
        value: Double? = 8_500,
        unit: String? = "count",
        source: String? = "iPhone",
        start: String = "2026-02-06T22:30:00.000Z",
        end: String? = nil,
        identifier: String = "abc-123",
        duration: Double? = nil,
        activityType: Int? = nil,
        isDeletion: Bool = false
    ) -> CompatiblePayloadBuilder.Record {
        CompatiblePayloadBuilder.Record(
            identifier: identifier,
            typeIdentifier: type,
            kind: kind,
            startDate: start,
            endDate: end ?? start,
            value: value,
            unit: unit,
            sourceName: source,
            duration: duration,
            activityType: activityType,
            isDeletion: isDeletion
        )
    }

    private func build(
        _ records: [CompatiblePayloadBuilder.Record]
    ) throws -> [String: Any] {
        let data = try HealthAutoExportPayloadBuilder.build(
            records: records,
            timeZone: timeZone
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func metrics(
        _ records: [CompatiblePayloadBuilder.Record]
    ) throws -> [[String: Any]] {
        let object = try build(records)
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        return try XCTUnwrap(data["metrics"] as? [[String: Any]])
    }

    private func firstPoint(
        _ records: [CompatiblePayloadBuilder.Record]
    ) throws -> [String: Any] {
        let metric = try XCTUnwrap(try metrics(records).first)
        return try XCTUnwrap((metric["data"] as? [[String: Any]])?.first)
    }

    // MARK: - Envelope

    func testTheEnvelopeIsDataThenMetrics() throws {
        let object = try build([record()])
        let data = try XCTUnwrap(object["data"] as? [String: Any])

        XCTAssertEqual(Array(object.keys), ["data"])
        XCTAssertNotNil(data["metrics"])
    }

    func testAMetricCarriesItsNameUnitsAndPoints() throws {
        let metric = try XCTUnwrap(try metrics([record()]).first)

        XCTAssertEqual(metric["name"] as? String, "step_count")
        XCTAssertEqual(metric["units"] as? String, "count")
        XCTAssertEqual((metric["data"] as? [[String: Any]])?.count, 1)
    }

    // MARK: - Dates

    /// Their format is local time with a numeric offset, and deliberately not
    /// ISO 8601. A consumer's parser fails on the very first point otherwise.
    func testDatesUseTheirLocalTimeFormatRatherThanISO8601() throws {
        let point = try firstPoint([record()])
        let date = try XCTUnwrap(point["date"] as? String)

        XCTAssertEqual(date, "2026-02-06 14:30:00 -0800")
        XCTAssertFalse(date.contains("T"))
        XCTAssertFalse(date.hasSuffix("Z"))
    }

    func testAnUnparseableDateIsPassedThroughRatherThanInvented() throws {
        let point = try firstPoint([record(start: "not a date")])
        XCTAssertEqual(point["date"] as? String, "not a date")
    }

    // MARK: - Point shapes

    func testAnOrdinaryPointCarriesQtyAndSource() throws {
        let point = try firstPoint([record()])

        XCTAssertEqual(point["qty"] as? Double, 8_500)
        XCTAssertEqual(point["source"] as? String, "iPhone")
        XCTAssertNil(point["Avg"])
    }

    /// Their heart rate points carry a range, with capitalised keys, and no
    /// `qty` at all.
    func testAHeartRatePointUsesTheCapitalisedRangeKeys() throws {
        let point = try firstPoint([
            record(
                type: "HKQuantityTypeIdentifierHeartRate",
                value: 62,
                unit: "count/min"
            )
        ])

        XCTAssertEqual(point["Min"] as? Double, 62)
        XCTAssertEqual(point["Avg"] as? Double, 62)
        XCTAssertEqual(point["Max"] as? Double, 62)
        XCTAssertNil(point["qty"], "Their heart rate points have no qty.")
    }

    func testHeartRateUnitsAreTranslatedToTheirSpelling() throws {
        let metric = try XCTUnwrap(
            try metrics([
                record(
                    type: "HKQuantityTypeIdentifierHeartRate",
                    value: 62,
                    unit: "count/min"
                )
            ]).first
        )
        XCTAssertEqual(metric["units"] as? String, "bpm")
    }

    func testAnUndocumentedUnitIsPassedThroughRatherThanInvented() throws {
        let metric = try XCTUnwrap(
            try metrics([
                record(
                    type: "HKQuantityTypeIdentifierDistanceWalkingRunning",
                    value: 3.2,
                    unit: "km"
                )
            ]).first
        )
        XCTAssertEqual(metric["units"] as? String, "km")
    }

    // MARK: - Sleep

    func testASleepSegmentUsesTheirUnaggregatedShape() throws {
        let metric = try XCTUnwrap(
            try metrics([
                record(
                    type: "HKCategoryTypeIdentifierSleepAnalysis",
                    kind: "category",
                    value: 3,
                    unit: nil,
                    start: "2026-02-06T07:00:00.000Z",
                    end: "2026-02-06T08:30:00.000Z"
                )
            ]).first
        )
        let point = try XCTUnwrap((metric["data"] as? [[String: Any]])?.first)

        XCTAssertEqual(metric["units"] as? String, "hr")
        XCTAssertEqual(point["startDate"] as? String, "2026-02-05 23:00:00 -0800")
        XCTAssertEqual(point["endDate"] as? String, "2026-02-06 00:30:00 -0800")
        XCTAssertEqual(point["qty"] as? Double, 1.5, "Their sleep quantities are hours.")
        XCTAssertEqual(point["value"] as? String, "Core")
        XCTAssertNil(point["date"], "Their unaggregated sleep points have no date key.")
    }

    func testEverySleepStageHasTheirName() {
        let expected = [
            0: "In Bed",
            1: "Asleep",
            2: "Awake",
            3: "Core",
            4: "Deep",
            5: "REM"
        ]
        for (rawValue, name) in expected {
            XCTAssertEqual(HealthAutoExportPayloadBuilder.sleepStage(rawValue), name)
        }
        XCTAssertEqual(
            HealthAutoExportPayloadBuilder.sleepStage(99),
            "Unspecified",
            "A stage this build has no name for is still reported honestly."
        )
    }

    // MARK: - Workouts

    func testAWorkoutUsesTheirRequiredFields() throws {
        let object = try build([
            record(
                type: "HKWorkoutTypeIdentifier",
                kind: "workout",
                value: nil,
                unit: nil,
                start: "2026-02-06T15:00:00.000Z",
                end: "2026-02-06T15:30:00.000Z",
                identifier: "workout-1",
                duration: 1_800,
                activityType: 37
            )
        ])
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        let workout = try XCTUnwrap((data["workouts"] as? [[String: Any]])?.first)

        XCTAssertEqual(workout["id"] as? String, "workout-1")
        XCTAssertEqual(workout["name"] as? String, "Running")
        XCTAssertEqual(workout["start"] as? String, "2026-02-06 07:00:00 -0800")
        XCTAssertEqual(workout["end"] as? String, "2026-02-06 07:30:00 -0800")
        XCTAssertEqual(workout["duration"] as? Double, 1_800, "Their durations are seconds.")
    }

    func testAnUnknownActivityIsLabelledHonestlyRatherThanGuessed() {
        XCTAssertEqual(WorkoutActivityNames.label(for: 37), "Running")
        XCTAssertNil(WorkoutActivityNames.name(for: 9_999))
        XCTAssertEqual(WorkoutActivityNames.label(for: 9_999), "Activity 9999")
    }

    // MARK: - Deletions

    /// Their format has no tombstone. Dropping ours to match would leave a
    /// receiver showing data the user deliberately removed.
    func testDeletionsAreCarriedEvenThoughTheirFormatHasNoPlaceForThem() throws {
        let object = try build([
            record(value: nil, unit: nil, identifier: "gone-1", isDeletion: true)
        ])
        let data = try XCTUnwrap(object["data"] as? [String: Any])
        let deletion = try XCTUnwrap((data["deletions"] as? [[String: Any]])?.first)

        XCTAssertEqual(deletion["id"] as? String, "gone-1")
        XCTAssertEqual(deletion["name"] as? String, "step_count")
    }

    // MARK: - Opting in

    func testHozzsOwnSchemaIsTheDefault() {
        XCTAssertEqual(Destination(name: "X", kind: .restAPI).payloadSchema, .hozz)
        for preset in DestinationPreset.allCases {
            XCTAssertEqual(
                preset.makeDestination().payloadSchema,
                .hozz,
                "\(preset.displayName) must not opt anyone in by default."
            )
        }
    }

    /// The compatibility mode only means anything for the grouped shape. The
    /// record-per-line formats are Hozz's own and have nothing to match.
    func testTheCompatibilityModeOnlyAppliesWhereItCouldMeanAnything() {
        XCTAssertTrue(PayloadSchema.applies(to: .metrics))
        XCTAssertFalse(PayloadSchema.applies(to: .ndjson))
        XCTAssertFalse(PayloadSchema.applies(to: .json))
        XCTAssertFalse(PayloadSchema.applies(to: .csv))
        XCTAssertFalse(PayloadSchema.applies(to: .influx))
    }

    func testTheTwoSchemasReallyDoDiffer() throws {
        let records = [
            record(type: "HKQuantityTypeIdentifierHeartRate", value: 62, unit: "count/min")
        ]
        let hozz = try CompatiblePayloadBuilder.build(records: records)
        let compatible = try HealthAutoExportPayloadBuilder.build(
            records: records,
            timeZone: timeZone
        )

        XCTAssertNotEqual(hozz, compatible)
        XCTAssertTrue(String(decoding: hozz, as: UTF8.self).contains("\"qty\""))
        XCTAssertTrue(String(decoding: compatible, as: UTF8.self).contains("\"Avg\""))
    }

    func testTheChosenSchemaSurvivesBeingSaved() throws {
        var destination = Destination(name: "Home Assistant", kind: .restAPI, format: .metrics)
        destination.payloadSchema = .healthAutoExport

        let decoded = try JSONDecoder().decode(
            Destination.self,
            from: JSONEncoder().encode(destination)
        )
        XCTAssertEqual(decoded.payloadSchema, .healthAutoExport)
    }

    // MARK: - Not losing destinations

    /// Destinations are loaded with `try?`, so a decoder that throws on a key
    /// added later would empty somebody's destination list on upgrade and
    /// silently stop every automatic export they had set up.
    func testADestinationSavedByAnEarlierBuildStillLoads() throws {
        let older = Data(
            """
            {
              "id": "8B2E7F6A-1C2D-4E5F-9A0B-1C2D3E4F5A6B",
              "name": "My computer",
              "kind": "restAPI",
              "format": "metrics",
              "cadence": "hourly",
              "isEnabled": true,
              "headers": {"topic": "hozz"},
              "authorizationHeader": "Authorization",
              "includedTypes": [],
              "createdAt": 760000000
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(Destination.self, from: older)

        XCTAssertEqual(decoded.name, "My computer")
        XCTAssertEqual(decoded.format, .metrics)
        XCTAssertEqual(decoded.cadence, .hourly)
        XCTAssertEqual(decoded.headers["topic"], "hozz")
        XCTAssertEqual(decoded.payloadSchema, .hozz, "A field it never had defaults.")
        XCTAssertTrue(decoded.options.isEmpty)
    }

    func testADestinationRoundTripsWithEverythingSet() throws {
        var destination = DestinationPreset.influxDB.makeDestination()
        destination.payloadSchema = .healthAutoExport
        destination.headers = ["X-Thing": "1"]
        destination.includedTypes = []
        destination.endpointURL = URL(string: "http://influx.local:8086/api/v2/write")

        let decoded = try JSONDecoder().decode(
            Destination.self,
            from: JSONEncoder().encode(destination)
        )
        XCTAssertEqual(decoded, destination)
    }
}
