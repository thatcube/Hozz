import Foundation

/// Encodes a batch as InfluxDB line protocol.
///
/// This exists because the alternative was making people run a translator. The
/// common self-hosted setup is Health data in InfluxDB, charted in Grafana, and
/// until now that meant deploying a container whose entire job was turning an
/// exporter's JSON into the format InfluxDB already wanted. Emitting line
/// protocol directly deletes that step.
///
/// The escaping below is the whole point of the file. InfluxDB rejects a
/// malformed line, a rejected write takes the rest of the batch with it, and a
/// rejected batch is data the user does not get. The rules differ by position —
/// what has to be escaped in a measurement is not what has to be escaped in a
/// tag, which is not what has to be escaped in a string field — so they are
/// implemented as three separate functions rather than one shared one.
public enum InfluxLineProtocol {
    /// The timestamp precision written into the lines.
    ///
    /// This must match the `precision` parameter on the write request.
    /// InfluxDB defaults to nanoseconds, and a mismatch does not fail: it
    /// silently files every point in 1970 or in the far future.
    public enum Precision: String, Codable, CaseIterable, Sendable {
        case nanoseconds = "ns"
        case microseconds = "us"
        case milliseconds = "ms"
        case seconds = "s"

        public var displayName: String {
            switch self {
            case .nanoseconds:
                "Nanoseconds (ns)"
            case .microseconds:
                "Microseconds (us)"
            case .milliseconds:
                "Milliseconds (ms)"
            case .seconds:
                "Seconds (s)"
            }
        }

        /// Nanoseconds per unit of this precision.
        var nanosecondsPerUnit: Int64 {
            switch self {
            case .nanoseconds:
                1
            case .microseconds:
                1_000
            case .milliseconds:
                1_000_000
            case .seconds:
                1_000_000_000
            }
        }
    }

    public struct Options: Sendable, Equatable {
        /// The InfluxDB measurement samples are written to.
        public var measurement: String
        public var precision: Precision

        public init(
            measurement: String = InfluxLineProtocol.defaultMeasurement,
            precision: Precision = .nanoseconds
        ) {
            let trimmed = measurement.trimmingCharacters(in: .whitespacesAndNewlines)
            self.measurement = trimmed.isEmpty
                ? InfluxLineProtocol.defaultMeasurement
                : trimmed
            self.precision = precision
        }
    }

    public static let defaultMeasurement = "health"

    /// The precision declared in a write URL, when it declares one.
    ///
    /// InfluxDB does not report a mismatch between the precision in the
    /// address and the precision of the timestamps it is sent. It just files
    /// every point in the wrong decade, and the user finds out when a Grafana
    /// panel is empty. Reading it back out of the address is what lets Hozz say
    /// so before that happens.
    public static func declaredPrecision(in url: URL?) -> Precision? {
        guard
            let url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        return components.queryItems?
            .last { $0.name == "precision" }?
            .value
            .flatMap(Precision.init(rawValue:))
    }

    /// Suffix for workouts, which carry a duration rather than a measurement.
    public static let workoutSuffix = "_workouts"
    /// Suffix for records that have no numeric value at all.
    public static let eventSuffix = "_events"
    /// Suffix for tombstones.
    ///
    /// Line protocol cannot retract a point, so a deletion cannot be applied.
    /// Recording it in its own measurement is the difference between the user
    /// being able to reconcile later and the fact being thrown away in transit.
    public static let deletionSuffix = "_deletions"

    // MARK: - Building

    /// One line that says only that Hozz reached this database.
    ///
    /// A connection test has to be written in the destination's own format.
    /// InfluxDB rejects JSON, so a JSON probe would report a correctly
    /// configured database as broken.
    public static func probe(options: Options, at date: Date = .now) -> Data {
        let iso = Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
        let line = compose(
            measurement: options.measurement + eventSuffix,
            tags: [("type", "hozz_connection_test")],
            fields: [("value", .double(1))],
            timestamp: timestamp(iso, precision: options.precision)
        )
        guard let line else {
            return Data()
        }
        return Data((line + "\n").utf8)
    }

