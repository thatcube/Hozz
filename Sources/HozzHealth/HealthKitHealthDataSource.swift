import Foundation
import HealthKit
import HozzCatalog
import HozzCore

public enum HealthKitSourceError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedType(String)
    case missingAnchor(String)
    case invalidLimit

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let identifier):
            "Hozz cannot read \(identifier) with the public HealthKit APIs."
        case .missingAnchor(let identifier):
            "Health returned data for \(identifier) without a continuation cursor."
        case .invalidLimit:
            "A Health page size must be greater than zero."
        }
    }
}

/// The production ``HealthDataSource``: real `HKAnchoredObjectQuery` pagination
/// behind the same protocol the fault tests drive.
///
/// Encoding happens inside the query callback so no `HKSample` ever escapes
/// HealthKit's completion queue, and only `Sendable` values cross back into
/// structured concurrency.
public actor HealthKitHealthDataSource: HealthDataSource {
    private let healthStore: HKHealthStore
    private let encoder: HealthSampleEncoder
    private let typesByKey: [HealthTypeKey: ExportableHealthType]
    private var encodingErrors: [HealthTypeKey: Int] = [:]

    public init(
        healthStore: HKHealthStore = HKHealthStore(),
        encoder: HealthSampleEncoder = HealthSampleEncoder(),
        types: [ExportableHealthType] = HealthKitTypeRegistry.exportableTypes()
    ) {
        self.healthStore = healthStore
        self.encoder = encoder
        self.typesByKey = Dictionary(
            types.map { ($0.catalogEntry.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The number of samples whose canonical encoding failed and were written as
    /// explicit error records instead of being silently dropped.
    public func encodingErrorCount(for type: HealthTypeKey) -> Int {
        encodingErrors[type, default: 0]
    }

    public func changes(
        for type: HealthTypeKey,
        after anchor: AnchorToken?,
        limit: Int
    ) async throws -> HealthChangeBatch {
        guard limit > 0 else {
            throw HealthKitSourceError.invalidLimit
        }
        guard let exportable = typesByKey[type] else {
            throw HealthKitSourceError.unsupportedType(type.rawValue)
        }

        let startAnchor = try HealthKitAnchorCoding.anchor(for: anchor)
        let page = try await page(
            type: exportable,
            anchor: startAnchor,
            limit: limit
        )
        encodingErrors[type, default: 0] += page.encodingErrors
        return page.batch
    }

    private struct Page: Sendable {
        let batch: HealthChangeBatch
        let encodingErrors: Int
    }

    private func page(
        type: ExportableHealthType,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> Page {
        let encoder = encoder
        let key = type.catalogEntry.key
        let catalogEntry = type.catalogEntry
        let sampleType = type.sampleType

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: nil,
                anchor: anchor,
                limit: limit
            ) { _, samples, deletions, newAnchor, error in
                if let error {
                    continuation.resume(
                        throwing: HealthKitFailure.classify(
                            error,
                            typeIdentifier: key.rawValue
                        )
                    )
                    return
                }
                guard let newAnchor else {
                    continuation.resume(
                        throwing: HealthKitSourceError.missingAnchor(key.rawValue)
                    )
                    return
                }

                var changes: [HealthChange] = []
                changes.reserveCapacity(
                    (samples?.count ?? 0) + (deletions?.count ?? 0)
                )
                var encodingErrors = 0

                for sample in samples ?? [] {
                    do {
                        let payload = try encoder.encode(
                            sample: sample,
                            catalogEntry: catalogEntry
                        )
                        changes.append(
                            .upsert(
                                CapturedHealthObject(
                                    id: sample.uuid,
                                    type: key,
                                    canonicalPayload: payload
                                )
                            )
                        )
                    } catch {
                        // A sample Hozz cannot encode losslessly is recorded as
                        // an explicit error in the output rather than dropped,
                        // so the export never overstates its own coverage.
                        encodingErrors += 1
                        guard
                            let payload = try? encoder.encodeEncodingFailure(
                                id: sample.uuid,
                                typeIdentifier: key.rawValue,
                                message: String(describing: error)
                            )
                        else {
                            continue
                        }
                        changes.append(
                            .upsert(
                                CapturedHealthObject(
                                    id: sample.uuid,
                                    type: key,
                                    canonicalPayload: payload
                                )
                            )
                        )
                    }
                }

                for deletion in deletions ?? [] {
                    changes.append(
                        .delete(
                            CapturedHealthDeletion(id: deletion.uuid, type: key)
                        )
                    )
                }

                do {
                    let token = try HealthKitAnchorCoding.token(for: newAnchor)
                    continuation.resume(
                        returning: Page(
                            batch: HealthChangeBatch(
                                changes: changes,
                                proposedAnchor: token
                            ),
                            encodingErrors: encodingErrors
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            healthStore.execute(query)
        }
    }
}
