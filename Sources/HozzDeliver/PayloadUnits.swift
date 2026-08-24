import Foundation

/// Rewrites the values in an encoded payload into a destination's chosen units.
///
/// The rule the whole file is written to: **a value and its unit move
/// together, always, in the same edit.** A number changed without its label is
/// not a conversion, it is a wrong reading with a plausible name on it, and for
/// health data that is the worst outcome available. Every path below either
/// writes both or writes neither.
///
/// The second rule is that a conversion is visible. A record whose value was
/// converted also carries the unit it came from, so a receiver comparing today's
/// batch with last month's can tell that the meaning of the column changed and
/// is not left to infer it from the numbers.
public enum PayloadUnits {
    /// Whether Hozz can express a destination's unit choices in this format.
    ///
    /// Line protocol is deliberately absent. It carries the unit as a tag and
    /// the value as a field, both inside a line whose escaping rules differ by
    /// position, and rewriting one in place is exactly the kind of edit that
    /// silently corrupts a batch InfluxDB then rejects whole. The setting is not
    /// offered there rather than being offered and quietly not applied.
    public static func applies(to format: DeliveryFormat) -> Bool {
        format != .influx
    }

    /// Converts every value in the payload it can, leaving the rest alone.
    ///
    /// Returns the payload unchanged when there is nothing to do, so a
    /// destination with no preferences is byte-for-byte what it was before this
    /// existed.
    public static func apply(
        _ preferences: UnitPreferences,
        to payload: Data,
        format: DeliveryFormat
    ) -> Data {
        guard !preferences.isEmpty, applies(to: format), !payload.isEmpty else {
            return payload
        }
        switch format {
        case .ndjson, .json:
            return canonical(preferences, payload: payload, format: format)
        case .csv:
            return csv(preferences, payload: payload)
        case .metrics:
            return metrics(preferences, payload: payload)
        case .influx:
            return payload
        }
    }

    // MARK: - NDJSON and JSON

    private static func canonical(
        _ preferences: UnitPreferences,
        payload: Data,
        format: DeliveryFormat
    ) -> Data {
        guard let division = PayloadDivision.decompose(payload, format: format) else {
            return payload
        }
        let rewritten = division.records.map { record -> PayloadDivision.Record in
            guard
                case .line(let line) = record.content,
                let converted = convert(line: line, preferences: preferences)
            else {
                return record
            }
            return PayloadDivision.Record(date: record.date, content: .line(converted))
        }
        return division.recompose(rewritten)
    }

    /// One canonical record, with its quantity converted.
    private static func convert(
        line: Data,
        preferences: UnitPreferences
    ) -> Data? {
        guard
            var object = try? JSONSerialization.jsonObject(with: line)
                as? [String: Any],
            var quantity = object["quantity"] as? [String: Any],
            let unit = quantity["unit"] as? String,
            let value = number(quantity["value"]),
            let type = object["type"] as? String,
            let target = preferences.target(for: unit, typeIdentifier: type),
            let converted = HealthUnit.convert(value, from: unit, to: target)
        else {
            return nil
        }

        quantity["value"] = converted
        quantity["unit"] = target
        // HealthKit's own rendering was of the original number in the original
        // unit. Left alone it would contradict the two fields beside it, which
        // is worse than losing it, so it is rewritten to match.
        quantity["description"] = "\(converted) \(target)"
        // What it was, so a receiver can tell a converted reading from one that
        // arrived in this unit to begin with.
        quantity["convertedFrom"] = unit
        object["quantity"] = quantity

        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    // MARK: - CSV

    /// The flat CSV's columns, as `DeliveryPayloadBuilder` writes them.
    private static let typeColumn = 1
    private static let valueColumn = 5
    private static let unitColumn = 6

    private static func csv(
        _ preferences: UnitPreferences,
        payload: Data
    ) -> Data {
        guard let division = PayloadDivision.decompose(payload, format: .csv) else {
            return payload
        }
        let rewritten = division.records.map { record -> PayloadDivision.Record in
            guard
                case .line(let row) = record.content,
                let text = String(data: row, encoding: .utf8)
            else {
                return record
            }
            var fields = PayloadDivision.csvFields(text)
            guard
                fields.count > unitColumn,
                let value = Double(fields[valueColumn]),
                let target = preferences.target(
                    for: fields[unitColumn],
                    typeIdentifier: fields[typeColumn]
                ),
                let converted = HealthUnit.convert(
                    value,
                    from: fields[unitColumn],
                    to: target
                )
            else {
                return record
            }
            fields[valueColumn] = format(converted)
            fields[unitColumn] = target
            let line = Data(fields.map(escape).joined(separator: ",").utf8)
            return PayloadDivision.Record(date: record.date, content: .line(line))
        }
        return division.recompose(rewritten)
    }

    /// Matches how the builder writes a number, so a converted row looks like
    /// every other row rather than announcing itself with a different spelling.
    private static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int64(value))
            : String(value)
    }

    private static func escape(_ field: String) -> String {
        guard
            field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Metrics JSON

    /// Grouped payloads carry the unit twice — once on the metric and once on
    /// every point — and both have to move or the two disagree about what the
    /// numbers mean.
    private static func metrics(
        _ preferences: UnitPreferences,
        payload: Data
    ) -> Data {
        guard
            var root = try? JSONSerialization.jsonObject(with: payload)
                as? [String: Any],
            var data = root["data"] as? [String: Any],
            let metrics = data["metrics"] as? [[String: Any]]
        else {
            return payload
        }

        let rewritten = metrics.map { metric -> [String: Any] in
            guard
                var metric = metric as [String: Any]?,
                let unit = metric["units"] as? String,
                let name = metric["name"] as? String,
                let target = preferences.target(
                    for: unit,
                    typeIdentifier: MetricNameMap.typeIdentifier(for: name) ?? name
                )
            else {
                return metric
            }

            var converted = true
            let points = (metric["data"] as? [[String: Any]] ?? []).map {
                point -> [String: Any] in
                var point = point
                guard
                    let value = number(point["qty"]),
                    let result = HealthUnit.convert(value, from: unit, to: target)
                else {
                    // A point that could not be converted keeps its number, so
                    // the metric must keep its unit too — otherwise this one
                    // point would be relabelled without being changed.
                    if point["qty"] != nil {
                        converted = false
                    }
                    return point
                }
                point["qty"] = result
                return point
            }

            guard converted else {
                return metric
            }
            metric["data"] = points
            metric["units"] = target
            metric["convertedFrom"] = unit
            return metric
        }

        data["metrics"] = rewritten
        root["data"] = data
        return (
            try? JSONSerialization.data(
                withJSONObject: root,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        ) ?? payload
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        default: nil
        }
    }
}
