import Foundation
import HozzCore

/// One point from a workout route, as a value.
///
/// `CLLocation` is a reference type handed over on HealthKit's own queue.
/// Converting each point where it arrives keeps Core Location objects from
/// escaping that queue, and makes the encoding testable without a device.
public struct RouteLocation: Equatable, Sendable, SeriesElement {
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

    public var seriesTimestamp: Date {
        timestamp
    }

    public var seriesObject: [String: any Sendable] {
        var object: [String: any Sendable] = [
            "timestamp": SeriesEncoding.timestamp(timestamp),
            "latitude": latitude,
            "longitude": longitude
        ]
        // Core Location reports "unknown" as a negative accuracy, course, or
        // speed. Writing those through as numbers would look like
        // measurements, so an unknown is left out instead.
        if verticalAccuracy > 0 {
            object["altitude"] = altitude
            object["verticalAccuracy"] = verticalAccuracy
            if let ellipsoidalAltitude {
                object["ellipsoidalAltitude"] = ellipsoidalAltitude
            }
        }
        if horizontalAccuracy >= 0 {
            object["horizontalAccuracy"] = horizontalAccuracy
        }
        if course >= 0 {
            object["course"] = course
            if courseAccuracy >= 0 {
                object["courseAccuracy"] = courseAccuracy
            }
        }
        if speed >= 0 {
            object["speed"] = speed
            if speedAccuracy >= 0 {
                object["speedAccuracy"] = speedAccuracy
            }
        }
        if let floor {
            object["floor"] = floor
        }
        if let isSimulatedBySoftware {
            object["simulatedBySoftware"] = isSimulatedBySoftware
        }
        if let isProducedByAccessory {
            object["producedByAccessory"] = isProducedByAccessory
        }
        return object
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

    var object: [String: Any] {
        switch self {
        case .resolved(let id, let activityType, let start, let end):
            [
                "state": "resolved",
                "id": id.uuidString.lowercased(),
                "activityType": activityType,
                "startDate": SeriesEncoding.timestamp(start),
                "endDate": SeriesEncoding.timestamp(end)
            ]
        case .unresolved(let reason):
            [
                "state": "unresolved",
                "reason": reason
            ]
        }
    }
}

public enum WorkoutRouteEncoding {
    public static let typeIdentifier = "HKWorkoutRouteTypeIdentifier"
    public static let typeKey = HealthTypeKey(typeIdentifier)

    public static let shape = SeriesShape(
        typeIdentifier: typeIdentifier,
        headerKind: "workoutRoute",
        elementKind: "workoutRouteLocations",
        endKind: "workoutRouteEnd",
        elementsKey: "locations",
        // Roughly 70 KB of JSON per record: small enough that a handful in
        // flight is nothing, large enough that a long ride does not become a
        // million lines.
        elementsPerRecord: 500,
        recordsPerPage: 8
    )

    public static var locationsPerRecord: Int {
        shape.elementsPerRecord
    }

    public static var recordsPerPage: Int {
        shape.recordsPerPage
    }

    /// Adds the workout a route belongs to, which needs queries of its own and
    /// so cannot be known where the sample was encoded.
    public static func basePayload(
        _ payload: Data,
        workout: RouteWorkoutLink
    ) throws -> Data {
        guard
            var object = try JSONSerialization.jsonObject(with: payload)
                as? [String: Any]
        else {
            throw HealthSampleEncodingError.invalidJSONObject
        }
        object["workout"] = workout.object
        return try SeriesEncoding.serialize(object)
    }
}
