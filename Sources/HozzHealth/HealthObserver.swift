import Foundation
import HealthKit
import HozzCore
import os

/// Subscribes to Health so iOS wakes Hozz when new data is recorded.
///
/// This is what makes export automatic. `enableBackgroundDelivery` asks iOS to
/// *activate the app* when data of a type is recorded, which relaunches Hozz
/// even if it is not running. Four limits are real and are surfaced to the user
/// rather than hidden:
///
/// 1. Force-quitting the app stops iOS relaunching it until it is opened again.
/// 2. Health cannot be read at all while the device is locked, because the
///    database is encrypted with the passcode.
/// 3. HealthKit caps most types at hourly regardless of what is requested.
/// 4. iOS decides the real cadence based on how the phone is used.
public actor HealthObserver {
    private static let log = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "observer"
    )

    /// The largest number of types Hozz will subscribe to.
    ///
    /// Every observer is a wake-up reason, and hundreds of them would cost
    /// battery for types the user almost certainly has no data for. The picker
    /// narrows this further.
    public static let maximumObservedTypes = 64

    private let healthStore: HKHealthStore
    private let types: [ExportableHealthType]
    private var activeQueries: [HKObserverQuery] = []
    private var dirtyTypes: Set<HealthTypeKey> = []
    private var onDirty: (@Sendable (Set<HealthTypeKey>) async -> Void)?

    public init(
        healthStore: HKHealthStore = HKHealthStore(),
        types: [ExportableHealthType] = HealthKitTypeRegistry.exportableTypes()
    ) {
        self.healthStore = healthStore
        self.types = types
    }

    /// Types that have reported new data since the last drain.
    public func takeDirtyTypes() -> Set<HealthTypeKey> {
        let dirty = dirtyTypes
        dirtyTypes.removeAll()
        return dirty
    }

    public func markDirty(_ type: HealthTypeKey) {
        dirtyTypes.insert(type)
    }

    /// Starts observing, and asks iOS to deliver in the background.
    ///
    /// - Parameters:
    ///   - selection: Types to watch. Empty watches a bounded default set.
    ///   - onDirty: Called when types report new data. It should return
    ///     quickly; the completion handler owes iOS an answer within seconds.
    public func start(
        selection: Set<HealthTypeKey>,
        onDirty: @escaping @Sendable (Set<HealthTypeKey>) async -> Void
    ) async {
        guard HKHealthStore.isHealthDataAvailable() else {
            return
        }
        await stop()
        self.onDirty = onDirty

        for type in observedTypes(for: selection) {
            let key = type.catalogEntry.key
            let query = HKObserverQuery(
                sampleType: type.sampleType,
                predicate: nil
            ) { [weak self] _, completionHandler, error in
                // HealthKit hands back a non-Sendable completion handler that
                // must be called exactly once, from any queue. Boxing it lets
                // it cross into the actor without Swift copying it.
                let acknowledgement = ObserverAcknowledgement(completionHandler)
                if error != nil {
                    Self.log.error("A Health observer reported an error.")
                    // iOS still needs the acknowledgement, or it backs off.
                    acknowledgement.callAsFunction()
                    return
                }
                Task { [weak self] in
                    await self?.handleUpdate(for: key)
                    // Acknowledging tells iOS the wake-up was handled. Doing it
                    // once the change has been recorded, rather than once the
                    // whole delivery finishes, keeps iOS from treating the
                    // launch as wasted while staying inside its time budget.
                    acknowledgement.callAsFunction()
                }
            }
            healthStore.execute(query)
            activeQueries.append(query)

            await enableBackgroundDelivery(for: type.sampleType)
        }
        Self.log.info("Observing \(self.activeQueries.count, privacy: .public) Health types.")
    }

    public func stop() async {
        for query in activeQueries {
            healthStore.stop(query)
        }
        activeQueries.removeAll()
    }

    /// Turns off every background subscription Hozz previously asked for.
    public func disableAllBackgroundDelivery() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            healthStore.disableAllBackgroundDelivery { _, _ in
                continuation.resume()
            }
        }
    }

    private func handleUpdate(for key: HealthTypeKey) async {
        dirtyTypes.insert(key)
        await onDirty?([key])
    }

    private func enableBackgroundDelivery(for type: HKSampleType) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Immediate is requested because HealthKit silently lowers it to
            // hourly for the types that require it. Asking for less would make
            // the types that *can* be immediate slower for no benefit.
            healthStore.enableBackgroundDelivery(
                for: type,
                frequency: .immediate
            ) { success, error in
                if let error, !success {
                    Self.log.debug(
                        "Background delivery unavailable for a type: \(error.localizedDescription, privacy: .public)"
                    )
                }
                continuation.resume()
            }
        }
    }

    /// Chooses which types to watch, honouring the user's selection and the
    /// wake-up budget.
    private func observedTypes(
        for selection: Set<HealthTypeKey>
    ) -> [ExportableHealthType] {
        if !selection.isEmpty {
            return types
                .filter { selection.contains($0.catalogEntry.key) }
                .prefix(Self.maximumObservedTypes)
                .map { $0 }
        }
        // With no selection, watch the types most people actually record. This
        // is a wake-up budget, not a claim about what Hozz can export: a manual
        // export still covers everything.
        let defaults = Set(HealthObserverDefaults.commonTypeIdentifiers)
        let common = types.filter { defaults.contains($0.catalogEntry.key.rawValue) }
        return Array(common.prefix(Self.maximumObservedTypes))
    }
}

