import Foundation

/// Takes an encoded payload apart into the records it carries, and puts any
/// subset of them back together in the same format.
///
/// Two features need this and neither can get it any other way. A delivery
/// window has to decide per record whether it is inside the window, and batching
/// has to hand a server several smaller bodies instead of one it will refuse.
/// Both happen after the payload has already been encoded, so both need a way
/// back to the records.
///
/// The rule the whole file is written to is that decomposing and recomposing
/// every record must return exactly the bytes that went in. Anything less means
/// a record changed shape in transit, and a record that changed shape is a
/// record whose value can no longer be trusted. ``roundTripsExactly(_:format:)``
/// is what the tests assert on, and ``divide(_:format:into:)`` refuses to split
/// a payload it could not take apart rather than guessing at a boundary.
public enum PayloadDivision {
    /// One record, still in the form its format wrote it.
    public struct Record: Sendable {
        /// When this record happened, when the format records that per record.
        ///
        /// Absent means the format did not write a timestamp this record could
        /// be dated by — a deletion tombstone in line protocol, for instance.
        /// An undated record is never excluded by a window, because "no date"
        /// is not evidence of being outside one.
        public let date: Date?
        let content: Content

        /// Roughly what this record adds to a payload, separator included.
        ///
        /// Only ever used to decide where to cut, and always checked against
        /// the real bytes afterwards, so being a little generous here costs a
        /// slightly smaller part and nothing else.
        var estimatedBytes: Int {
            switch content {
            case .line(let line):
                // The line, plus a newline or a comma and a newline.
                line.count + 2
            case .metricPoint(let name, let units, let point):
                // The point, plus its share of the metric envelope it may have
                // to open: {"name":"…","units":"…","data":[]}.
                point.count + name.count + units.count + 40
            case .metricWorkout(let object), .metricDeletion(let object):
                object.count + 2
            }
        }

        enum Content: Sendable {
            /// A whole line, exactly as the builder wrote it.
            case line(Data)
            /// One point inside a Metrics JSON metric, held as the bytes of its
            /// own JSON object.
            ///
            /// Bytes rather than a dictionary because a `[String: Any]` is not
            /// `Sendable`, and a batch crosses actors on its way to a channel.
            /// Re-serialising is deterministic — every builder here writes with
            /// sorted keys — so nothing about the payload changes for it.
            case metricPoint(name: String, units: String, point: Data)
            case metricWorkout(Data)
            case metricDeletion(Data)
        }
    }

    /// A payload taken apart, with whatever framing its format needs to be put
    /// back together.
    public struct Division: Sendable {
        public let format: DeliveryFormat
        public var records: [Record]
        /// The CSV header row, which every part has to repeat.
        let header: Data?

        public var count: Int {
            records.count
        }

        /// What every part costs before it holds a single record.
        var framingBytes: Int {
            switch format {
            case .ndjson, .influx:
                0
            case .json:
                // "[\n" and "\n]\n".
                5
            case .csv:
                header?.count ?? 0
            case .metrics:
                // {"data":{"metrics":[]}} and room for the workout and deletion
                // keys if this part happens to carry any.
                60
            }
        }

        /// Rebuilds a payload holding exactly the given records, in order.
        public func recompose(_ subset: [Record]) -> Data {
            PayloadDivision.recompose(subset, format: format, header: header)
        }
    }

    // MARK: - Taking a payload apart

    /// Splits a payload into its records, or nil when this build cannot do it
    /// exactly.
    ///
    /// Returning nil is deliberate and load bearing. A payload this cannot take
    /// apart is one where a split or a filter would have to guess, and a guess
    /// here silently drops or duplicates a Health record. Every caller treats
    /// nil as "leave the payload alone and say so".
    public static func decompose(
        _ payload: Data,
        format: DeliveryFormat,
        influxPrecision: InfluxLineProtocol.Precision = .nanoseconds,
        dateStyle: PointDateStyle = .iso8601
    ) -> Division? {
        switch format {
        case .ndjson, .json:
            guard let lines = canonicalLines(payload, format: format) else {
                return nil
            }
            return Division(
                format: format,
                records: lines.map {
                    Record(date: canonicalDate(of: $0), content: .line($0))
                },
                header: nil
            )

        case .csv:
            return csvDivision(payload)
        case .influx:
            let lines = payload.split(separator: 0x0A, omittingEmptySubsequences: true)
            return Division(
                format: format,
                records: lines.map { line in
                    Record(
                        date: influxDate(of: Data(line), precision: influxPrecision),
                        content: .line(Data(line))
                    )
                },
                header: nil
            )

        case .metrics:
            return metricsDivision(payload, dateStyle: dateStyle)
        }
    }

