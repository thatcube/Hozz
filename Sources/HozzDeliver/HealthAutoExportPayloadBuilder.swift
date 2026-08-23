import Foundation

/// Builds a payload using Health Auto Export's published field names.
///
/// This exists for one reason: the people most likely to try Hozz already have
/// something working. Health Auto Export is the paid app in this space, and its
/// users have Home Assistant automations, MQTT subscribers, Node-RED flows, and
/// scripts keyed to its field names. Asking them to rewrite all of that in
/// order to move to a free tool is a real reason not to move.
///
/// It is opt-in and it is not the default. Hozz's own schema is documented,
/// keeps more of what Health returned, and is the one to build against. This is
/// a bridge for pipelines that already exist.
///
/// **What is matched, and from where.** Everything below follows the published
/// format at `help.healthyapps.dev/en/health-auto-export/export-format/`:
/// the `data.metrics[].{name, units, data}` envelope, the
/// `yyyy-MM-dd HH:mm:ss Z` timestamp, `qty`, the capitalised `Min`/`Avg`/`Max`
/// on heart rate points, and the sleep point's `startDate`/`endDate`/`value`.
///
/// **What is deliberately not claimed.** Hozz sends the individual samples
/// HealthKit returned rather than hourly or daily rollups, because that is the
/// only shape that can honestly say it has no gaps and no duplicates. So a
/// heart rate point carries the same number in `Min`, `Avg`, and `Max` — that
/// is what one sample means — and the aggregated sleep shape, which only exists
/// for summarised exports, is not produced at all. Blood pressure is published
/// as separate systolic and diastolic metrics rather than paired on one point,
/// because pairing them would mean guessing which two samples belong together.
/// The per-point extras that come from Health metadata — `mealTime`, `reason`,
/// and the sexual-activity keys — are not emitted, because Hozz's delivery
/// batches do not carry that metadata.
public enum HealthAutoExportPayloadBuilder {
    /// Health Auto Export's timestamp format: local time, space separated, with
    /// a numeric offset and no colon. Notably not ISO 8601, which is the
    /// mistake that makes a consumer's parser fail on the first point.
    public static let dateFormat = "yyyy-MM-dd HH:mm:ss Z"

