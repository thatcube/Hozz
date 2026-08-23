import Foundation
@testable import HozzDeliver
import HozzStore
import XCTest

/// A strict reader for InfluxDB line protocol.
///
/// The tests parse Hozz's output back rather than comparing it to a hand-typed
/// string. A literal expectation only proves the bytes did not change; parsing
/// proves the escaping is *reversible*, which is the property InfluxDB actually
/// relies on. A tag that comes back different from the one that went in is a
/// value the user's dashboard will group wrongly forever.
struct ParsedLine {
    var measurement: String
    var tags: [String: String]
    var fields: [String: String]
    var timestamp: Int64?

    /// Splits on `separators` at unescaped positions, leaving the escapes in
    /// place. Unescaping happens exactly once, in `unescape`, because doing it
    /// twice quietly eats every backslash the data legitimately contained.
    private static func split(
        _ input: [Character],
        on separators: Set<Character>,
        limit: Int? = nil
    ) -> [String] {
        var parts: [String] = []
        var current = ""
        var index = 0
        while index < input.count {
            let character = input[index]
            if character == "\\", index + 1 < input.count {
                current.append(character)
                current.append(input[index + 1])
                index += 2
                continue
            }
            if separators.contains(character),
               limit.map({ parts.count < $0 }) ?? true {
                parts.append(current)
                current = ""
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }
        parts.append(current)
        return parts
    }

    /// InfluxDB reads a backslash as an escape for the character that follows.
    static func unescape(_ value: String) -> String {
        var result = ""
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                result.append(characters[index + 1])
                index += 2
                continue
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    /// Returns nil for anything InfluxDB would reject.
    static func parse(_ line: String) -> ParsedLine? {
        guard !line.isEmpty, !line.contains("\n") else {
            return nil
        }
        let characters = Array(line)

        // Line protocol is: <measurement+tags> <fields> [timestamp], where the
        // separators are unescaped spaces.
        var sections: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                current.append(character)
                current.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "\"" {
                // A quoted string field may contain unescaped spaces.
                current.append(character)
                index += 1
                while index < characters.count {
                    if characters[index] == "\\", index + 1 < characters.count {
                        current.append(characters[index])
                        current.append(characters[index + 1])
                        index += 2
                        continue
                    }
                    current.append(characters[index])
                    if characters[index] == "\"" {
                        index += 1
                        break
                    }
                    index += 1
                }
                continue
            }
            if character == " " {
                sections.append(current)
                current = ""
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }
        sections.append(current)

        guard sections.count == 2 || sections.count == 3 else {
            return nil
        }

        let head = split(Array(sections[0]), on: [","])
        guard let rawMeasurement = head.first, !rawMeasurement.isEmpty else {
            return nil
        }
        let measurement = unescape(rawMeasurement)
        guard !measurement.hasPrefix("#"), !measurement.hasPrefix("_") else {
            // A leading hash makes InfluxDB read the line as a comment and
            // throw it away without saying so.
            return nil
        }

        var tags: [String: String] = [:]
        for entry in head.dropFirst() {
            let pair = split(Array(entry), on: ["="], limit: 1)
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else {
                return nil
            }
            let key = unescape(pair[0])
            guard !key.hasPrefix("_"), tags[key] == nil else {
                return nil
            }
            tags[key] = unescape(pair[1])
        }

        var fields: [String: String] = [:]
        for entry in splitFields(sections[1]) {
            guard let pair = splitFieldEntry(entry) else {
                return nil
            }
            fields[pair.key] = pair.value
        }
        guard !fields.isEmpty else {
            return nil
        }

        var timestamp: Int64?
        if sections.count == 3 {
            guard let parsed = Int64(sections[2]) else {
                return nil
            }
            timestamp = parsed
        }

        return ParsedLine(
            measurement: measurement,
            tags: tags,
            fields: fields,
            timestamp: timestamp
        )
    }

    /// Splits one `key=value` on the first unescaped equals, unescaping the key
    /// but leaving the value exactly as it was written. A string value is
    /// unescaped later by `unquote`; a number has nothing to unescape.
    private static func splitFieldEntry(_ entry: String) -> (key: String, value: String)? {
        let characters = Array(entry)
        var key = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                key.append(characters[index])
                key.append(characters[index + 1])
                index += 2
                continue
            }
            if characters[index] == "=" {
                let value = String(characters[(index + 1)...])
                guard !key.isEmpty, !value.isEmpty else {
                    return nil
                }
                return (unescape(key), value)
            }
            key.append(characters[index])
            index += 1
        }
        return nil
    }

