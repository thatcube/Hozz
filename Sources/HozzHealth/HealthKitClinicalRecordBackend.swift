import Foundation
import HealthKit
import HozzCore

/// The real clinical backend: `HKSampleQuery`, because HealthKit does not
/// support anchored queries for clinical types.
///
/// That is not a preference. Running an anchored query against a clinical type
/// is unsupported, which is why clinical types are kept structurally out of the
/// list the drain iterates rather than merely skipped inside it.
public struct HealthKitClinicalRecordBackend: ClinicalRecordBackend {
    // Safe to share: `HKHealthStore` documents its queries as usable from any
    // thread, and this type only ever executes them.
    private nonisolated(unsafe) let healthStore: HKHealthStore
    private let encoder: HealthSampleEncoder

    public init(
        healthStore: HKHealthStore = HKHealthStore(),
        encoder: HealthSampleEncoder = HealthSampleEncoder()
    ) {
        self.healthStore = healthStore
        self.encoder = encoder
    }

    public func records(
        of type: ExportableHealthType
    ) async throws -> [ClinicalRecordFacts] {
        let identifier = type.catalogEntry.key.rawValue

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type.sampleType,
                predicate: nil,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(
                        throwing: HealthKitFailure.classify(
                            error,
                            typeIdentifier: identifier
                        )
                    )
                    return
                }
                // Converted here so no `HKClinicalRecord` leaves HealthKit's
                // own queue, and so the shaping stays testable as values.
                continuation.resume(
                    returning: (samples ?? [])
                        .compactMap { $0 as? HKClinicalRecord }
                        .map(HealthSampleEncoder.facts(for:))
                )
            }
            healthStore.execute(query)
        }
    }
}