    /// Puts the given records back together as a payload of that format.
    static func recompose(
        _ records: [Record],
        format: DeliveryFormat,
        header: Data?
    ) -> Data {
        switch format {
        case .ndjson, .influx:
            var payload = Data()
            for record in records {
                guard case .line(let line) = record.content else {
                    continue
                }
                payload.append(line)
                payload.append(0x0A)
            }
            return payload

        case .json:
            var payload = Data("[\n".utf8)
            var isFirst = true
            for record in records {
                guard case .line(let line) = record.content else {
                    continue
                }
                if !isFirst {
                    payload.append(Data(",\n".utf8))
                }
                isFirst = false
                payload.append(line)
            }
            payload.append(Data("\n]\n".utf8))
            return payload

        case .csv:
            var payload = header ?? Data()
            for record in records {
                guard case .line(let line) = record.content else {
                    continue
                }
                payload.append(line)
                payload.append(0x0A)
            }
            return payload

        case .metrics:
            return recomposeMetrics(records)
        }
    }

    // MARK: - Dividing

    /// Splits a payload into parts of at most `maxRecords` records each.
    ///
    /// Every record appears in exactly one part, in the order it was written.
    /// A payload that cannot be taken apart comes back as a single part holding
    /// the original bytes, so the caller never has to choose between splitting
    /// wrongly and sending nothing.
    public static func divide(
        _ payload: Data,
        format: DeliveryFormat,
        into maxRecords: Int,
        influxPrecision: InfluxLineProtocol.Precision = .nanoseconds,
        dateStyle: PointDateStyle = .iso8601
    ) -> [Data] {
        guard
            maxRecords > 0,
            let division = decompose(
                payload,
                format: format,
                influxPrecision: influxPrecision,
                dateStyle: dateStyle
            )
        else {
            return [payload]
        }
        guard division.count > maxRecords else {
            return [payload]
        }
        return stride(from: 0, to: division.count, by: maxRecords).map { start in
            let end = min(start + maxRecords, division.count)
            return division.recompose(Array(division.records[start..<end]))
        }
    }

    /// Splits a payload into parts that each fit inside `maxBytes`.
    ///
    /// The size limit that matters is a server's, and servers count bytes. An
    /// nginx in front of somebody's home API refuses a body over one megabyte
    /// by default, and the whole batch is rejected — so the useful question is
    /// not "how many records" but "how much".
    ///
    /// Packing is greedy over an estimate and then **verified against the real
    /// bytes**, because an estimate that is wrong in the wrong direction
    /// produces a part the server refuses, which is the failure this is meant
    /// to avoid. A part that still does not fit is halved until it does or
    /// until it holds a single record.
    ///
    /// A single record larger than the limit is sent on its own rather than
    /// dropped. It will probably be refused, and that is the honest outcome: it
    /// cannot be made smaller without throwing away part of a reading.
    public static func divide(
        _ payload: Data,
        format: DeliveryFormat,
        maxBytes: Int,
        influxPrecision: InfluxLineProtocol.Precision = .nanoseconds,
        dateStyle: PointDateStyle = .iso8601
    ) -> [Data] {
        guard
            maxBytes > 0,
            payload.count > maxBytes,
            let division = decompose(
                payload,
                format: format,
                influxPrecision: influxPrecision,
                dateStyle: dateStyle
            ),
            division.count > 1
        else {
            return [payload]
        }

        var parts: [[Record]] = []
        var current: [Record] = []
        var currentBytes = division.framingBytes

        for record in division.records {
            let cost = record.estimatedBytes
            if !current.isEmpty, currentBytes + cost > maxBytes {
                parts.append(current)
                current = []
                currentBytes = division.framingBytes
            }
            current.append(record)
            currentBytes += cost
        }
        if !current.isEmpty {
            parts.append(current)
        }

        return parts.flatMap { part in
            fit(part, in: division, maxBytes: maxBytes)
        }
    }

    /// Recomposes a group and halves it until the bytes really do fit.
    private static func fit(
        _ records: [Record],
        in division: Division,
        maxBytes: Int
    ) -> [Data] {
        let payload = division.recompose(records)
        guard payload.count > maxBytes, records.count > 1 else {
            return [payload]
        }
        let middle = records.count / 2
        return fit(Array(records[..<middle]), in: division, maxBytes: maxBytes)
            + fit(Array(records[middle...]), in: division, maxBytes: maxBytes)
    }

