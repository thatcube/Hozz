import Foundation
import HozzCore

/// One Health sample as it arrives from a phone.
///
/// This is deliberately lenient. The receiver is the far end of a wire the user
/// controls, and a record that cannot be fully understood is still worth
/// keeping — refusing it would silently drop data the user believes they
/// exported. Anything unrecognised is preserved in `raw` so nothing is lost.
public struct HealthRecord: Hashable, Sendable {
    public let id: String
    public let type: String
    public let kind: String?
    public let startDate: Date
    public let endDate: Date
    public let value: Double?
    public let unit: String?
    public let sourceName: String?
    public let raw: Data

    public init(
        id: String,
        type: String,
        kind: String? = nil,
        startDate: Date,
        endDate: Date,
        value: Double? = nil,
        unit: String? = nil,
        sourceName: String? = nil,
        raw: Data
    ) {
        self.id = id
        self.type = type
        self.kind = kind
        self.startDate = startDate
        self.endDate = endDate
        self.value = value
        self.unit = unit
        self.sourceName = sourceName
        self.raw = raw
    }
}

/// A sample the phone reports as removed from Health.
///
/// Deletions matter as much as additions: Health is the user's record of their
/// own body, and a receiver that only ever accumulates would keep showing data
/// they deliberately removed.
public struct HealthDeletion: Hashable, Sendable {
    public let id: String
    public let type: String?
    /// Set only for payload shapes that carry no per-sample identifier, where
    /// a deletion can only be matched by type and timestamp.
    public let startDate: Date?

    public init(id: String, type: String? = nil, startDate: Date? = nil) {
        self.id = id
        self.type = type
        self.startDate = startDate
    }
}

/// Everything one delivered batch contained.
public struct ParsedBatch: Hashable, Sendable {
    public let records: [HealthRecord]
    public let deletions: [HealthDeletion]
    /// Lines that could not be parsed at all, kept only as a count so nothing
    /// about their contents is logged.
    public let unreadableCount: Int

    public var isEmpty: Bool {
        records.isEmpty && deletions.isEmpty
    }

    public init(
        records: [HealthRecord],
        deletions: [HealthDeletion],
        unreadableCount: Int
    ) {
        self.records = records
        self.deletions = deletions
        self.unreadableCount = unreadableCount
    }
}

public enum BatchParseError: Error, LocalizedError, Sendable {
    case connectionTest

    public var errorDescription: String? {
        switch self {
        case .connectionTest:
            "This was a connection test, not a batch of samples."
        }
    }
}

/// Turns a delivered payload into records, whatever shape it arrived in.
///
/// Hozz can deliver NDJSON, a JSON array, CSV, or a flattened metrics envelope,
/// and the receiver has no reliable way to be told which — a user can point any
/// destination at it. So the shape is detected rather than configured, because
/// a mismatch that silently stores nothing is the worst possible outcome.
public enum BatchParser {
    public static func parse(_ payload: Data) throws -> ParsedBatch {
        let text = String(decoding: payload, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedBatch(records: [], deletions: [], unreadableCount: 0)
        }

        // A connection test is a real, valid request that carries no samples.
        // Treating it as an unparseable batch would report a working setup as
        // broken at exactly the moment the user is checking it.
        if trimmed.contains("hozzConnectionTest") {
            throw BatchParseError.connectionTest
        }

        if trimmed.hasPrefix("[") {
            return parseJSONArray(trimmed)
        }
        if trimmed.hasPrefix("{"), trimmed.contains("\"metrics\"") {
            return parseMetricsEnvelope(trimmed)
        }
        if trimmed.hasPrefix("{") {
            return parseLines(trimmed)
        }
        if looksLikeCSV(trimmed) {
            return parseCSV(trimmed)
        }
        return parseLines(trimmed)
    }

    private static func looksLikeCSV(_ text: String) -> Bool {
        guard let first = text.split(separator: "\n", maxSplits: 1).first else {
            return false
        }
        return first.contains("startDate") && first.contains(",")
    }

