import Foundation
import HozzCore
import HozzStore

/// A workout's recorded path.
///
/// Locations arrive in pages, the same way an electrocardiogram's voltages do,
/// and the same rule applies: a path assembled from pages that are still on
/// their way is not the route that was walked. A gap in the middle of a run
/// draws as a straight line across a park, which is a plausible-looking lie
/// about where somebody went, so it is reported instead of smoothed over.
public struct WorkoutRoute: Sendable, Hashable {
    public struct Point: Sendable, Hashable {
        public let latitude: Double
        public let longitude: Double
        public let altitude: Double?
        public let timestamp: Date?
        public let speed: Double?

        public init(
            latitude: Double,
            longitude: Double,
            altitude: Double?,
            timestamp: Date?,
            speed: Double?
        ) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
            self.timestamp = timestamp
            self.speed = speed
        }
    }

    public let points: [Point]
    /// Whether every page between the first and the last is present.
    public let isComplete: Bool
    /// How many pages were expected to be contiguous but were not.
    public let missingPages: Int

    public init(points: [Point], isComplete: Bool, missingPages: Int) {
        self.points = points
        self.isComplete = isComplete
        self.missingPages = missingPages
    }

    public var isEmpty: Bool { points.isEmpty }
}

extension IngestStore {
    /// The route recorded for a workout, if one was.
    ///
    /// Routes are ordinary samples carrying the workout they belong to, and
    /// their locations are further samples carrying the route they belong to.
    /// Both links live in the stored JSON rather than in columns, so both are
    /// read out of it — the schema is another agent's to change, not this
    /// query's.
    public func route(forWorkout workoutID: String) throws -> WorkoutRoute? {
        let routeIDs = try database.query(
            """
            SELECT id FROM sample
             WHERE type = 'HKWorkoutRouteTypeIdentifier'
               AND kind = 'workoutRoute'
               AND json_extract(CAST(raw AS TEXT), '$.workout.id') = ?
             ORDER BY start_date
            """,
            [.text(workoutID)],
            row: { $0.text(0) }
        )
        guard !routeIDs.isEmpty else {
            return nil
        }

        var points: [WorkoutRoute.Point] = []
        var missingPages = 0

        for routeID in routeIDs {
            let pages = try database.query(
                """
                SELECT json_extract(CAST(raw AS TEXT), '$.offset'),
                       json_extract(CAST(raw AS TEXT), '$.count'),
                       raw
                  FROM sample
                 WHERE kind = 'workoutRouteLocations'
                   AND json_extract(CAST(raw AS TEXT), '$.sample') = ?
                 ORDER BY json_extract(CAST(raw AS TEXT), '$.offset')
                """,
                [.text(routeID)],
                row: {
                    (
                        offset: Int($0.optionalReal(0) ?? 0),
                        count: Int($0.optionalReal(1) ?? 0),
                        raw: $0.blob(2) ?? Data()
                    )
                }
            )

            var nextOffset = 0
            for page in pages {
                if page.offset != nextOffset {
                    // A page between the last one and this never arrived. The
                    // locations that did are still shown; the gap is what makes
                    // the route incomplete.
                    missingPages += 1
                }
                points.append(contentsOf: Self.locations(in: page.raw))
                nextOffset = page.offset + page.count
            }
        }

        guard !points.isEmpty else {
            return nil
        }
        return WorkoutRoute(
            points: points,
            isComplete: missingPages == 0,
            missingPages: missingPages
        )
    }

    private static func locations(in raw: Data) -> [WorkoutRoute.Point] {
        guard
            let object = try? JSONSerialization.jsonObject(with: raw),
            let root = object as? [String: Any],
            let entries = root["locations"] as? [[String: Any]]
        else {
            return []
        }
        return entries.compactMap { entry in
            guard
                let latitude = entry["latitude"] as? Double,
                let longitude = entry["longitude"] as? Double
            else {
                return nil
            }
            return WorkoutRoute.Point(
                latitude: latitude,
                longitude: longitude,
                altitude: entry["altitude"] as? Double,
                timestamp: (entry["timestamp"] as? String)
                    .flatMap(Timestamps.date(from:)),
                speed: entry["speed"] as? Double
            )
        }
    }

    /// Heart rate through one workout, as it was actually measured.
    ///
    /// Read from the samples that fall inside the workout rather than from the
    /// workout's own statistics, because the statistics carry an average and
    /// this is the shape underneath it.
    public func heartRate(
        duringWorkout workoutID: String
    ) throws -> [(at: Date, beatsPerMinute: Double)] {
        let bounds = try database.query(
            "SELECT start_date, end_date FROM workout_detail WHERE id = ?",
            [.text(workoutID)],
            row: { ($0.text(0), $0.optionalText(1)) }
        ).first
        guard let bounds, let end = bounds.1 else {
            return []
        }

        return try database.query(
            """
            SELECT start_date, value, unit FROM sample
             WHERE type = 'HKQuantityTypeIdentifierHeartRate'
               AND start_date >= ? AND start_date <= ?
               AND value IS NOT NULL
             ORDER BY start_date
            """,
            [.text(bounds.0), .text(end)]
        ) { row in
            // Health's canonical unit for a pulse is per second; anything
            // already per minute is left alone rather than multiplied twice.
            let value = row.real(1)
            let unit = row.optionalText(2)
            return (
                at: Timestamps.date(from: row.text(0)) ?? .distantPast,
                beatsPerMinute: unit == "count/min" ? value : value * 60
            )
        }
    }
}
