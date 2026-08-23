import Foundation
import HozzCore

public enum HealthTypeFamily: String, Codable, CaseIterable, Sendable {
    case quantity
    case category
    case characteristic
    case correlation
    case clinical
    case document
    case scoredAssessment
    case workout
    /// Samples whose real content is a stream attached to them rather than a
    /// value on them — a workout's route, for instance. They are read through
    /// the ordinary anchored path and then streamed in bounded pieces.
    case series
}

public struct IOSVersion: Codable, Hashable, Sendable, Comparable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public func isAvailable(on version: OperatingSystemVersion) -> Bool {
        self <= IOSVersion(major: version.majorVersion, minor: version.minorVersion)
    }
}

public struct HealthCatalogEntry: Codable, Hashable, Sendable {
    public let key: HealthTypeKey
    public let family: HealthTypeFamily
    public let introduced: IOSVersion
    public let canonicalUnit: String?
    public let isDeprecated: Bool

    public init(
        identifier: String,
        family: HealthTypeFamily,
        introduced: IOSVersion,
        canonicalUnit: String? = nil,
        isDeprecated: Bool = false
    ) {
        self.key = HealthTypeKey(identifier)
        self.family = family
        self.introduced = introduced
        self.canonicalUnit = canonicalUnit
        self.isDeprecated = isDeprecated
    }

    public var displayName: String {
        var name = key.rawValue
        let prefixes = [
            "HKQuantityTypeIdentifier",
            "HKCategoryTypeIdentifier",
            "HKCharacteristicTypeIdentifier",
            "HKCorrelationTypeIdentifier",
            "HKClinicalTypeIdentifier",
            "HKDocumentTypeIdentifier",
            "HKScoredAssessmentTypeIdentifier",
            "HKWorkoutRouteTypeIdentifier",
            "HKWorkoutTypeIdentifier"
        ]
        for prefix in prefixes where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        if name.isEmpty {
            return switch key.rawValue {
            case "HKWorkoutTypeIdentifier": "Workout"
            case "HKWorkoutRouteTypeIdentifier": "Workout Route"
            default: key.rawValue
            }
        }

        return name
            .replacingOccurrences(
                of: #"([a-z0-9])([A-Z])"#,
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"([A-Z]+)([A-Z][a-z])"#,
                with: "$1 $2",
                options: .regularExpression
            )
    }
}

public enum HealthTypeCatalog {
    public static let version = "2026.08.1"

    public static let entries: [HealthCatalogEntry] =
        GeneratedHealthTypeCatalog.entries + [
            HealthCatalogEntry(
                identifier: "HKWorkoutTypeIdentifier",
                family: .workout,
                introduced: IOSVersion(major: 8, minor: 0)
            ),
            // Not in the generated catalog because it is not a type identifier
            // Apple lists with the others: a route is reached through
            // `HKSeriesType.workoutRoute()`. It is anchored and drained like
            // any other sample, and its locations are streamed separately.
            HealthCatalogEntry(
                identifier: "HKWorkoutRouteTypeIdentifier",
                family: .series,
                introduced: IOSVersion(major: 11, minor: 0)
            )
        ]

    public static let entriesByIdentifier: [String: HealthCatalogEntry] =
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0) })
}