    /// Whether taking this payload apart and putting it back gives the same
    /// bytes.
    ///
    /// Used by the tests rather than in the app, because the property it checks
    /// is the one that makes everything built on this file safe.
    public static func roundTripsExactly(
        _ payload: Data,
        format: DeliveryFormat,
        dateStyle: PointDateStyle = .iso8601
    ) -> Bool {
        guard
            let division = decompose(payload, format: format, dateStyle: dateStyle)
        else {
            return false
        }
        return division.recompose(division.records) == payload
    }

    // MARK: - NDJSON and JSON

    /// The canonical record lines inside an NDJSON or JSON payload.
    ///
    /// Both formats are built from compact, single-line JSON objects. Compact
    /// JSON cannot contain a literal newline — a newline inside a string is
    /// written as the two characters `\n` — so splitting on newlines recovers
    /// exactly the lines that were written and nothing else.
    private static func canonicalLines(
        _ payload: Data,
        format: DeliveryFormat
    ) -> [Data]? {
        var lines: [Data] = []
        for slice in payload.split(separator: 0x0A, omittingEmptySubsequences: true) {
            var line = Data(slice)
            if format == .json {
                // The array framing: a leading `[`, a trailing `]`, and a comma
                // after every element but the last.
                if line == Data("[".utf8) || line == Data("]".utf8) {
                    continue
                }
                if line.last == 0x2C {
                    line.removeLast()
                }
            }
            guard line.first == 0x7B else {
                // Not a JSON object. Refusing is the honest answer: a payload
                // this does not recognise is one it must not take apart.
                return nil
            }
            lines.append(line)
        }
        return lines
    }

