import CryptoKit
import Foundation
import HozzCatalog
import HozzCore

/// One point from a workout route, as a value.
///
/// `CLLocation` is a reference type handed over on HealthKit's own queue.
/// Converting each point where it arrives keeps Core Location objects from
/// escaping that queue, and makes the encoding testable without a device.
public struct RouteLocation: Equatable, Sendable {
    public let timestamp: Date
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let ellipsoidalAltitude: Double?
    public let horizontalAccuracy: Double
    public let verticalAccuracy: Double
    public let course: Double
    public let courseAccuracy: Double
    public let speed: Double
    public let speedAccuracy: Double
    public let floor: Int?
    public let isSimulatedBySoftware: Bool?
    public let isProducedByAccessory: Bool?

    public init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        altitude: Double,
        ellipsoidalAltitude: Double? = nil,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        course: Double,
        courseAccuracy: Double,
        speed: Double,
        speedAccuracy: Double,
        floor: Int? = nil,
        isSimulatedBySoftware: Bool? = nil,
        isProducedByAccessory: Bool? = nil
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.ellipsoidalAltitude = ellipsoidalAltitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.floor = floor
        self.isSimulatedBySoftware = isSimulatedBySoftware
        self.isProducedByAccessory = isProducedByAccessory
    }
}

/// What Hozz could establish about the workout a route belongs to.
public enum RouteWorkoutLink: Equatable, Sendable {
    case resolved(
        id: UUID,
        activityType: UInt,
        startDate: Date,
        endDate: Date
    )
    /// No workout claimed this route. Reported rather than guessed.
    case unresolved(reason: String)
}

/// Builds the records a workout route contributes to an export.
///
/// A route is written as a header, then a run of location pages, then an end
/// marker. Splitting it up is what keeps a long ride out of memory, and the
/// split is by **absolute offset** rather than by however far a given pass
/// happened to get. That matters: a run interrupted halfway and resumed would
/// otherwise re-chunk the remaining points differently, give them different
/// identifiers, and land at the receiver as new records rather than as the
/// same ones. Fixed offsets make a replayed page byte-identical to the page it
/// replaces.
public enum WorkoutRouteEncoding {
    public static let typeIdentifier = "HKWorkoutRouteTypeIdentifier"
    public static let typeKey = HealthTypeKey(typeIdentifier)

    /// Points per location record. Roughly 70 KB of JSON, small enough that a
    /// handful in flight is nothing, large enough that a long ride does not
    /// become a million lines.
    public static let locationsPerRecord = 500

    /// Location records handed back in one drain page, which is what bounds
    /// how much of a route is ever in memory at once.
    public static let recordsPerPage = 8

    public struct Header: Equatable, Sendable {
        public let id: UUID
        public let startDate: Date
        public let endDate: Date
        /// The route's own fields, already encoded on HealthKit's queue.
        public let basePayload: Data

        public init(
            id: UUID,
            startDate: Date,
            endDate: Date,
            basePayload: Data
        ) {
            self.id = id
            self.startDate = startDate
            self.endDate = endDate
            self.basePayload = basePayload
        }
    }

    // MARK: - Records

    /// The route's own fields, encoded where HealthKit handed the sample over.
    ///
    /// Kept as bytes rather than a dictionary because the metadata of an
    /// arbitrary sample is not a `Sendable` value, and the whole point of
    /// encoding inside the query callback is that no `HKSample` escapes
    /// HealthKit's queue. The workout link needs queries of its own, so it is
    /// resolved afterwards and merged in here.
    public static func headerChange(
        id: UUID,
        basePayload: Data,
        workout: RouteWorkoutLink
    ) throws -> HealthChange {
        guard
            var object = try JSONSerialization.jsonObject(with: basePayload)
                as? [String: Any]
        else {
            throw HealthSampleEncodingError.invalidJSONObject
        }
        object["kind"] = "workoutRoute"
        object["schemaVersion"] = 1
        object["catalogVersion"] = HealthTypeCatalog.version
        object["id"] = id.uuidString.lowercased()
        object["type"] = typeIdentifier
        object["workout"] = workoutObject(workout)

        return .upsert(
            CapturedHealthObject(
                id: id,
                type: typeKey,
                canonicalPayload: try serialize(object)
            )
        )
    }

