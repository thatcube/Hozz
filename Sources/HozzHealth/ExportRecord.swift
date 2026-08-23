import Foundation

/// One spool line, projected into the handful of fields a presentation format
/// needs.
///
/// The projection is deliberately shallow. `object` and `raw` keep the original
/// record intact, so a format that can carry everything — SQLite does — stores
/// the untouched JSON alongside the extracted columns and loses nothing, while
/// a format that cannot — Markdown — has somewhere honest to say so.
///
/// Nothing here reaches into `HealthSampleEncoder`. It reads whatever that
/// encoder produced, and an unrecognised `kind` is carried through rather than
/// dropped.
struct ExportRecord {
    /// Record kinds that describe the run rather than the user's health data.
    static let runKinds: Set<String> = [
        "manifest",
        "resume",
        "typeSummary",
        "typeError",
        "completion"
    ]

    let raw: Data
    let object: [String: Any]
    let kind: String

    init?(line: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: line)
                as? [String: Any],
            let kind = object["kind"] as? String
        else {
            return nil
        }
        self.raw = line
        self.object = object
        self.kind = kind
    }

    var isRunRecord: Bool {
        Self.runKinds.contains(kind)
    }

    var id: String? { object["id"] as? String }
    var type: String? { object["type"] as? String }

    var startDate: Date? { Self.date(object["startDate"]) }
    var endDate: Date? { Self.date(object["endDate"]) }

    /// The numeric value a row can be aggregated on, when the kind has one.
    ///
    /// A category value is an enumeration rather than a measurement, so it is
    /// returned but left without a unit — which is exactly how a query should
    /// see it.
    var value: Double? {
        switch kind {
        case "quantity":
            guard let quantity = object["quantity"] as? [String: Any] else {
                return nil
            }
            return Self.number(quantity["value"])
        case "category":
            return Self.number(object["value"])
        default:
            return nil
        }
    }

    var unit: String? {
        guard
            kind == "quantity",
            let quantity = object["quantity"] as? [String: Any]
        else {
            return nil
        }
        return quantity["unit"] as? String
    }

    var duration: Double? {
        kind == "workout" ? Self.number(object["duration"]) : nil
    }

    var activityType: Int64? {
        guard kind == "workout", let number = Self.number(object["activityType"])
        else {
            return nil
        }
        return Int64(number)
    }

    var workoutEvents: [[String: Any]] {
        object["events"] as? [[String: Any]] ?? []
    }

    private var source: [String: Any] { object["source"] as? [String: Any] ?? [:] }
    private var device: [String: Any] { object["device"] as? [String: Any] ?? [:] }

    var sourceName: String? { source["name"] as? String }
    var sourceBundleIdentifier: String? { source["bundleIdentifier"] as? String }
    var sourceVersion: String? { source["version"] as? String }
    var deviceName: String? { device["name"] as? String }
    var deviceManufacturer: String? { device["manufacturer"] as? String }
    var deviceModel: String? { device["model"] as? String }

    var metadataJSON: String? {
        Self.compactJSON(object["metadata"])
    }

    var message: String? { object["message"] as? String }

    /// A metadata value that was tagged by the encoder, unwrapped to plain text.
    func metadataString(_ key: String) -> String? {
        guard
            let metadata = object["metadata"] as? [String: Any],
            let tagged = metadata[key] as? [String: Any]
        else {
            return nil
        }
        if let text = tagged["value"] as? String {
            return text
        }
        if let number = Self.number(tagged["value"]) {
            return Self.plain(number)
        }
        return tagged["description"] as? String
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        default: nil
        }
    }

    /// Formats a number the way a person writing it down would.
    static func plain(_ value: Double) -> String {
        guard value.isFinite else {
            return "\(value)"
        }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.2f", value)
    }

    static func compactJSON(_ value: Any?) -> String? {
        guard
            let value,
            JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
            let text = String(data: data, encoding: .utf8),
            text != "{}", text != "[]"
        else {
            return nil
        }
        return text
    }

    private static let fractional = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true,
        timeZone: .gmt
    )
    private static let whole = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false,
        timeZone: .gmt
    )

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else {
            return nil
        }
        // Hozz writes fractional seconds; the whole-second form is accepted so
        // a spool written by an older build still reads.
        if let parsed = try? fractional.parse(text) {
            return parsed
        }
        return try? whole.parse(text)
    }

    static func timestamp(_ date: Date) -> String {
        fractional.format(date)
    }
}

/// Turns instants into the calendar day a person actually lived them in.
///
/// Health timestamps are UTC, and a UTC day is the wrong bucket for a summary:
/// an evening run in California lands on the following day, and the day it is
/// filed under is the one nobody was awake for. Every day-grouped output
/// therefore uses a real time zone and records which one it used, so a file
/// that is read years later still explains itself.
///
/// The conversion is arithmetic rather than `Calendar`-based because it runs
/// once per record — millions of times in a large export — and because the only
/// question being asked is which day a wall-clock instant fell on.
struct LocalDayFormatter {
    let timeZone: TimeZone
    private var cache: [Int: String] = [:]

    init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    /// The `YYYY-MM-DD` day `date` fell on locally.
    mutating func day(for date: Date) -> String {
        let local = date.timeIntervalSince1970
            + Double(timeZone.secondsFromGMT(for: date))
        let dayNumber = Int((local / 86_400).rounded(.down))
        if let cached = cache[dayNumber] {
            return cached
        }
        let text = Self.text(forDayNumber: dayNumber)
        // Bounded by the number of distinct days an export covers, which is
        // years of history at worst.
        cache[dayNumber] = text
        return text
    }

    /// Days since the Unix epoch for a `YYYY-MM-DD` string.
    static func dayNumber(for text: String) -> Int? {
        let parts = text.split(separator: "-")
        guard
            parts.count == 3,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2])
        else {
            return nil
        }
        return daysFromCivil(year: year, month: month, day: day)
    }

    static func text(forDayNumber dayNumber: Int) -> String {
        let civil = civilFromDays(dayNumber)
        return String(
            format: "%04d-%02d-%02d",
            civil.year,
            civil.month,
            civil.day
        )
    }

    /// Howard Hinnant's `civil_from_days`, which is exact for every day in
    /// range and needs no calendar lookup.
    static func civilFromDays(_ dayNumber: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = dayNumber + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096)
            / 365
        let year = yearOfEra + era * 400
        let dayOfYear =
            dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        return (month <= 2 ? year + 1 : year, month, day)
    }

    /// The inverse, so a day string can be turned back into an instant.
    static func daysFromCivil(year y: Int, month m: Int, day d: Int) -> Int {
        let year = m <= 2 ? y - 1 : y
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let dayOfYear = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let dayOfEra =
            yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