    private static func parseJSONArray(_ text: String) -> ParsedBatch {
        guard
            let data = text.data(using: .utf8),
            let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return ParsedBatch(records: [], deletions: [], unreadableCount: 1)
        }
        return collect(items)
    }

    private static func parseLines(_ text: String) -> ParsedBatch {
        var objects: [[String: Any]] = []
        var unreadable = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty else {
                continue
            }
            guard
                let data = candidate.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                unreadable += 1
                continue
            }
            objects.append(object)
        }
        let batch = collect(objects)
        return ParsedBatch(
            records: batch.records,
            deletions: batch.deletions,
            unreadableCount: batch.unreadableCount + unreadable
        )
    }

    private static func collect(_ objects: [[String: Any]]) -> ParsedBatch {
        var records: [HealthRecord] = []
        var deletions: [HealthDeletion] = []
        var unreadable = 0

        for object in objects {
            if let deleted = object["deleted"] as? Bool, deleted,
               let id = object["id"] as? String {
                deletions.append(
                    HealthDeletion(id: id, type: object["type"] as? String)
                )
                continue
            }
            guard let record = record(from: object) else {
                unreadable += 1
                continue
            }
            records.append(record)
        }

        return ParsedBatch(
            records: records,
            deletions: deletions,
            unreadableCount: unreadable
        )
    }

    static func record(from object: [String: Any]) -> HealthRecord? {
        guard
            let id = object["id"] as? String,
            let type = object["type"] as? String,
            let startText = object["startDate"] as? String,
            let start = Timestamps.date(from: startText)
        else {
            return nil
        }
        let end = (object["endDate"] as? String)
            .flatMap(Timestamps.date(from:)) ?? start

        var value: Double?
        var unit: String?
        if let quantity = object["quantity"] as? [String: Any] {
            value = numeric(quantity["value"])
            unit = quantity["unit"] as? String
        } else {
            value = numeric(object["value"])
            unit = object["unit"] as? String
        }

        var sourceName: String?
        if let source = object["source"] as? [String: Any] {
            sourceName = source["name"] as? String
        } else {
            sourceName = object["sourceName"] as? String
        }

        let raw = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()

        return HealthRecord(
            id: id,
            type: type,
            kind: object["kind"] as? String,
            startDate: start,
            endDate: end,
            value: value,
            unit: unit,
            sourceName: sourceName,
            raw: raw
        )
    }

    /// The metrics shape carries no per-sample identifier, so one is derived
    /// from the type and timestamp. That is what makes re-delivering the same
    /// metric update a row rather than duplicate it.
    private static func parseMetricsEnvelope(_ text: String) -> ParsedBatch {
        guard
            let data = text.data(using: .utf8),
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = envelope["data"] as? [String: Any]
        else {
            return ParsedBatch(records: [], deletions: [], unreadableCount: 1)
        }

        var records: [HealthRecord] = []
        var unreadable = 0
        for metric in payload["metrics"] as? [[String: Any]] ?? [] {
            let name = metric["name"] as? String ?? "unknown"
            let units = metric["units"] as? String
            for point in metric["data"] as? [[String: Any]] ?? [] {
                guard
                    let dateText = point["date"] as? String,
                    let date = Timestamps.date(from: dateText)
                else {
                    unreadable += 1
                    continue
                }
                let end = (point["endDate"] as? String)
                    .flatMap(Timestamps.date(from:)) ?? date
                let identifier = "\(name):\(dateText)"
                var object: [String: Any] = [
                    "id": identifier,
                    "type": name,
                    "startDate": dateText
                ]
                if let quantity = numeric(point["qty"]) {
                    object["value"] = quantity
                }
                if let units {
                    object["unit"] = units
                }
                records.append(
                    HealthRecord(
                        id: identifier,
                        type: name,
                        kind: "quantity",
                        startDate: date,
                        endDate: end,
                        value: numeric(point["qty"]),
                        unit: units,
                        sourceName: point["source"] as? String,
                        raw: (try? JSONSerialization.data(
                            withJSONObject: object,
                            options: [.sortedKeys]
                        )) ?? Data()
                    )
                )
            }
        }

        var deletions: [HealthDeletion] = []
        for deletion in payload["deletions"] as? [[String: Any]] ?? [] {
            guard
                let name = (deletion["name"] as? String) ?? (deletion["type"] as? String),
                let dateText = deletion["date"] as? String,
                let date = Timestamps.date(from: dateText)
            else {
                continue
            }
            deletions.append(
                HealthDeletion(id: "\(name):\(dateText)", type: name, startDate: date)
            )
        }

        return ParsedBatch(
            records: records,
            deletions: deletions,
            unreadableCount: unreadable
        )
    }

    private static func parseCSV(_ text: String) -> ParsedBatch {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            return ParsedBatch(records: [], deletions: [], unreadableCount: 0)
        }
        let header = CSV.fields(in: String(lines.removeFirst()))

        var records: [HealthRecord] = []
        var deletions: [HealthDeletion] = []
        var unreadable = 0

        for line in lines {
            let fields = CSV.fields(in: String(line))
            guard fields.count == header.count else {
                unreadable += 1
                continue
            }
            var object: [String: Any] = [:]
            for (key, field) in zip(header, fields) where !field.isEmpty {
                object[key] = field
            }
            if let deleted = object["deleted"] as? String,
               deleted == "true" || deleted == "1",
               let id = object["id"] as? String {
                deletions.append(
                    HealthDeletion(id: id, type: object["type"] as? String)
                )
                continue
            }
            // CSV carries every field as text, so the numeric column is
            // converted before the shared decoder sees it.
            if let raw = object["value"] as? String, let number = Double(raw) {
                object["value"] = number
            }
            guard let record = record(from: object) else {
                unreadable += 1
                continue
            }
            records.append(record)
        }

        return ParsedBatch(
            records: records,
            deletions: deletions,
            unreadableCount: unreadable
        )
    }

    private static func numeric(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: number
        case let number as Int: Double(number)
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text)
        default: nil
        }
    }
}

/// Parses and writes the timestamp formats Hozz emits.
///
/// `ISO8601FormatStyle` is a value type, so unlike a shared `DateFormatter` it
/// carries no mutable state across threads — which matters here because
/// batches are parsed off the network on whichever queue delivered them.
public enum Timestamps {
    private static let fractional = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )
    private static let whole = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false,
        timeZone: .gmt
    )

    public static func date(from text: String) -> Date? {
        // Both are tried because Hozz writes fractional seconds but other
        // producers pointed at the same receiver frequently do not.
        if let parsed = try? fractional.parse(text) {
            return parsed
        }
        return try? whole.parse(text)
    }

    public static func text(from date: Date) -> String {
        fractional.format(date)
    }
}

/// Minimal RFC 4180 field splitting, enough for the CSV Hozz writes.
enum CSV {
    static func fields(in line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var isQuoted = false
        var iterator = line.makeIterator()

        while let character = iterator.next() {
            if isQuoted {
                if character == "\"" {
                    // A doubled quote inside a quoted field is a literal quote.
                    if let next = iterator.next() {
                        if next == "\"" {
                            current.append("\"")
                        } else if next == "," {
                            fields.append(current)
                            current = ""
                            isQuoted = false
                        } else {
                            isQuoted = false
                            current.append(next)
                        }
                    } else {
                        isQuoted = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"", current.isEmpty {
                isQuoted = true
            } else if character == "," {
                fields.append(current)
                current = ""
            } else if character != "\r" {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}