    public static func build(
        records: [CompatiblePayloadBuilder.Record],
        options: Options = Options()
    ) -> Data {
        var payload = Data()
        for record in records {
            guard let line = line(for: record, options: options) else {
                continue
            }
            payload.append(Data(line.utf8))
            payload.append(0x0A)
        }
        return payload
    }

    public static func canRepresent(
        _ record: CompatiblePayloadBuilder.Record,
        options: Options = Options()
    ) -> Bool {
        line(for: record, options: options) != nil
    }

    /// One line, or nil when the record cannot be represented at all.
    ///
    /// The only records that return nil are ones with no timestamp *and* no
    /// identifier, which would produce a line InfluxDB rejects.
    static func line(
        for record: CompatiblePayloadBuilder.Record,
        options: Options
    ) -> String? {
        if record.isDeletion {
            return deletionLine(for: record, options: options)
        }
        if record.kind == "workout" {
            return workoutLine(for: record, options: options)
        }
        if record.value != nil {
            return sampleLine(for: record, options: options)
        }
        return eventLine(for: record, options: options)
    }

    private static func sampleLine(
        for record: CompatiblePayloadBuilder.Record,
        options: Options
    ) -> String? {
        guard let value = record.value, value.isFinite else {
            // A NaN or an infinity is not a number InfluxDB accepts, and one of
            // them in a batch rejects every line that travelled with it.
            return eventLine(for: record, options: options)
        }

        var tags = baseTags(for: record)
        if let unit = record.unit {
            tags.append(("unit", unit))
        }

        var fields: [(String, FieldValue)] = [("value", .double(value))]
        if let duration = intervalSeconds(for: record) {
            // An interval sample narrowed to a point loses the fact that it
            // covered a span. Sleep and workouts are almost entirely intervals.
            fields.append(("duration", .double(duration)))
        }

        return compose(
            measurement: options.measurement,
            tags: tags,
            fields: fields,
            timestamp: timestamp(record.startDate, precision: options.precision)
        )
    }

    private static func workoutLine(
        for record: CompatiblePayloadBuilder.Record,
        options: Options
    ) -> String? {
        var tags: [(String, String)] = [("type", "workout")]
        if let activity = record.activityName {
            tags.append(("activity", activity))
        }
        tags.append(contentsOf: baseTags(for: record).filter { $0.0 != "type" })

        var fields: [(String, FieldValue)] = []
        if let duration = record.duration ?? intervalSeconds(for: record) {
            fields.append(("duration", .double(duration)))
        }
        if !record.identifier.isEmpty {
            fields.append(("id", .string(record.identifier)))
        }
        guard !fields.isEmpty else {
            return nil
        }

        return compose(
            measurement: options.measurement + workoutSuffix,
            tags: tags,
            fields: fields,
            timestamp: timestamp(record.startDate, precision: options.precision)
        )
    }

    /// A record with no number in it — a correlation, or a sample kind Hozz
    /// could not reduce to a value.
    ///
    /// Line protocol needs at least one field, so these cannot go in the main
    /// measurement without inventing a value for them. They get their own
    /// measurement instead, which keeps the main series clean and still means
    /// nothing disappears between the phone and InfluxDB.
    private static func eventLine(
        for record: CompatiblePayloadBuilder.Record,
        options: Options
    ) -> String? {
        guard !record.identifier.isEmpty else {
            return nil
        }
        var fields: [(String, FieldValue)] = [("id", .string(record.identifier))]
        if let duration = intervalSeconds(for: record) {
            fields.append(("duration", .double(duration)))
        }
        return compose(
            measurement: options.measurement + eventSuffix,
            tags: baseTags(for: record),
            fields: fields,
            timestamp: timestamp(record.startDate, precision: options.precision)
        )
    }

