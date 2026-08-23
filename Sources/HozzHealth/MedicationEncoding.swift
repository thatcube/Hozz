import Foundation
import HozzCore

/// One medication dose event, as values.
///
/// Kept apart from HealthKit so the shaping can be tested: an
/// `HKMedicationDoseEvent` cannot be constructed — its initialiser is
/// unavailable and there is no factory — so a test could not otherwise reach
/// any of this.
public struct MedicationDoseFacts: Equatable, Sendable {
    public let scheduleType: NamedValue
    public let logStatus: NamedValue
    public let unit: String
    /// What the person actually took. Absent when nothing was recorded, which
    /// is not the same as a dose of zero.
    public let doseQuantity: Double?
    /// What they were meant to take, when the dose came from a schedule.
    public let scheduledDoseQuantity: Double?
    public let scheduledDate: Date?

    public init(
        scheduleType: NamedValue,
        logStatus: NamedValue,
        unit: String,
        doseQuantity: Double?,
        scheduledDoseQuantity: Double?,
        scheduledDate: Date?
    ) {
        self.scheduleType = scheduleType
        self.logStatus = logStatus
        self.unit = unit
        self.doseQuantity = doseQuantity
        self.scheduledDoseQuantity = scheduledDoseQuantity
        self.scheduledDate = scheduledDate
    }
}

/// An enumeration Hozz names, carrying the number behind the name so a case
/// added in a later release still arrives as something.
public struct NamedValue: Equatable, Sendable {
    public let name: String
    public let rawValue: Int

    public init(name: String, rawValue: Int) {
        self.name = name
        self.rawValue = rawValue
    }

    var object: [String: Any] {
        ["name": name, "rawValue": rawValue]
    }
}

/// What the medication a dose refers to actually is.
///
/// A dose event names its medication only through an opaque concept
/// identifier — HealthKit exposes no stable string for it — so the medication
/// has to be looked up separately. When that lookup finds nothing, the dose is
/// still exported and says the medication is unresolved, rather than being
/// dropped or given a name it does not have.
public enum MedicationConceptFacts: Equatable, Sendable {
    case resolved(
        displayText: String,
        nickname: String?,
        generalForm: String,
        isArchived: Bool,
        hasSchedule: Bool,
        codings: [MedicationCoding]
    )
    case unresolved(reason: String)
}

public struct MedicationCoding: Equatable, Sendable, Comparable {
    public let system: String
    public let code: String
    public let version: String?

    public init(system: String, code: String, version: String?) {
        self.system = system
        self.code = code
        self.version = version
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.system, lhs.code) < (rhs.system, rhs.code)
    }

    var object: [String: Any] {
        var object: [String: Any] = ["system": system, "code": code]
        if let version {
            object["version"] = version
        }
        return object
    }
}

public enum MedicationEncoding {
    public static let typeIdentifier = "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent"
    public static let typeKey = HealthTypeKey(typeIdentifier)

    /// Shapes a dose event.
    ///
    /// Every optional stays optional. A dose the person never recorded is left
    /// out rather than written as zero — "took none" and "logged nothing" are
    /// different facts, and only one of them is a dose of zero.
    static func object(
        for dose: MedicationDoseFacts,
        medication: MedicationConceptFacts
    ) -> [String: Any] {
        var object: [String: Any] = [
            "scheduleType": dose.scheduleType.object,
            "logStatus": dose.logStatus.object,
            "unit": dose.unit,
            "medication": medicationObject(medication)
        ]
        if let quantity = dose.doseQuantity {
            object["doseQuantity"] = quantity
        }
        if let scheduled = dose.scheduledDoseQuantity {
            object["scheduledDoseQuantity"] = scheduled
        }
        if let date = dose.scheduledDate {
            object["scheduledDate"] = timestamp(date)
        }
        return object
    }

    private static func medicationObject(
        _ medication: MedicationConceptFacts
    ) -> [String: Any] {
        switch medication {
        case .resolved(
            let displayText,
            let nickname,
            let generalForm,
            let isArchived,
            let hasSchedule,
            let codings
        ):
            var object: [String: Any] = [
                "state": "resolved",
                "displayText": displayText,
                "generalForm": generalForm,
                "isArchived": isArchived,
                "hasSchedule": hasSchedule,
                // Sorted so the same medication always encodes to the same
                // bytes; HealthKit hands the codings over as a set.
                "codings": codings.sorted().map(\.object)
            ]
            if let nickname {
                object["nickname"] = nickname
            }
            return object
        case .unresolved(let reason):
            return ["state": "unresolved", "reason": reason]
        }
    }

    private static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
    }
}