    /// Splits a field set on commas that are outside a quoted string.
    private static func splitFields(_ input: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var index = 0
        let characters = Array(input)
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                current.append(character)
                current.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "\"" {
                quoted.toggle()
            }
            if character == ",", !quoted {
                parts.append(current)
                current = ""
                index += 1
                continue
            }
            current.append(character)
            index += 1
        }
        parts.append(current)
        return parts
    }

    /// Unwraps a quoted string field back to its original characters.
    static func unquote(_ value: String) -> String? {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else {
            return nil
        }
        let inner = Array(value.dropFirst().dropLast())
        var result = ""
        var index = 0
        while index < inner.count {
            if inner[index] == "\\", index + 1 < inner.count {
                result.append(inner[index + 1])
                index += 2
                continue
            }
            result.append(inner[index])
            index += 1
        }
        return result
    }
}

/// Rejects a whole write when any line is malformed, as InfluxDB does.
private struct LineProtocolValidatingChannel: DeliveryChannel {
    func deliver(
        _ batch: DeliveryBatch,
        to destination: Destination
    ) async throws -> DeliveryReceipt {
        let text = String(decoding: batch.payload, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty, lines.allSatisfy({ ParsedLine.parse(String($0)) != nil }) else {
            throw DeliveryError.rejected(statusCode: 400, body: nil)
        }
        return DeliveryReceipt(
            destinationID: destination.id,
            attemptedAt: .now,
            recordCount: batch.recordCount,
            byteCount: UInt64(batch.payload.count),
            state: .delivered
        )
    }
}

final class InfluxLineProtocolTests: XCTestCase {
    private let iso = "2026-08-22T21:10:46.500Z"

    private func sample(
        type: String = "HKQuantityTypeIdentifierHeartRate",
        kind: String = "quantity",
        value: Double? = 62.5,
        unit: String? = "count/min",
        source: String? = "iPhone",
        device: String? = nil,
        start: String? = nil,
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
            startDate: start ?? iso,
            endDate: end ?? start ?? iso,
            value: value,
            unit: unit,
            sourceName: source,
            deviceName: device,
            duration: duration,
            activityType: activityType,
            isDeletion: isDeletion
        )
    }