    /// A tombstone.
    ///
    /// The record identifier is a tag here and nowhere else. Putting a unique
    /// value in a tag is normally the mistake that ruins an InfluxDB instance,
    /// and it is done deliberately in this one measurement: a deletion carries
    /// no timestamp, so as a field every tombstone in a batch would land on the
    /// same series at the same instant and overwrite the one before it. Losing
    /// records is the one thing worth spending cardinality on, and it is spent
    /// in a measurement nothing else queries.
    private static func deletionLine(
        for record: CompatiblePayloadBuilder.Record,
        options: Options
    ) -> String? {
        guard !record.identifier.isEmpty else {
            return nil
        }
        let tags = [
            ("type", record.metricName),
            ("id", record.identifier)
        ]
        return compose(
            measurement: options.measurement + deletionSuffix,
            tags: tags,
            fields: [("deleted", .boolean(true))],
            timestamp: timestamp(record.startDate, precision: options.precision)
        )
    }

    private static func baseTags(
        for record: CompatiblePayloadBuilder.Record
    ) -> [(String, String)] {
        var tags: [(String, String)] = [("type", record.metricName)]
        if let source = record.sourceName {
            tags.append(("source", source))
        }
        if let device = record.deviceName {
            tags.append(("device", device))
        }
        return tags
    }

    private static func intervalSeconds(
        for record: CompatiblePayloadBuilder.Record
    ) -> Double? {
        guard
            record.endDate != record.startDate,
            let start = date(from: record.startDate),
            let end = date(from: record.endDate)
        else {
            return nil
        }
        let seconds = end.timeIntervalSince(start)
        return seconds > 0 ? seconds : nil
    }

    // MARK: - Composing

    enum FieldValue {
        case double(Double)
        case string(String)
        case boolean(Bool)

        var encoded: String {
            switch self {
            case .double(let value):
                // Swift's shortest round-tripping form, which is locale
                // independent. Scientific notation is valid line protocol.
                String(value)
            case .string(let value):
                "\"\(escapeStringField(value))\""
            case .boolean(let value):
                value ? "true" : "false"
            }
        }
    }

    /// Assembles `measurement,tag_set field_set timestamp`.
    ///
    /// A tag with an empty key or value is dropped rather than written: InfluxDB
    /// treats an empty tag value as the tag being absent anyway, and writing
    /// `source=` produces a line it rejects.
    static func compose(
        measurement: String,
        tags: [(String, String)],
        fields: [(String, FieldValue)],
        timestamp: Int64?
    ) -> String? {
        guard !fields.isEmpty else {
            return nil
        }

        var line = escapeMeasurement(measurement)
        var seenTagKeys = Set<String>()
        for (key, value) in tags {
            let cleanKey = sanitised(key)
            let cleanValue = sanitised(value)
            guard
                !cleanKey.isEmpty,
                !cleanValue.isEmpty,
                // `time` is reserved: InfluxDB rejects it as a tag or field key.
                cleanKey != "time",
                seenTagKeys.insert(cleanKey).inserted
            else {
                continue
            }
            line += ",\(escapeKey(cleanKey))=\(escapeKey(cleanValue))"
        }

        var encodedFields: [String] = []
        var seenFieldKeys = Set<String>()
        for (key, value) in fields {
            let cleanKey = sanitised(key)
            guard
                !cleanKey.isEmpty,
                cleanKey != "time",
                seenFieldKeys.insert(cleanKey).inserted
            else {
                continue
            }
            encodedFields.append("\(escapeKey(cleanKey))=\(value.encoded)")
        }
        guard !encodedFields.isEmpty else {
            return nil
        }

        line += " " + encodedFields.joined(separator: ",")
        if let timestamp {
            line += " \(timestamp)"
        }
        return line
    }

    // MARK: - Escaping