    private static func canonicalDate(of line: Data) -> Date? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let start = object["startDate"] as? String
        else {
            return nil
        }
        return InfluxLineProtocol.date(from: start)
    }

    // MARK: - CSV

    /// The column the flat CSV writes `startDate` into.
    static let csvStartDateColumn = 3

    private static func csvDivision(_ payload: Data) -> Division? {
        var rows = csvRows(payload)
        guard let header = rows.first else {
            return nil
        }
        rows.removeFirst()

        var headerData = header
        headerData.append(0x0A)
        return Division(
            format: .csv,
            records: rows.map { row in
                Record(date: csvDate(of: row), content: .line(row))
            },
            header: headerData
        )
    }

    /// Splits a CSV payload into rows, ignoring newlines inside quotes.
    ///
    /// The writer quotes any field containing a newline, so a source name with
    /// one in it produces a record that spans two lines. Splitting on every
    /// newline would tear that record in half, and the halves would then be
    /// filtered or batched independently — one record silently becoming two,
    /// both malformed. Rare, but the failure is corruption rather than an error,
    /// so it is worth the dozen lines to be right.
    static func csvRows(_ payload: Data) -> [Data] {
        var rows: [Data] = []
        var current = Data()
        var isQuoted = false

        for byte in payload {
            if byte == 0x22 {
                // A doubled quote inside a quoted field is an escaped quote, and
                // flipping twice leaves the state where it started, so it needs
                // no special case here.
                isQuoted.toggle()
                current.append(byte)
                continue
            }
            if byte == 0x0A, !isQuoted {
                if !current.isEmpty {
                    rows.append(current)
                }
                current = Data()
                continue
            }
            current.append(byte)
        }
        if !current.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private static func csvDate(of row: Data) -> Date? {
        guard let text = String(data: row, encoding: .utf8) else {
            return nil
        }
        let fields = csvFields(text)
        guard fields.count > csvStartDateColumn else {
            return nil
        }
        return InfluxLineProtocol.date(from: fields[csvStartDateColumn])
    }

    /// Splits one CSV row into its fields, honouring quoting.
    ///
    /// Written out rather than split on commas because `sourceName` is a
    /// user-visible device name and genuinely does contain commas — "Brandon's
    /// iPhone, work" is a name someone can set — and a naive split would read
    /// the wrong column as the date and drop the row from every window.
    static func csvFields(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isQuoted = false
        var characters = Array(row)
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if isQuoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        current.append("\"")
                        index += 2
                        continue
                    }
                    isQuoted = false
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                isQuoted = true
            } else if character == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        fields.append(current)
        return fields
    }

    // MARK: - InfluxDB line protocol

    /// The timestamp on a line, converted back from the precision it was
    /// written in.
    ///
    /// A line without a trailing integer has no timestamp, which line protocol
    /// allows — the server stamps it on arrival. Such a line is undated here
    /// rather than dated wrongly.
    static func influxDate(
        of line: Data,
        precision: InfluxLineProtocol.Precision
    ) -> Date? {
        guard
            let text = String(data: line, encoding: .utf8),
            let field = text.split(separator: " ").last,
            let ticks = Int64(field)
        else {
            return nil
        }
        let nanoseconds = Double(ticks) * Double(precision.nanosecondsPerUnit)
        return Date(timeIntervalSince1970: nanoseconds / 1_000_000_000)
    }

    // MARK: - Metrics JSON

    /// Which spelling of a date a Metrics JSON payload used.
    ///
    /// Hozz's own schema writes ISO 8601; the Health Auto Export compatibility
    /// mode writes that app's local-time format. Reading a point's date back
    /// needs to know which, and guessing wrong would silently place every point
    /// outside every window.
    public enum PointDateStyle: Sendable {
        case iso8601
        case healthAutoExport(TimeZone)

        func date(from text: String) -> Date? {
            switch self {
            case .iso8601:
                return InfluxLineProtocol.date(from: text)
            case .healthAutoExport(let timeZone):
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.timeZone = timeZone
                formatter.dateFormat = HealthAutoExportPayloadBuilder.dateFormat
                return formatter.date(from: text)
            }
        }
    }

    private static func metricsDivision(
        _ payload: Data,
        dateStyle: PointDateStyle
    ) -> Division? {
        guard
            let root = try? JSONSerialization.jsonObject(with: payload) as? JSONObject,
            let data = root["data"] as? JSONObject
        else {
            return nil
        }

        var records: [Record] = []
        for metric in data["metrics"] as? [JSONObject] ?? [] {
            guard
                let name = metric["name"] as? String,
                let units = metric["units"] as? String
            else {
                return nil
            }
            for point in metric["data"] as? [JSONObject] ?? [] {
                guard let bytes = encode(point) else {
                    return nil
                }
                records.append(
                    Record(
                        date: metricPointDate(point, style: dateStyle),
                        content: .metricPoint(name: name, units: units, point: bytes)
                    )
                )
            }
        }
        for workout in data["workouts"] as? [JSONObject] ?? [] {
            guard let bytes = encode(workout) else {
                return nil
            }
            let text = workout["start"] as? String ?? ""
            records.append(
                Record(
                    date: dateStyle.date(from: text),
                    content: .metricWorkout(bytes)
                )
            )
        }
        for deletion in data["deletions"] as? [JSONObject] ?? [] {
            guard let bytes = encode(deletion) else {
                return nil
            }
            let text = deletion["date"] as? String ?? ""
            records.append(
                Record(
                    date: dateStyle.date(from: text),
                    content: .metricDeletion(bytes)
                )
            )
        }

        return Division(format: .metrics, records: records, header: nil)
    }

    private static func encode(_ object: JSONObject) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func decode(_ data: Data) -> JSONObject? {
        try? JSONSerialization.jsonObject(with: data) as? JSONObject
    }

    /// A sleep point writes `startDate` where every other point writes `date`.
    private static func metricPointDate(
        _ point: JSONObject,
        style: PointDateStyle
    ) -> Date? {
        let text = point["date"] as? String ?? point["startDate"] as? String
        return text.flatMap(style.date(from:))
    }

    private static func recomposeMetrics(_ records: [Record]) -> Data {
        // Rebuilt in the same order the builder wrote them: metrics sorted by
        // name, then workouts, then deletions. A part that reordered them would
        // still be valid JSON, but it would no longer be the same payload, and
        // the round-trip check is what makes the split trustworthy.
        var order: [String] = []
        var grouped: [String: (units: String, points: [JSONObject])] = [:]
        var workouts: [JSONObject] = []
        var deletions: [JSONObject] = []

        for record in records {
            switch record.content {
            case .metricPoint(let name, let units, let point):
                guard let point = decode(point) else {
                    continue
                }
                if grouped[name] == nil {
                    grouped[name] = (units: units, points: [])
                    order.append(name)
                }
                grouped[name]?.points.append(point)
            case .metricWorkout(let workout):
                guard let workout = decode(workout) else {
                    continue
                }
                workouts.append(workout)
            case .metricDeletion(let deletion):
                guard let deletion = decode(deletion) else {
                    continue
                }
                deletions.append(deletion)
            case .line:
                continue
            }
        }

        let metrics = order.sorted().map { name -> JSONObject in
            let value = grouped[name] ?? (units: "count", points: [])
            return ["name": name, "units": value.units, "data": value.points]
        }

        var data: JSONObject = ["metrics": metrics]
        if !workouts.isEmpty {
            data["workouts"] = workouts
        }
        if !deletions.isEmpty {
            data["deletions"] = deletions
        }

        return (
            try? JSONSerialization.data(
                withJSONObject: ["data": data],
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        ) ?? Data()
    }
}

typealias JSONObject = [String: Any]
