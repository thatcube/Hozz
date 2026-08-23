import Foundation
import HealthKit
import HozzCore

/// Looks up what a dose event's medication actually is.
///
/// A dose event names its medication only through an opaque
/// `HKHealthConceptIdentifier`; HealthKit exposes no stable string for it, so
/// the name, form, and codings live on a separate object that has to be
/// fetched with its own query.
///
/// The list is small — a person's own medications — and it is read once per
/// drain rather than once per dose, because a course of tablets can be
/// thousands of dose events pointing at the same handful of medicines.
@available(iOS 26.0, *)
public struct HealthKitMedicationDirectory: Sendable {
    // Safe to share: `HKHealthStore` documents its queries as usable from any
    // thread, and this type only ever executes them.
    private nonisolated(unsafe) let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    /// Every medication the person has annotated, keyed by concept identity.
    ///
    /// Archived medications are included deliberately. A dose taken last year
    /// still refers to the medicine it referred to then, and dropping archived
    /// entries would turn old doses into unresolved ones.
    public func load() async throws -> [AnyHashable: MedicationConceptFacts] {
        try await withCheckedThrowingContinuation { continuation in
            // The results handler is called repeatedly on HealthKit's own
            // queue, so the accumulator is held in a box rather than a captured
            // `var`, and only the finished dictionary crosses back.
            let found = Accumulator()
            let query = HKUserAnnotatedMedicationQuery(
                predicate: nil,
                limit: HKObjectQueryNoLimit
            ) { _, medication, done, error in
                if let error {
                    continuation.resume(
                        throwing: HealthKitFailure.classify(
                            error,
                            typeIdentifier: MedicationEncoding.typeIdentifier
                        )
                    )
                    return
                }
                if let medication {
                    found.add(
                        AnyHashable(medication.medication.identifier),
                        Self.facts(for: medication)
                    )
                }
                if done {
                    continuation.resume(returning: found.take())
                }
            }
            healthStore.execute(query)
        }
    }

    /// HealthKit calls one query's handler serially, so a plain lock is all
    /// this needs.
    private final class Accumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var found: [AnyHashable: MedicationConceptFacts] = [:]

        func add(_ key: AnyHashable, _ facts: MedicationConceptFacts) {
            lock.lock()
            defer { lock.unlock() }
            found[key] = facts
        }

        func take() -> [AnyHashable: MedicationConceptFacts] {
            lock.lock()
            defer { lock.unlock() }
            return found
        }
    }

    static func facts(
        for medication: HKUserAnnotatedMedication
    ) -> MedicationConceptFacts {
        .resolved(
            displayText: medication.medication.displayText,
            nickname: medication.nickname,
            generalForm: medication.medication.generalForm.rawValue,
            isArchived: medication.isArchived,
            hasSchedule: medication.hasSchedule,
            codings: medication.medication.relatedCodings.map {
                MedicationCoding(
                    system: $0.system,
                    code: $0.code,
                    version: $0.version
                )
            }
        )
    }

    /// Turns a dose event into values, on the queue HealthKit handed it over.
    static func facts(for dose: HKMedicationDoseEvent) -> MedicationDoseFacts {
        MedicationDoseFacts(
            scheduleType: named(dose.scheduleType),
            logStatus: named(dose.logStatus),
            unit: dose.unit.unitString,
            doseQuantity: dose.doseQuantity,
            scheduledDoseQuantity: dose.scheduledDoseQuantity,
            scheduledDate: dose.scheduledDate
        )
    }

    static func named(
        _ scheduleType: HKMedicationDoseEvent.ScheduleType
    ) -> NamedValue {
        let name: String = switch scheduleType {
        case .asNeeded: "asNeeded"
        case .schedule: "schedule"
        @unknown default: "unrecognisedByHozz"
        }
        return NamedValue(name: name, rawValue: scheduleType.rawValue)
    }

    /// The log status is the whole meaning of a dose event: taken, skipped, or
    /// never answered are three different facts about a person's treatment,
    /// and flattening them would be the worst possible summary.
    static func named(
        _ status: HKMedicationDoseEvent.LogStatus
    ) -> NamedValue {
        let name: String = switch status {
        case .notInteracted: "notInteracted"
        case .notificationNotSent: "notificationNotSent"
        case .snoozed: "snoozed"
        case .taken: "taken"
        case .skipped: "skipped"
        case .notLogged: "notLogged"
        @unknown default: "unrecognisedByHozz"
        }
        return NamedValue(name: name, rawValue: status.rawValue)
    }
}
