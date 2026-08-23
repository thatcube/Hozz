import Foundation
import HozzCore
import HozzReceive

/// A Model Context Protocol server over the received Health data.
///
/// This is the point of receiving on a computer. Files in a folder are inert;
/// this lets the user point any MCP-capable assistant at their own data and ask
/// real questions about it — "how has my resting heart rate moved this year",
/// "did my sleep change after I started that medication" — without the data
/// ever leaving the machine or passing through anyone's service.
///
/// Three rules shape everything here:
///
/// 1. **Read-only.** No tool can modify or delete anything. The receiver's copy
///    is derived data, but it is still the user's health record.
/// 2. **Aggregates before rows.** Tools return summaries and buckets by
///    default. Handing an assistant a million raw samples would be slower,
///    less useful, and would spread far more personal detail than the question
///    needed.
/// 3. **No silent emptiness.** A type with no data says so, rather than
///    returning an empty list that reads like a confident zero.
public actor MCPServer {
    public static let protocolVersion = "2024-11-05"
    public static let serverName = "hozz"

    private let store: IngestStore
    private let version: String

    public init(store: IngestStore, version: String = "1.0.0") {
        self.store = store
        self.version = version
    }

    /// Handles one JSON-RPC message and returns the reply, if any.
    ///
    /// Notifications have no `id` and must not be answered — replying to one is
    /// a protocol violation that some clients treat as fatal.
    public func handle(_ message: Data) async -> Data? {
        guard
            let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any]
        else {
            return encode(
                JSONRPC.error(id: nil, code: -32700, message: "Parse error")
            )
        }

        let id = object["id"]
        let method = object["method"] as? String ?? ""
        let params = object["params"] as? [String: Any] ?? [:]

        if id == nil {
            // A notification. `initialized` is the common one; nothing to do.
            return nil
        }

        switch method {
        case "initialize":
            return encode(JSONRPC.result(id: id, result: initializeResult()))
        case "tools/list":
            return encode(JSONRPC.result(id: id, result: ["tools": Tools.all]))
        case "tools/call":
            return encode(await callTool(id: id, params: params))
        case "ping":
            return encode(JSONRPC.result(id: id, result: [:]))
        default:
            return encode(
                JSONRPC.error(
                    id: id,
                    code: -32601,
                    message: "Unknown method: \(method)"
                )
            )
        }
    }

    private func initializeResult() -> [String: Any] {
        [
            "protocolVersion": Self.protocolVersion,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": Self.serverName, "version": version]
        ]
    }

    private func callTool(id: Any?, params: [String: Any]) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        do {
            let text = try await run(tool: name, arguments: arguments)
            return JSONRPC.result(
                id: id,
                result: [
                    "content": [["type": "text", "text": text]],
                    "isError": false
                ]
            )
        } catch {
            // Reported as tool output rather than a protocol error, so the
            // assistant can read the reason and adjust instead of failing.
            return JSONRPC.result(
                id: id,
                result: [
                    "content": [[
                        "type": "text",
                        "text": "That did not work: \(error.localizedDescription)"
                    ]],
                    "isError": true
                ]
            )
        }
    }

    func run(tool name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "list_health_types":
            return try await listTypes()
        case "summarise_health_data":
            return try await summarise(arguments)
        case "aggregate_health_data":
            return try await aggregate(arguments)
        case "list_health_samples":
            return try await samples(arguments)
        case "list_electrocardiograms":
            return try await electrocardiograms(arguments)
        case "get_electrocardiogram_voltages":
            return try await voltages(arguments)
        case "list_audiograms":
            return try await audiograms(arguments)
        default:
            throw MCPError.unknownTool(name)
        }
    }

    // MARK: - Tools

    // MARK: - ECG and hearing

    private func electrocardiograms(_ arguments: [String: Any]) async throws -> String {
        let limit = min((arguments["limit"] as? Int) ?? 50, 500)
        let readings = try await store.electrocardiograms(limit: limit)
        guard !readings.isEmpty else {
            return "No ECG readings have been received."
        }

        var text = "\(readings.count) ECG "
        text += readings.count == 1 ? "reading" : "readings"
        text += ".\n\nid, start, classification, symptoms, average bpm, waveform\n"
        text += readings
            .map { reading in
                [
                    reading.id,
                    Timestamps.text(from: reading.startDate),
                    reading.classification ?? "unclassified",
                    reading.symptomsStatus ?? "unknown",
                    reading.averageHeartRate.map(Self.number) ?? "",
                    Self.waveformState(reading)
                ].joined(separator: ", ")
            }
            .joined(separator: "\n")
        return text
    }

    /// Says what is actually held, because "complete" and "still arriving" are
    /// different claims and only one of them can be read as a whole recording.
    private static func waveformState(
        _ reading: IngestStore.StoredElectrocardiogram
    ) -> String {
        guard reading.heldVoltages > 0 else {
            return "no waveform received"
        }
        if reading.isComplete {
            return "complete (\(reading.heldVoltages) points)"
        }
        guard let expected = reading.expectedVoltages else {
            return "\(reading.heldVoltages) points, completeness unknown"
        }
        return "incomplete (\(reading.heldVoltages) of \(expected) points)"
    }

    private func voltages(_ arguments: [String: Any]) async throws -> String {
        guard let id = arguments["id"] as? String else {
            throw MCPError.missingArgument("id")
        }
        let limit = min((arguments["limit"] as? Int) ?? 500, 20_000)
        let waveform = try await store.voltages(forElectrocardiogram: id)

        guard !waveform.points.isEmpty else {
            // Distinguishing "no such reading" from "no waveform yet" matters:
            // an assistant told only "empty" will report the reading missing.
            let known = try await store.electrocardiograms(limit: 500)
                .map(\.id)
            if !known.contains(id) {
                return "There is no ECG reading with id \(id)."
            }
            return "That reading has arrived but its waveform has not."
        }

        var text = waveform.isComplete
            ? "Complete recording: \(waveform.points.count) points."
            : "INCOMPLETE recording: \(waveform.points.count) points held"
        if !waveform.isComplete {
            text += waveform.expected.map { " of \($0) expected" } ?? ""
            text += ". Do not read this as a whole trace."
        }
        text += "\n\nsecondsSinceStart, volts\n"

        text += waveform.points.prefix(limit)
            .map { point in
                String(format: "%.4f, %.7f", point.secondsSinceStart, point.volts)
            }
            .joined(separator: "\n")

        if waveform.points.count > limit {
            text += "\n\n(Truncated at \(limit) of \(waveform.points.count) points.)"
        }
        return text
    }

    private func audiograms(_ arguments: [String: Any]) async throws -> String {
        let limit = min((arguments["limit"] as? Int) ?? 20, 200)
        let tests = try await store.audiograms(limit: limit)
        guard !tests.isEmpty else {
            return "No hearing tests have been received."
        }

        var text = ""
        for test in tests {
            text += "Hearing test \(Self.day(test.startDate))"
            if let source = test.sourceName {
                text += " from \(source)"
            }
            text += "\n"
            if test.points.isEmpty {
                text += "  (no thresholds recorded)\n\n"
                continue
            }
            text += "  frequency, ear, threshold\n"
            for point in test.points {
                let value = point.sensitivity.map(Self.number) ?? "—"
                // A clamped reading is a bound: the difference between "90 dB"
                // and "at least 90 dB".
                let threshold = point.clamped ? "at least \(value)" : value
                text += "  \(Self.number(point.frequency)) Hz, \(point.ear), "
                text += "\(threshold) \(point.unit ?? "")\n"
            }
            text += "\n"
        }
        return text
    }

    private func listTypes() async throws -> String {
        let summaries = try await store.summaries()
        guard !summaries.isEmpty else {
            return """
                No Health data has been received yet. Open Hozz on the phone and \
                add this computer as a destination, then sync.
                """
        }
        let lines = summaries.map { summary in
            let range = [summary.earliest, summary.latest]
                .compactMap { $0 }
                .map(Self.day)
            let span = range.count == 2 ? " (\(range[0]) to \(range[1]))" : ""
            let unit = summary.unit.map { " \($0)" } ?? ""
            return "- \(summary.type): \(summary.recordCount) records\(unit)\(span)"
        }
        return "Health types available:\n" + lines.joined(separator: "\n")
    }

    private func summarise(_ arguments: [String: Any]) async throws -> String {
        let summaries = try await store.summaries()
        let total = try await store.totalRecordCount()
        let characteristics = try await store.characteristics()
        // Counted here rather than later, because "nothing received" has to be
        // false the moment anything has been — an ECG is not an ordinary
        // sample, and reporting an empty store while holding one is exactly
        // the confidently wrong answer this tool exists to avoid.
        let ecgCount = try await store.electrocardiograms(limit: 500).count
        let audiogramCount = try await store.audiograms(limit: 200).count

        guard
            !summaries.isEmpty
                || !characteristics.isEmpty
                || ecgCount > 0
                || audiogramCount > 0
        else {
            return "No Health data has been received yet."
        }

        var text = ""

        // Deliberately part of this tool rather than one of its own.
        //
        // These are what the measurements have to be read against: a resting
        // heart rate of 48 is athletic in a 34-year-old and worth a question in
        // a 70-year-old. A separate tool would be cleaner to describe and worse
        // in practice, because an assistant that is not required to call it
        // will answer "is this normal for me" without ever having asked who
        // "me" is. Putting it here means the context arrives with the
        // orientation step that every session already begins with.
        if !characteristics.isEmpty {
            text += "About the person:\n"
            for characteristic in characteristics {
                text += "- \(characteristic.displayName): "
                text += Self.describe(characteristic) + "\n"
            }
            text += "\n"
        }

        guard !summaries.isEmpty else {
            if ecgCount > 0 || audiogramCount > 0 {
                return text
                    + "No ordinary measurements yet, but \(ecgCount) ECG "
                    + "readings and \(audiogramCount) hearing tests have arrived."
            }
            return text + "No measurements have been received yet."
        }

        let earliest = summaries.compactMap(\.earliest).min()
        let latest = summaries.compactMap(\.latest).max()
        text += "\(total) records across \(summaries.count) types."
        if let earliest, let latest {
            text += " Covering \(Self.day(earliest)) to \(Self.day(latest))."
        }

        // A receiver holding records it could not interpret is not the same as
        // one holding nothing, and an assistant should not describe a partial
        // picture as a complete one.
        let unhandled = try await store.unhandledSummary()
        if !unhandled.isEmpty {
            let count = unhandled.reduce(0) { $0 + $1.count }
            text += " \(count) further "
            text += count == 1 ? "record was" : "records were"
            text += " received in a form this version of Hozz cannot read yet ("
            text += unhandled.map(\.kind).joined(separator: ", ")
            text += "); they are stored but not queryable here."
        }

        // Named separately because they are not ordinary samples: saying
        // "0 types" while holding 200 ECG readings would be false.
        if ecgCount > 0 {
            text += " \(ecgCount) ECG "
            text += ecgCount == 1 ? "reading" : "readings"
            text += " (list_electrocardiograms)."
        }
        if audiogramCount > 0 {
            text += " \(audiogramCount) hearing "
            text += audiogramCount == 1 ? "test" : "tests"
            text += " (list_audiograms)."
        }

        let biggest = summaries.sorted { $0.recordCount > $1.recordCount }.prefix(10)
        text += "\n\nLargest types:\n"
        text += biggest
            .map { "- \($0.type): \($0.recordCount)" }
            .joined(separator: "\n")
        return text
    }

    /// One characteristic, in the form an assistant can reason with.
    ///
    /// A date of birth is reported with the age it implies, because age is what
    /// every reference range is actually keyed to and an assistant that has to
    /// derive it may get it wrong. States other than "known" are reported as
    /// themselves: "not set" is a fact about the person, and reporting it as a
    /// blank would invite a confident answer built on a guess.
    public static func describe(_ characteristic: StoredCharacteristic) -> String {
        guard characteristic.isKnown, let value = characteristic.value else {
            return switch characteristic.state {
            case "notSet": "not set by the person"
            case "unavailable": "not available on their device"
            case "unrecognised": "a value this version of Hozz has no name for"
            case "unreadable": "could not be read"
            default: "unknown"
            }
        }

        if characteristic.type.hasSuffix("DateOfBirth"),
           let age = Self.age(fromDateOfBirth: value) {
            return "\(value) (age \(age))"
        }
        return value
    }

    /// Whole years between a `yyyy-MM-dd` birth date and today.
    public static func age(fromDateOfBirth text: String, now: Date = .now) -> Int? {
        let parts = text.prefix(10).split(separator: "-")
        guard
            parts.count == 3,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else {
            return nil
        }
        let today = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: now
        )
        guard
            let nowYear = today.year,
            let nowMonth = today.month,
            let nowDay = today.day
        else {
            return nil
        }
        var age = nowYear - year
        // A birthday later this year has not happened yet.
        if (nowMonth, nowDay) < (month, day) {
            age -= 1
        }
        return age >= 0 ? age : nil
    }

    private func aggregate(_ arguments: [String: Any]) async throws -> String {
        guard let type = arguments["type"] as? String else {
            throw MCPError.missingArgument("type")
        }
        let bucket = (arguments["bucket"] as? String)
            .flatMap(BucketSize.init(rawValue:)) ?? .day
        let from = (arguments["from"] as? String).flatMap(Timestamps.date(from:))
        let to = (arguments["to"] as? String).flatMap(Timestamps.date(from:))

        let buckets = try await store.aggregate(
            type: type,
            bucket: bucket,
            from: from,
            to: to
        )
        guard !buckets.isEmpty else {
            // Distinguishing "no such type" from "no data in range" matters:
            // an assistant told only "empty" will confidently report a zero.
            let known = try await store.summaries().map(\.type)
            if !known.contains(type) {
                return """
                    There is no type called "\(type)". Available types: \
                    \(known.prefix(40).joined(separator: ", "))
                    """
            }
            return "\(type) has no records in that range."
        }

        let unit = try await store.summaries()
            .first { $0.type == type }?
            .unit

        var text = "\(type) by \(bucket.rawValue)"
        if let unit {
            text += " (\(unit))"
        }
        text += ":\n"
        text += "date, sum, average, min, max, count\n"
        text += buckets
            .map { bucket in
                [
                    Self.day(bucket.start),
                    Self.number(bucket.sum),
                    Self.number(bucket.average),
                    Self.number(bucket.minimum),
                    Self.number(bucket.maximum),
                    String(bucket.count)
                ].joined(separator: ", ")
            }
            .joined(separator: "\n")
        text += """

            \nBoth sum and average are given because the right one depends on \
            the type: summing an instantaneous measure like heart rate is \
            meaningless, and averaging a cumulative one like step count \
            understates the period.
            """
        return text
    }

    private func samples(_ arguments: [String: Any]) async throws -> String {
        let type = arguments["type"] as? String
        let from = (arguments["from"] as? String).flatMap(Timestamps.date(from:))
        let to = (arguments["to"] as? String).flatMap(Timestamps.date(from:))
        let limit = min((arguments["limit"] as? Int) ?? 100, 1000)

        let records = try await store.samples(
            type: type,
            from: from,
            to: to,
            limit: limit
        )
        guard !records.isEmpty else {
            return "No samples matched."
        }
        var text = "type, start, value, unit, source\n"
        text += records
            .map { record in
                [
                    record.type,
                    Timestamps.text(from: record.startDate),
                    record.value.map(Self.number) ?? "",
                    record.unit ?? "",
                    record.sourceName ?? ""
                ].joined(separator: ", ")
            }
            .joined(separator: "\n")
        if records.count == limit {
            text += "\n\n(Truncated at \(limit). Narrow the range or aggregate instead.)"
        }
        return text
    }

    // MARK: - Formatting

    private static func day(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(timeZone: .gmt)
                .year().month().day()
        )
    }

    private static func number(_ value: Double) -> String {
        // Health values are rarely meaningful past two decimals, and long
        // floating point tails make a table unreadable.
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    private func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

public enum MCPError: Error, LocalizedError, Sendable {
    case unknownTool(String)
    case missingArgument(String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            "There is no tool called \"\(name)\"."
        case .missingArgument(let name):
            "The \"\(name)\" argument is required."
        }
    }
}

