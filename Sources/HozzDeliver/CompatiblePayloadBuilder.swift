import Foundation

/// Builds the payload shape used by the widely deployed Health Auto Export
/// schema, so existing receivers keep working.
///
/// Anyone who has already wired up a Home Assistant integration, a Grafana
/// dashboard, or the community ingest server should be able to point it at Hozz
/// and have it keep working. Interoperability is the point; a free tool that
/// forces everyone to rewrite their pipeline is not actually cheaper.
///
/// One deliberate difference: Hozz sends the individual samples HealthKit
/// returned, not hourly or daily rollups. That schema's own "summarize off"
/// mode does the same, so receivers already handle it, and it is the only
/// option that can honestly claim no gaps and no duplicates.
public enum CompatiblePayloadBuilder {
    /// One decoded record from Hozz's canonical NDJSON.
    public struct Record: Sendable {
        public let identifier: String
        public let typeIdentifier: String
        public let kind: String
        public let startDate: String
        public let endDate: String
        public let value: Double?
        public let unit: String?
        public let sourceName: String?
        public let isDeletion: Bool

        public init(
            identifier: String,
            typeIdentifier: String,
            kind: String,
            startDate: String,
            endDate: String,
            value: Double?,
            unit: String?,
            sourceName: String?,
            isDeletion: Bool
        ) {
            self.identifier = identifier
            self.typeIdentifier = typeIdentifier
            self.kind = kind
            self.startDate = startDate
            self.endDate = endDate
            self.value = value
            self.unit = unit
            self.sourceName = sourceName
            self.isDeletion = isDeletion
        }
    }

    public static func build(records: [Record]) throws -> Data {
        var metrics: [String: (units: String, points: [[String: Any]])] = [:]
        var workouts: [[String: Any]] = []
        var deletions: [[String: Any]] = []

        for record in records {
            if record.isDeletion {
                // Deletions have no equivalent in the original schema, so they
                // are carried alongside rather than silently dropped. A
                // receiver that ignores the key behaves exactly as before.
                deletions.append([
                    "id": record.identifier,
                    "name": MetricNameMap.metricName(for: record.typeIdentifier),
                    "type": record.typeIdentifier,
                    "date": record.startDate
                ])
                continue
            }

            if record.kind == "workout" {
                workouts.append([
                    "id": record.identifier,
                    "name": "Workout",
                    "start": record.startDate,
                    "end": record.endDate
                ])
                continue
            }

            let name = MetricNameMap.metricName(for: record.typeIdentifier)
            let units = record.unit ?? "count"
            var point: [String: Any] = [
                "date": record.startDate,
                "units": units
            ]
            if let value = record.value {
                point["qty"] = value
            }
            if let sourceName = record.sourceName {
                point["source"] = sourceName
            }
            // Hozz sends individual samples, so start and end can differ. The
            // original schema has no field for that, and dropping it would
            // silently narrow an interval sample to a point.
            if record.endDate != record.startDate {
                point["endDate"] = record.endDate
            }

            metrics[name, default: (units: units, points: [])].points.append(point)
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

    /// Decodes one line of Hozz's canonical NDJSON.
    public static func record(from line: Data) -> Record? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line)
                as? [String: Any],
            let kind = object["kind"] as? String,
            let type = object["type"] as? String
        else {
            return nil
        }

        let quantity = object["quantity"] as? [String: Any]
        let source = object["source"] as? [String: Any]
        let value: Double? = switch quantity?["value"] ?? object["value"] {
        case let number as Double: number
        case let number as Int: Double(number)
        case let number as NSNumber: number.doubleValue
        default: nil
        }

        return Record(
            identifier: object["id"] as? String ?? "",
            typeIdentifier: type,
            kind: kind,
            startDate: object["startDate"] as? String ?? "",
            endDate: object["endDate"] as? String ?? "",
            value: value,
            unit: quantity?["unit"] as? String,
            sourceName: source?["name"] as? String,
            isDeletion: kind == "deletion"
        )
    }
}