/// Carries HealthKit's completion handler across an actor hop.
///
/// The handler is not `Sendable` and must be invoked exactly once. The box is
/// only ever called from the single task that owns one observer callback, so
/// there is no concurrent access to guard.
private final class ObserverAcknowledgement: @unchecked Sendable {
    private let handler: HKObserverQueryCompletionHandler

    init(_ handler: @escaping HKObserverQueryCompletionHandler) {
        self.handler = handler
    }

    func callAsFunction() {
        handler()
    }
}

/// The types worth waking the app for when the user has not chosen.
public enum HealthObserverDefaults {
    public static let commonTypeIdentifiers: [String] = [
        "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
        "HKQuantityTypeIdentifierActiveEnergyBurned",
        "HKQuantityTypeIdentifierBasalEnergyBurned",
        "HKQuantityTypeIdentifierHeartRate",
        "HKQuantityTypeIdentifierRestingHeartRate",
        "HKQuantityTypeIdentifierWalkingHeartRateAverage",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        "HKQuantityTypeIdentifierOxygenSaturation",
        "HKQuantityTypeIdentifierRespiratoryRate",
        "HKQuantityTypeIdentifierBodyMass",
        "HKQuantityTypeIdentifierBodyFatPercentage",
        "HKQuantityTypeIdentifierLeanBodyMass",
        "HKQuantityTypeIdentifierBodyMassIndex",
        "HKQuantityTypeIdentifierHeight",
        "HKQuantityTypeIdentifierAppleExerciseTime",
        "HKQuantityTypeIdentifierAppleStandTime",
        "HKQuantityTypeIdentifierFlightsClimbed",
        "HKQuantityTypeIdentifierVO2Max",
        "HKQuantityTypeIdentifierBloodGlucose",
        "HKQuantityTypeIdentifierBloodPressureSystolic",
        "HKQuantityTypeIdentifierBloodPressureDiastolic",
        "HKQuantityTypeIdentifierBodyTemperature",
        "HKQuantityTypeIdentifierDietaryEnergyConsumed",
        "HKQuantityTypeIdentifierDietaryProtein",
        "HKQuantityTypeIdentifierDietaryCarbohydrates",
        "HKQuantityTypeIdentifierDietaryFatTotal",
        "HKQuantityTypeIdentifierDietaryWater",
        "HKQuantityTypeIdentifierDistanceCycling",
        "HKQuantityTypeIdentifierDistanceSwimming",
        "HKQuantityTypeIdentifierAppleSleepingWristTemperature",
        "HKCategoryTypeIdentifierSleepAnalysis",
        "HKCategoryTypeIdentifierMindfulSession",
        "HKCategoryTypeIdentifierAppleStandHour",
        "HKCategoryTypeIdentifierMenstrualFlow",
        "HKWorkoutTypeIdentifier"
    ]
}