    /// Line protocol is line delimited, and it has no escape for a newline in a
    /// tag or a field. A value containing one has to be flattened here or the
    /// line breaks in two and InfluxDB rejects both halves.
    static func sanitised(_ value: String) -> String {
        guard value.contains(where: { $0.isNewline || $0 == "\u{0}" }) else {
            return value
        }
        return String(value.map { $0.isNewline || $0 == "\u{0}" ? " " : $0 })
    }

    /// Measurement names escape a comma and a space.
    ///
    /// A leading `#` or `_` is also dealt with here. InfluxDB reads a line
    /// starting with `#` as a comment and discards it without complaining, and
    /// it reserves the `_` namespace for itself — either one turns a
    /// user-chosen measurement name into a batch that vanishes rather than a
    /// batch that fails.
    static func escapeMeasurement(_ value: String) -> String {
        var value = sanitised(value)
        while value.hasPrefix("#") || value.hasPrefix("_") {
            value.removeFirst()
        }
        if value.isEmpty {
            value = defaultMeasurement
        }
        return escape(value, specials: [",", " "])
    }

    /// Tag keys, tag values, and field keys escape a comma, an equals, and a
    /// space.
    static func escapeKey(_ value: String) -> String {
        escape(sanitised(value), specials: [",", "=", " "])
    }

    /// String field values escape a double quote and a backslash, and nothing
    /// else — a comma or a space inside the quotes is already unambiguous.
    static func escapeStringField(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in sanitised(value) {
            if character == "\\" || character == "\"" {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    /// Escapes the given characters, and doubles every backslash.
    ///
    /// InfluxDB reads two contiguous backslashes as one, in every position, so
    /// doubling is what makes a backslash arrive as the character that was
    /// sent. It also removes the case that actually corrupts a line: a value
    /// ending in a single backslash would otherwise escape the space that
    /// separates the tag set from the field set, and take the whole line with
    /// it.
    private static func escape(_ value: String, specials: Set<Character>) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            if character == "\\" || specials.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    // MARK: - Timestamps

    /// Converts one of Hozz's ISO 8601 timestamps to an integer in the given
    /// precision.
    ///
    /// The fraction is read from the string rather than from the parsed date on
    /// purpose. A `Date` is a `Double` of seconds since 2001, and near 2026
    /// that leaves it about 400ns of resolution — enough to round two samples a
    /// millisecond apart onto timestamps that are not a millisecond apart, and
    /// in the worst case onto the same point, where InfluxDB would keep one and
    /// discard the other. The digits after the decimal point in the source
    /// string do not have that problem.
    static func timestamp(_ value: String, precision: Precision) -> Int64? {
        guard let date = date(from: value) else {
            return nil
        }
        let seconds = Int64(date.timeIntervalSince1970.rounded(.down))
        let nanoseconds = seconds * 1_000_000_000 + fractionalNanoseconds(of: value)
        return nanoseconds / precision.nanosecondsPerUnit
    }

    /// The digits after the decimal point, as nanoseconds.
    static func fractionalNanoseconds(of value: String) -> Int64 {
        guard let dot = value.firstIndex(of: ".") else {
            return 0
        }
        var digits = ""
        for character in value[value.index(after: dot)...] {
            guard character.isASCII, character.isNumber else {
                break
            }
            digits.append(character)
            if digits.count == 9 {
                break
            }
        }
        guard !digits.isEmpty else {
            return 0
        }
        // Pad to nanoseconds: ".5" is 500 million, not 5.
        let padded = digits.padding(toLength: 9, withPad: "0", startingAt: 0)
        return Int64(padded) ?? 0
    }

    static func date(from value: String) -> Date? {
        guard !value.isEmpty else {
            return nil
        }
        if let parsed = try? fractional.parse(value) {
            return parsed
        }
        return try? whole.parse(value)
    }

    private static let fractional = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )
    private static let whole = Date.ISO8601FormatStyle(timeZone: .gmt)
}