    /// One page of locations, addressed by its absolute offset in the route.
    public static func locationsChange(
        route: UUID,
        offset: Int,
        locations: [RouteLocation],
        routeStart: Date,
        routeEnd: Date
    ) throws -> HealthChange {
        let sequence = offset / locationsPerRecord
        // The receiver requires dates on every record, so a page carries the
        // span of the points it holds rather than borrowing the whole route's.
        let start = locations.first?.timestamp ?? routeStart
        let end = locations.last?.timestamp ?? routeEnd

        let object: [String: Any] = [
            "kind": "workoutRouteLocations",
            "schemaVersion": 1,
            "id": identifier(route: route, suffix: "locations-\(sequence)")
                .uuidString.lowercased(),
            "type": typeIdentifier,
            "route": route.uuidString.lowercased(),
            "sequence": sequence,
            "offset": offset,
            "count": locations.count,
            "startDate": timestamp(start),
            "endDate": timestamp(end),
            "locations": locations.map(object(for:))
        ]
        return .upsert(
            CapturedHealthObject(
                id: identifier(route: route, suffix: "locations-\(sequence)"),
                type: typeKey,
                canonicalPayload: try serialize(object)
            )
        )
    }

    /// Marks a route as fully written, so a reader can tell a complete route
    /// from one an export never got to the end of.
    public static func endChange(
        route: UUID,
        locationCount: Int,
        routeStart: Date,
        routeEnd: Date
    ) throws -> HealthChange {
        let object: [String: Any] = [
            "kind": "workoutRouteEnd",
            "schemaVersion": 1,
            "id": identifier(route: route, suffix: "end")
                .uuidString.lowercased(),
            "type": typeIdentifier,
            "route": route.uuidString.lowercased(),
            "locations": locationCount,
            "startDate": timestamp(routeStart),
            "endDate": timestamp(routeEnd)
        ]
        return .upsert(
            CapturedHealthObject(
                id: identifier(route: route, suffix: "end"),
                type: typeKey,
                canonicalPayload: try serialize(object)
            )
        )
    }

    // MARK: - Identifiers

    /// A stable identifier for a record that HealthKit never gave one to.
    ///
    /// Derived from the route and the record's position, so the same page
    /// always carries the same identifier — which is what lets a receiver
    /// recognise a replayed page as the one it already has.
    public static func identifier(route: UUID, suffix: String) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data(typeIdentifier.utf8))
        withUnsafeBytes(of: route.uuid) { hasher.update(data: Data($0)) }
        hasher.update(data: Data(suffix.utf8))
        let digest = Array(hasher.finalize())

        var bytes = Array(digest.prefix(16))
        // Version 5 (name-based, SHA-1 by the letter of the spec) with the
        // RFC 4122 variant, so the value is a well-formed UUID rather than
        // sixteen arbitrary bytes.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }

    // MARK: - Shaping

    static func object(for location: RouteLocation) -> [String: Any] {
        var object: [String: Any] = [
            "timestamp": timestamp(location.timestamp),
            "latitude": location.latitude,
            "longitude": location.longitude
        ]
        // Core Location reports "unknown" as a negative accuracy or a negative
        // course or speed. Writing those through as numbers would look like
        // measurements, so an unknown is left out instead.
        if location.verticalAccuracy > 0 {
            object["altitude"] = location.altitude
            object["verticalAccuracy"] = location.verticalAccuracy
            if let ellipsoidal = location.ellipsoidalAltitude {
                object["ellipsoidalAltitude"] = ellipsoidal
            }
        }
        if location.horizontalAccuracy >= 0 {
            object["horizontalAccuracy"] = location.horizontalAccuracy
        }
        if location.course >= 0 {
            object["course"] = location.course
            if location.courseAccuracy >= 0 {
                object["courseAccuracy"] = location.courseAccuracy
            }
        }
        if location.speed >= 0 {
            object["speed"] = location.speed
            if location.speedAccuracy >= 0 {
                object["speedAccuracy"] = location.speedAccuracy
            }
        }
        if let floor = location.floor {
            object["floor"] = floor
        }
        if let simulated = location.isSimulatedBySoftware {
            object["simulatedBySoftware"] = simulated
        }
        if let accessory = location.isProducedByAccessory {
            object["producedByAccessory"] = accessory
        }
        return object
    }

    private static func workoutObject(_ link: RouteWorkoutLink) -> [String: Any] {
        switch link {
        case .resolved(let id, let activityType, let start, let end):
            [
                "state": "resolved",
                "id": id.uuidString.lowercased(),
                "activityType": activityType,
                "startDate": timestamp(start),
                "endDate": timestamp(end)
            ]
        case .unresolved(let reason):
            [
                "state": "unresolved",
                "reason": reason
            ]
        }
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw HealthSampleEncodingError.invalidJSONObject
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
    }
}
