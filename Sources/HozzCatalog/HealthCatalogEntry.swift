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
            "HKWorkoutTypeIdentifier"
        ]
        for prefix in prefixes where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        if name.isEmpty {
            return family == .workout ? "Workout" : key.rawValue
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
            )
        ]

    public static let entriesByIdentifier: [String: HealthCatalogEntry] =
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0) })
}