enum JSONRPC {
    static func result(id: Any?, result: [String: Any]) -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "result": result]
        message["id"] = id ?? NSNull()
        return message
    }

    static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message]
        ]
        payload["id"] = id ?? NSNull()
        return payload
    }
}

/// The tool definitions advertised to a client.
enum Tools {
    /// Computed rather than stored: `[String: Any]` is not `Sendable`, and a
    /// shared static would be mutable state across every connection.
    static var all: [[String: Any]] {
        [
        [
            "name": "list_health_types",
            "description": """
                List every Health data type that has been received, with how \
                many records each has and the dates they span. Call this first: \
                type names are HealthKit identifiers and cannot be guessed \
                reliably.
                """,
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "summarise_health_data",
            "description": """
                An overview of everything received: total records, how many \
                types, the date range covered, and the largest types. Also \
                returns the person's own characteristics — age, biological \
                sex, blood type and so on — where they have been shared. Call \
                this before interpreting any measurement, because reference \
                ranges depend on them: a resting heart rate of 48 means \
                something different at 34 than at 70.
                """,
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]]
        ],
        [
            "name": "aggregate_health_data",
            "description": """
                Aggregate one Health type into time buckets, returning sum, \
                average, minimum, maximum and count for each. This is the right \
                tool for questions about trends over time. Prefer it over \
                fetching raw samples.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "type": [
                        "type": "string",
                        "description": "The HealthKit type identifier, from list_health_types."
                    ],
                    "bucket": [
                        "type": "string",
                        "enum": BucketSize.allCases.map(\.rawValue),
                        "description": "Time grouping. Defaults to day."
                    ],
                    "from": [
                        "type": "string",
                        "description": "ISO 8601 start of range, inclusive. Optional."
                    ],
                    "to": [
                        "type": "string",
                        "description": "ISO 8601 end of range, inclusive. Optional."
                    ]
                ],
                "required": ["type"]
            ]
        ],
        [
            "name": "list_electrocardiograms",
            "description": """
                Every ECG reading, newest first, with what the Watch \
                classified it as, the average heart rate, whether the person \
                reported symptoms, and whether the full waveform has arrived. \
                Use this for questions about ECGs; they are not ordinary \
                samples and do not appear in list_health_samples.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "description": "How many readings to return. Defaults to 50."
                    ]
                ] as [String: Any]
            ]
        ],
        [
            "name": "get_electrocardiogram_voltages",
            "description": """
                The waveform of one ECG reading, as time/volt pairs. Says \
                explicitly whether the recording is complete: a waveform \
                assembled from pages that are still arriving is not the same \
                as a whole one, and must not be read as though it were. Large: \
                a thirty-second reading is roughly 15,000 points, so ask for a \
                limit unless the whole trace is genuinely needed.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": [
                        "type": "string",
                        "description": "The reading's id, from list_electrocardiograms."
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "How many points to return. Defaults to 500."
                    ]
                ] as [String: Any],
                "required": ["id"]
            ]
        ],
        [
            "name": "list_audiograms",
            "description": """
                Hearing tests, newest first, with the threshold measured at \
                each frequency for each ear. A clamped reading is reported as \
                a bound rather than a measurement.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "description": "How many tests to return. Defaults to 20."
                    ]
                ] as [String: Any]
            ]
        ],
        [
            "name": "list_health_samples",
            "description": """
                Individual Health samples, newest first. Use only when single \
                readings matter; for trends use aggregate_health_data, which is \
                faster and reveals far less personal detail.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "type": ["type": "string", "description": "Optional type filter."],
                    "from": ["type": "string", "description": "ISO 8601 start, inclusive."],
                    "to": ["type": "string", "description": "ISO 8601 end, inclusive."],
                    "limit": [
                        "type": "integer",
                        "description": "Maximum rows, capped at 1000. Defaults to 100."
                    ]
                ]
            ]
        ]
    ]
    }
}