    public static func build(
        records: [CompatiblePayloadBuilder.Record],
        timeZone: TimeZone = .current
    ) throws -> Data {
        let formatter = formatter(for: timeZone)
        var metrics: [String: (units: String, points: [[String: Any]])] = [:]
        var workouts: [[String: Any]] = []
        var deletions: [[String: Any]] = []

        for record in records {
            if record.isDeletion {
                // Health Auto Export has no equivalent, so this key is a Hozz
                // addition. A consumer written for their format ignores a key
                // it does not know; dropping tombstones instead would leave a
                // receiver showing data the user deliberately removed.
                deletions.append([
                    "id": record.identifier,
                    "name": record.metricName,
                    "type": record.typeIdentifier,
                    "date": formatter.string(for: record.startDate) ?? ""
                ])
                continue
            }

            if record.kind == "workout" {
                workouts.append(workout(record, formatter: formatter))
                continue
            }

            let name = record.metricName
            let units = self.units(for: name, unit: record.unit)
            metrics[name, default: (units: units, points: [])].points.append(
                point(record, name: name, formatter: formatter)
            )
        }

        let metricsArray = metrics
            .sorted { $0.key < $1.key }
            .map { name, value in
                [
                    "name": name,
                    "units": value.units,
                    "data": value.points
                ] as [String: Any]
            }

        var data: [String: Any] = ["metrics": metricsArray]
        if !workouts.isEmpty {
            data["workouts"] = workouts
        }
        if !deletions.isEmpty {
            data["deletions"] = deletions
        }

        return try JSONSerialization.data(
            withJSONObject: ["data": data],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - Points

    private static func point(
        _ record: CompatiblePayloadBuilder.Record,
        name: String,
        formatter: PointFormatter
    ) -> [String: Any] {
        if name == sleepMetric {
            return sleepPoint(record, formatter: formatter)
        }

        var point: [String: Any] = [
            "date": formatter.string(for: record.startDate) ?? record.startDate
        ]
        if let value = record.value {
            if name == heartRateMetric {
                // Their heart rate points carry a range rather than a single
                // quantity, and the keys really are capitalised. One sample is
                // its own minimum, average, and maximum.
                point["Min"] = value
                point["Avg"] = value
                point["Max"] = value
            } else {
                point["qty"] = value
            }
        }
        if let source = record.sourceName {
            point["source"] = source
        }
        // Not part of their format. Hozz sends samples rather than rollups, and
        // an interval sample flattened to an instant would quietly lose the
        // span it covered.
        if record.endDate != record.startDate {
            point["endDate"] = formatter.string(for: record.endDate) ?? record.endDate
        }
        return point
    }

    /// A single sleep segment, in the shape their unaggregated export uses.
    private static func sleepPoint(
        _ record: CompatiblePayloadBuilder.Record,
        formatter: PointFormatter
    ) -> [String: Any] {
        var point: [String: Any] = [
            "startDate": formatter.string(for: record.startDate) ?? record.startDate,
            "endDate": formatter.string(for: record.endDate) ?? record.endDate
        ]
        if let hours = formatter.hours(from: record.startDate, to: record.endDate) {
            point["qty"] = hours
        }
        if let stage = record.value.map({ sleepStage(Int($0)) }) {
            point["value"] = stage
        }
        if let source = record.sourceName {
            point["source"] = source
        }
        return point
    }

    private static func workout(
        _ record: CompatiblePayloadBuilder.Record,
        formatter: PointFormatter
    ) -> [String: Any] {
        var workout: [String: Any] = [
            "id": record.identifier,
            "start": formatter.string(for: record.startDate) ?? record.startDate,
            "end": formatter.string(for: record.endDate) ?? record.endDate
        ]
        // Their workouts are named by activity, not by HealthKit identifier.
        workout["name"] = record.activityType.map(WorkoutActivityNames.label(for:))
            ?? "Workout"
        // Seconds, as their format specifies.
        if let duration = record.duration
            ?? formatter.seconds(from: record.startDate, to: record.endDate) {
            workout["duration"] = duration
        }
        if let source = record.sourceName {
            workout["source"] = source
        }
        return workout
    }

    // MARK: - Names and units

    static let heartRateMetric = "heart_rate"
    static let sleepMetric = "sleep_analysis"

    /// Their unit spelling, where Hozz's differs and theirs is documented.
    ///
    /// Only translations taken from their published format are made. A unit
    /// nobody has written down is passed through as HealthKit spelled it,
    /// rather than being invented into something that looks compatible.
    static func units(for metric: String, unit: String?) -> String {
        if metric == sleepMetric {
            return "hr"
        }
        guard let unit, !unit.isEmpty else {
            return "count"
        }
        return unit == "count/min" ? "bpm" : unit
    }

    /// `HKCategoryValueSleepAnalysis` in their vocabulary.
    static func sleepStage(_ rawValue: Int) -> String {
        switch rawValue {
        case 0:
            "In Bed"
        case 1:
            "Asleep"
        case 2:
            "Awake"
        case 3:
            "Core"
        case 4:
            "Deep"
        case 5:
            "REM"
        default:
            "Unspecified"
        }
    }

    // MARK: - Dates

    static func formatter(for timeZone: TimeZone) -> PointFormatter {
        PointFormatter(timeZone: timeZone)
    }

    /// Converts Hozz's ISO 8601 timestamps into their local-time format.
    public struct PointFormatter: Sendable {
        private let formatter: DateFormatter

        init(timeZone: TimeZone) {
            let formatter = DateFormatter()
            // A fixed format needs a fixed locale, or a phone set to a
            // non-Gregorian calendar produces dates nothing can parse.
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = HealthAutoExportPayloadBuilder.dateFormat
            self.formatter = formatter
        }

        func string(for iso: String) -> String? {
            InfluxLineProtocol.date(from: iso).map(formatter.string(from:))
        }

        func seconds(from start: String, to end: String) -> Double? {
            guard
                let start = InfluxLineProtocol.date(from: start),
                let end = InfluxLineProtocol.date(from: end)
            else {
                return nil
            }
            let seconds = end.timeIntervalSince(start)
            return seconds >= 0 ? seconds : nil
        }

        func hours(from start: String, to end: String) -> Double? {
            seconds(from: start, to: end).map { $0 / 3_600 }
        }
    }
}