    private func lines(
        _ records: [CompatiblePayloadBuilder.Record],
        options: InfluxLineProtocol.Options = InfluxLineProtocol.Options()
    ) -> [String] {
        String(decoding: InfluxLineProtocol.build(records: records, options: options), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func parseOne(
        _ record: CompatiblePayloadBuilder.Record,
        options: InfluxLineProtocol.Options = InfluxLineProtocol.Options()
    ) throws -> ParsedLine {
        let produced = lines([record], options: options)
        XCTAssertEqual(produced.count, 1)
        return try XCTUnwrap(
            ParsedLine.parse(try XCTUnwrap(produced.first)),
            "InfluxDB would reject this line: \(produced.first ?? "")"
        )
    }

    // MARK: - Shape

    func testASampleBecomesOneLineWithTagsAndAValue() throws {
        let parsed = try parseOne(sample(device: "Apple Watch"))

        XCTAssertEqual(parsed.measurement, "health")
        XCTAssertEqual(parsed.tags["type"], "heart_rate")
        XCTAssertEqual(parsed.tags["source"], "iPhone")
        XCTAssertEqual(parsed.tags["device"], "Apple Watch")
        XCTAssertEqual(parsed.tags["unit"], "count/min")
        XCTAssertEqual(parsed.fields["value"], "62.5")
    }

    func testTheMeasurementNameIsConfigurable() throws {
        let parsed = try parseOne(
            sample(),
            options: InfluxLineProtocol.Options(measurement: "apple_health")
        )
        XCTAssertEqual(parsed.measurement, "apple_health")
    }

    func testAnEmptyMeasurementFallsBackRatherThanProducingAnInvalidLine() throws {
        let options = InfluxLineProtocol.Options(measurement: "   ")
        XCTAssertEqual(options.measurement, "health")
        let parsed = try parseOne(sample(), options: options)
        XCTAssertEqual(parsed.measurement, "health")
    }

    /// An interval sample flattened to an instant would silently lose the span
    /// it covered, which is most of what sleep and exercise data is.
    func testAnIntervalSampleKeepsItsDuration() throws {
        let parsed = try parseOne(
            sample(
                type: "HKCategoryTypeIdentifierSleepAnalysis",
                kind: "category",
                value: 3,
                unit: nil,
                start: "2026-08-22T22:00:00.000Z",
                end: "2026-08-22T22:30:00.000Z"
            )
        )
        XCTAssertEqual(parsed.fields["duration"], "1800.0")
    }

    // MARK: - Escaping

    func testASourceNameWithASpaceIsEscapedAndSurvivesTheRoundTrip() throws {
        let parsed = try parseOne(sample(source: "Apple Watch"))
        XCTAssertEqual(parsed.tags["source"], "Apple Watch")
        XCTAssertEqual(parsed.tags["type"], "heart_rate")
    }

    func testASourceNameWithACommaIsEscaped() throws {
        let parsed = try parseOne(sample(source: "Watch, Series 9"))
        XCTAssertEqual(parsed.tags["source"], "Watch, Series 9")
    }

    func testATagValueWithAnEqualsSignIsEscaped() throws {
        let parsed = try parseOne(sample(source: "app=health"))
        XCTAssertEqual(parsed.tags["source"], "app=health")
    }

    func testAMeasurementWithACommaAndASpaceIsEscaped() throws {
        let parsed = try parseOne(
            sample(),
            options: InfluxLineProtocol.Options(measurement: "my health, data")
        )
        XCTAssertEqual(parsed.measurement, "my health, data")
    }

    func testAnAwkwardTypeIdentifierStillProducesAValidTag() throws {
        let parsed = try parseOne(
            sample(type: "Custom Type, With=Everything")
        )
        // Unmapped identifiers are snake cased rather than dropped.
        XCTAssertFalse(parsed.tags["type"]?.isEmpty ?? true)
        XCTAssertEqual(parsed.fields["value"], "62.5")
    }

    func testAStringFieldWithAQuoteIsEscaped() throws {
        let parsed = try parseOne(
            sample(value: nil, unit: nil, identifier: #"the "best" watch"#)
        )
        XCTAssertEqual(
            ParsedLine.unquote(try XCTUnwrap(parsed.fields["id"])),
            #"the "best" watch"#
        )
    }

    func testAStringFieldWithABackslashIsEscaped() throws {
        let parsed = try parseOne(
            sample(value: nil, unit: nil, identifier: #"C:\Users\me"#)
        )
        XCTAssertEqual(
            ParsedLine.unquote(try XCTUnwrap(parsed.fields["id"])),
            #"C:\Users\me"#
        )
    }

    /// The case that actually corrupts a line: a trailing backslash would
    /// otherwise escape the space that separates the tags from the fields.
    func testATagValueEndingInABackslashDoesNotSwallowTheFieldSeparator() throws {
        let parsed = try parseOne(sample(source: #"Watch\"#))
        XCTAssertEqual(parsed.tags["source"], #"Watch\"#)
        XCTAssertEqual(parsed.fields["value"], "62.5")
    }

    /// InfluxDB reads two contiguous backslashes as one, so a backslash has to
    /// go out doubled to arrive as itself.
    func testAnInteriorBackslashArrivesAsOneCharacter() throws {
        let parsed = try parseOne(sample(source: #"C:\Users"#))
        XCTAssertEqual(parsed.tags["source"], #"C:\Users"#)
    }

    func testABackslashBeforeASpecialCharacterIsEscaped() throws {
        let parsed = try parseOne(sample(source: #"a\,b"#))
        XCTAssertEqual(parsed.tags["source"], #"a\,b"#)
    }

    /// Line protocol is line delimited and has no escape for a newline, so one
    /// in a source name would split the line in two and lose both halves.
    func testANewlineInATagIsFlattenedRatherThanBreakingTheLine() throws {
        let produced = lines([sample(source: "Apple\nWatch")])
        XCTAssertEqual(produced.count, 1, "A newline must not split the line.")
        let parsed = try XCTUnwrap(ParsedLine.parse(try XCTUnwrap(produced.first)))
        XCTAssertEqual(parsed.tags["source"], "Apple Watch")
    }

    func testAnEmptyTagValueIsDroppedRatherThanWritten() throws {
        let parsed = try parseOne(sample(source: ""))
        XCTAssertNil(parsed.tags["source"], "InfluxDB rejects an empty tag value.")
        XCTAssertEqual(parsed.tags["type"], "heart_rate")
    }

    // MARK: - Values

    func testANegativeValueIsWrittenAsIs() throws {
        let parsed = try parseOne(
            sample(type: "HKQuantityTypeIdentifierBodyTemperature", value: -3.5, unit: "degC")
        )
        XCTAssertEqual(parsed.fields["value"], "-3.5")
    }

    func testAFractionalValueKeepsItsPrecision() throws {
        let parsed = try parseOne(sample(value: 0.000_123_456))
        XCTAssertEqual(Double(try XCTUnwrap(parsed.fields["value"])), 0.000_123_456)
    }

    /// One NaN in a batch rejects every line that travelled with it, so it must
    /// never reach the wire as a number.
    func testANonFiniteValueNeverBecomesANumericField() throws {
        for value in [Double.nan, .infinity, -.infinity] {
            let produced = lines([sample(value: value)])
            for line in produced {
                XCTAssertFalse(line.contains("nan"), "Produced: \(line)")
                XCTAssertFalse(line.contains("inf"), "Produced: \(line)")
                let parsed = try XCTUnwrap(
                    ParsedLine.parse(line),
                    "InfluxDB would reject: \(line)"
                )
                XCTAssertNil(parsed.fields["value"])
            }
            XCTAssertFalse(produced.isEmpty, "The record must not vanish.")
        }
    }

    // MARK: - Timestamps

    func testTimestampsAreWrittenInTheDeclaredPrecision() {
        let iso = "2026-08-22T21:10:46.500Z"
        XCTAssertEqual(
            InfluxLineProtocol.timestamp(iso, precision: .seconds),
            1_787_433_046
        )
        XCTAssertEqual(
            InfluxLineProtocol.timestamp(iso, precision: .milliseconds),
            1_787_433_046_500
        )
        XCTAssertEqual(
            InfluxLineProtocol.timestamp(iso, precision: .microseconds),
            1_787_433_046_500_000
        )
        XCTAssertEqual(
            InfluxLineProtocol.timestamp(iso, precision: .nanoseconds),
            1_787_433_046_500_000_000
        )
    }

    /// Multiplying seconds-since-1970 by a billion in a `Double` rounds to
    /// roughly the nearest 256ns, which is enough to land two adjacent samples
    /// on the same point and lose one of them.
    func testMillisecondsApartStayMillisecondsApartInNanoseconds() throws {
        let first = try XCTUnwrap(
            InfluxLineProtocol.timestamp("2026-08-22T21:10:46.001Z", precision: .nanoseconds)
        )
        let second = try XCTUnwrap(
            InfluxLineProtocol.timestamp("2026-08-22T21:10:46.002Z", precision: .nanoseconds)
        )
        XCTAssertEqual(second - first, 1_000_000)
    }

    func testATimestampWithoutFractionalSecondsStillParses() {
        XCTAssertEqual(
            InfluxLineProtocol.timestamp("2026-08-22T21:10:46Z", precision: .seconds),
            1_787_433_046
        )
    }

    func testAnUnparseableTimestampLeavesTheLineValidWithoutOne() throws {
        let parsed = try parseOne(sample(start: "not a date", end: "not a date"))
        XCTAssertNil(parsed.timestamp, "InfluxDB times an undated point on arrival.")
        XCTAssertEqual(parsed.fields["value"], "62.5")
    }

    // MARK: - Records that are not plain samples

    func testAWorkoutGetsItsOwnMeasurementAndKeepsItsDuration() throws {
        let parsed = try parseOne(
            sample(
                type: "HKWorkoutTypeIdentifier",
                kind: "workout",
                value: nil,
                unit: nil,
                duration: 1_800,
                activityType: 37
            )
        )
        XCTAssertEqual(parsed.measurement, "health_workouts")
        XCTAssertEqual(parsed.tags["type"], "workout")
        XCTAssertEqual(parsed.tags["activity"], "Running")
        XCTAssertEqual(parsed.fields["duration"], "1800.0")
    }

    /// Line protocol cannot retract a point, so a tombstone that is not
    /// recorded is a fact thrown away in transit.
    func testADeletionIsRecordedRatherThanDropped() throws {
        let produced = lines([
            sample(value: nil, unit: nil, identifier: "gone-1", isDeletion: true)
        ])
        let parsed = try XCTUnwrap(ParsedLine.parse(try XCTUnwrap(produced.first)))
        XCTAssertEqual(parsed.measurement, "health_deletions")
        XCTAssertEqual(parsed.tags["id"], "gone-1")
        XCTAssertEqual(parsed.tags["type"], "heart_rate")
    }

    /// Two tombstones in one batch have no timestamps to tell them apart, so
    /// they must not land on the same series and overwrite each other.
    func testTwoDeletionsDoNotCollapseIntoOne() throws {
        let produced = lines([
            sample(value: nil, unit: nil, identifier: "gone-1", isDeletion: true),
            sample(value: nil, unit: nil, identifier: "gone-2", isDeletion: true)
        ])
        XCTAssertEqual(produced.count, 2)
        let ids = try produced.map {
            try XCTUnwrap(ParsedLine.parse($0)?.tags["id"])
        }
        XCTAssertEqual(Set(ids), ["gone-1", "gone-2"])
    }

    func testARecordWithNoNumberIsStillCarried() throws {
        let parsed = try parseOne(
            sample(type: "HKCorrelationTypeIdentifierBloodPressure", kind: "correlation", value: nil, unit: nil)
        )
        XCTAssertEqual(parsed.measurement, "health_events")
        XCTAssertEqual(ParsedLine.unquote(try XCTUnwrap(parsed.fields["id"])), "abc-123")
    }

    // MARK: - The batch as a whole

    /// The property that matters: whatever Health hands over, every line Hozz
    /// writes is one InfluxDB will accept. A single bad line rejects the write
    /// and takes the whole batch with it.
    func testEveryLineOfAnUnpleasantBatchIsAcceptable() throws {
        let nasty = [
            sample(source: "Watch, Series 9 = \"Ultra\"\\"),
            sample(source: "line\nbreak", device: "tab\there"),
            sample(type: "HK Quantity, Type=Weird", unit: "kg m,s"),
            sample(value: .nan),
            sample(value: -0.0),
            sample(value: 1e21),
            sample(value: nil, unit: nil, identifier: #"quote" and \slash"#),
            sample(kind: "workout", value: nil, unit: nil, duration: 60, activityType: 999),
            sample(value: nil, unit: nil, identifier: "deleted", isDeletion: true),
            sample(source: nil, device: nil, identifier: "")
        ]
        let produced = lines(nasty)
        XCTAssertFalse(produced.isEmpty)
        for line in produced {
            XCTAssertNotNil(
                ParsedLine.parse(line),
                "InfluxDB would reject this line and lose the whole batch: \(line)"
            )
        }
    }

    /// The examples in `docs/delivery-schema.md`, asserted verbatim.
    ///
    /// Documentation that describes what the code used to do is worse than no
    /// documentation, because someone builds against it.
    func testTheDocumentedExamplesAreWhatIsActuallyWritten() {
        let records = [
            sample(
                source: "Apple Watch",
                device: "Apple Watch",
                start: "2026-08-22T21:10:46.500Z"
            ),
            sample(
                type: "HKCategoryTypeIdentifierSleepAnalysis",
                kind: "category",
                value: 3,
                unit: nil,
                source: "Apple Watch",
                start: "2026-08-22T22:00:00.000Z",
                end: "2026-08-22T22:30:00.000Z"
            ),
            sample(
                type: "HKWorkoutTypeIdentifier",
                kind: "workout",
                value: nil,
                unit: nil,
                source: "Apple Watch",
                start: "2026-08-22T07:00:00.000Z",
                end: "2026-08-22T07:30:00.000Z",
                identifier: "7b21c0de-0000-4000-8000-000000000001",
                duration: 1_800,
                activityType: 37
            ),
            sample(
                type: "HKQuantityTypeIdentifierStepCount",
                value: nil,
                unit: nil,
                source: nil,
                start: "",
                end: "",
                identifier: "9c40c0de-0000-4000-8000-000000000002",
                isDeletion: true
            )
        ]

        XCTAssertEqual(
            lines(records),
            [
                #"health,type=heart_rate,source=Apple\ Watch,device=Apple\ Watch,unit=count/min value=62.5 1787433046500000000"#,
                #"health,type=sleep_analysis,source=Apple\ Watch value=3.0,duration=1800.0 1787436000000000000"#,
                #"health_workouts,type=workout,activity=Running,source=Apple\ Watch duration=1800.0,id="7b21c0de-0000-4000-8000-000000000001" 1787382000000000000"#,
                "health_deletions,type=step_count,id=9c40c0de-0000-4000-8000-000000000002 deleted=true"
            ]
        )
    }

    // MARK: - The seam

    /// A destination that rejects a batch must never look like a success.
    ///
    /// This is the failure worth guarding: two correct pieces of work either
    /// side of a boundary, and nobody owning the join, so records go missing in
    /// transit while the interface says everything is fine. The channel here
    /// validates line protocol the way InfluxDB does — reject the whole write
    /// if any line is malformed — and the engine has to record that as
    /// something needing attention, not as a delivery.
    func testAnUnacceptablePayloadIsNeverRecordedAsDelivered() async throws {
        let directory = try TemporaryDirectory()
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = LineProtocolValidatingChannel()
        let engine = DeliveryEngine(store: store, channels: [.restAPI: channel])
        var destination = DestinationPreset.influxDB.makeDestination()
        destination.endpointURL = URL(string: "http://influx.local:8086/api/v2/write")
        try await engine.save(destination)

        let malformed = DeliveryBatch(
            id: UUID(),
            sequence: 0,
            createdAt: .now,
            recordCount: 1,
            payload: Data("health,type=heart_rate value=\n".utf8),
            format: .influx
        )
        _ = try? await engine.deliver(malformed, to: destination)

        let state = try await engine.state(for: destination.id)
        XCTAssertNotEqual(state?.state, DeliveryState.delivered.rawValue)
        XCTAssertEqual(state?.deliveredRecords, 0, "Nothing arrived, so nothing counts.")
        let receipts = try await engine.receipts(for: destination.id)
        XCTAssertNotNil(receipts.first?.detail, "The user has to be told why.")
    }

    /// The other half of the same seam: what Hozz actually produces has to get
    /// through that same validation.
    func testWhatHozzProducesPassesTheValidationThatRejectedTheMalformedBatch() async throws {
        let directory = try TemporaryDirectory()
        let store = try HozzStore(directory: directory.url.appending(path: "store"))
        let channel = LineProtocolValidatingChannel()
        let engine = DeliveryEngine(store: store, channels: [.restAPI: channel])
        var destination = DestinationPreset.influxDB.makeDestination()
        destination.endpointURL = URL(string: "http://influx.local:8086/api/v2/write")
        try await engine.save(destination)

        let payload = InfluxLineProtocol.build(
            records: [
                sample(source: "Watch, Series 9 = \"Ultra\"\\"),
                sample(value: .nan),
                sample(kind: "workout", value: nil, unit: nil, duration: 60, activityType: 37),
                sample(value: nil, unit: nil, identifier: "deleted", isDeletion: true)
            ],
            options: destination.influxOptions
        )
        let batch = DeliveryBatch(
            id: DeliveryBatch.identifier(for: payload),
            sequence: 0,
            createdAt: .now,
            recordCount: 4,
            payload: payload,
            format: .influx
        )

        _ = try await engine.deliver(batch, to: destination)

        let state = try await engine.state(for: destination.id)
        XCTAssertEqual(state?.state, DeliveryState.delivered.rawValue)
        XCTAssertEqual(state?.deliveredRecords, 4)
    }

    func testTheSameRecordsAlwaysProduceTheSameBytes() {
        let records = [sample(), sample(source: "Apple Watch"), sample(value: nil, unit: nil)]
        XCTAssertEqual(
            InfluxLineProtocol.build(records: records),
            InfluxLineProtocol.build(records: records),
            "The batch identifier is derived from these bytes."
        )
    }

    // MARK: - The probe

    func testTheConnectionProbeIsValidLineProtocol() throws {
        let destination = Destination(
            name: "InfluxDB",
            kind: .restAPI,
            format: .influx,
            endpointURL: URL(string: "http://influx.local:8086/api/v2/write")
        )
        let payload = DeliveryProbe.payload(for: destination)
        let text = String(decoding: payload, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = try XCTUnwrap(
            ParsedLine.parse(text),
            "InfluxDB would reject the connection test itself: \(text)"
        )
        XCTAssertEqual(parsed.measurement, "health_events")
        XCTAssertEqual(parsed.tags["type"], "hozz_connection_test")
    }

    /// A JSON probe sent to InfluxDB is rejected, which would report a working
    /// database as broken.
    func testTheProbeFollowsTheFormatRatherThanAlwaysBeingJSON() {
        var destination = Destination(name: "Endpoint", kind: .restAPI, format: .ndjson)
        XCTAssertTrue(
            String(decoding: DeliveryProbe.payload(for: destination), as: UTF8.self)
                .hasPrefix("{")
        )
        destination.format = .influx
        XCTAssertFalse(
            String(decoding: DeliveryProbe.payload(for: destination), as: UTF8.self)
                .hasPrefix("{")
        )
    }

    // MARK: - Where the format is offered

    /// Hozz's own Mac app watches a folder for ndjson, json, and csv and
    /// ignores anything else. Offering line protocol there would let someone
    /// build a destination that looks like it works and delivers nothing.
    func testLineProtocolIsNotOfferedForFolders() {
        XCTAssertFalse(DeliveryFormat.available(for: .folder).contains(.influx))
        XCTAssertTrue(DeliveryFormat.available(for: .restAPI).contains(.influx))
        XCTAssertTrue(DeliveryFormat.available(for: .mqtt).contains(.influx))
    }

    /// A precision in the address that disagrees with the one Hozz writes is
    /// not an error InfluxDB reports. It accepts the write and files every
    /// point in the wrong decade, so the disagreement has to be found here.
    func testThePrecisionDeclaredInTheAddressIsReadBack() {
        XCTAssertEqual(
            InfluxLineProtocol.declaredPrecision(
                in: URL(string: "http://h:8086/api/v2/write?org=a&bucket=b&precision=ms")
            ),
            .milliseconds
        )
        XCTAssertEqual(
            InfluxLineProtocol.declaredPrecision(
                in: URL(string: "http://h:8086/write?db=health&precision=s")
            ),
            .seconds
        )
        XCTAssertNil(
            InfluxLineProtocol.declaredPrecision(
                in: URL(string: "http://h:8086/api/v2/write?org=a&bucket=b")
            ),
            "No declaration is not a disagreement."
        )
        XCTAssertNil(
            InfluxLineProtocol.declaredPrecision(
                in: URL(string: "http://h:8086/api/v2/write?precision=fortnights")
            ),
            "A precision InfluxDB would not accept is not one to match."
        )
        XCTAssertNil(InfluxLineProtocol.declaredPrecision(in: nil))
    }

    func testTheInfluxPresetIsReachableAndConfigured() {
        let destination = DestinationPreset.influxDB.makeDestination()
        XCTAssertEqual(destination.format, .influx)
        XCTAssertEqual(destination.kind, .restAPI)
        XCTAssertEqual(destination.influxOptions.measurement, "health")
        XCTAssertEqual(destination.influxOptions.precision, .nanoseconds)
        XCTAssertTrue(DestinationPreset.allCases.contains(.influxDB))
    }

    func testTheMeasurementAndPrecisionSurviveBeingSaved() throws {
        var destination = DestinationPreset.influxDB.makeDestination()
        destination.options[Destination.measurementKey] = "apple_health"
        destination.options[Destination.precisionKey] = "ms"

        let decoded = try JSONDecoder().decode(
            Destination.self,
            from: JSONEncoder().encode(destination)
        )

        XCTAssertEqual(decoded.influxOptions.measurement, "apple_health")
        XCTAssertEqual(decoded.influxOptions.precision, .milliseconds)
    }
}
