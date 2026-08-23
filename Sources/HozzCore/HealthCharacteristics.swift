import Foundation

/// One Health characteristic: a fact about the person rather than a
/// measurement of them.
///
/// Characteristics are not samples. They have no start date, no source, no
/// UUID, and no anchor, so they cannot travel through the anchored-query path
/// that every other Health type uses. They are read whole, each time, and are
/// carried in their own record.
///
/// They matter because they are the context that makes the measurements
/// interpretable. A resting heart rate of 48 means something different
/// depending on age and sex, and without these the exported data cannot answer
/// "is this normal for me".
public struct HealthCharacteristic: Equatable, Sendable {
    /// What Health actually said, kept distinct so an export never has to
    /// guess whether a blank meant refused, absent, or never asked.
    public enum State: String, Codable, Hashable, Sendable {
        /// Health answered with a value the person has set.
        case known
        /// Health answered, and the person has not set this one. That is an
        /// unknown fact about the person, not a failure of the export.
        case notSet
        /// Health answered with a value this build has no name for, usually
        /// because a later OS added a case. ``rawValue`` still carries it, so
        /// the fact survives even though the label does not.
        case unrecognised
        /// The characteristic does not exist on this OS version, or Health
        /// itself is unavailable on this device.
        case unavailable
        /// Health refused or could not answer. ``coverage`` and
        /// ``failureReason`` say why.
        case unreadable
    }

    public let type: HealthTypeKey
    public let state: State
    /// The canonical name of the value, present only when ``state`` is
    /// ``State/known``.
    public let value: String?
    /// HealthKit's own enumeration value, when the characteristic has one.
    /// Date of birth has no raw value, so it is `nil` there.
    public let rawValue: Int?
    /// How the read is classified when it did not produce a value.
    public let coverage: CoverageState?
    public let failureReason: String?

    public init(
        type: HealthTypeKey,
        state: State,
        value: String? = nil,
        rawValue: Int? = nil,
        coverage: CoverageState? = nil,
        failureReason: String? = nil
    ) {
        self.type = type
        self.state = state
        self.value = value
        self.rawValue = rawValue
        self.coverage = coverage
        self.failureReason = failureReason
    }

    public static func known(
        _ type: HealthTypeKey,
        value: String,
        rawValue: Int? = nil
    ) -> Self {
        Self(type: type, state: .known, value: value, rawValue: rawValue)
    }

    public static func notSet(_ type: HealthTypeKey, rawValue: Int? = nil) -> Self {
        Self(type: type, state: .notSet, rawValue: rawValue)
    }

    public static func unrecognised(_ type: HealthTypeKey, rawValue: Int) -> Self {
        Self(type: type, state: .unrecognised, rawValue: rawValue)
    }

    public static func unavailable(_ type: HealthTypeKey, reason: String) -> Self {
        Self(
            type: type,
            state: .unavailable,
            coverage: .unsupported,
            failureReason: reason
        )
    }

    public static func unreadable(
        _ type: HealthTypeKey,
        coverage: CoverageState,
        reason: String
    ) -> Self {
        Self(
            type: type,
            state: .unreadable,
            coverage: coverage,
            failureReason: reason
        )
    }
}

/// Every characteristic Hozz asked for, and when it asked.
public struct HealthCharacteristics: Equatable, Sendable {
    public let readAt: Date
    /// Sorted by type identifier, so the same facts always encode to the same
    /// bytes.
    public let characteristics: [HealthCharacteristic]

    public init(readAt: Date, characteristics: [HealthCharacteristic]) {
        self.readAt = readAt
        self.characteristics = characteristics.sorted { $0.type < $1.type }
    }

    public var known: [HealthCharacteristic] {
        characteristics.filter { $0.state == .known }
    }
}

/// Reads the person's Health characteristics.
///
/// Deliberately non-throwing. Each characteristic carries its own state, so a
/// characteristic Health will not answer is reported as that, and can never
/// fail an export whose real work is elsewhere.
public protocol HealthCharacteristicsSource: Sendable {
    func characteristics() async -> HealthCharacteristics
}
