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
    let healthStore: HKHealthStore
    let encoder: HealthSampleEncoder
    private let typesByKey: [HealthTypeKey: ExportableHealthType]
    private let routes: SeriesReader<HealthKitWorkoutRouteBackend>
    private let electrocardiograms: SeriesReader<HealthKitElectrocardiogramBackend>
    private let quantitySeries: QuantitySeriesExpander
    /// Whether a series sample noticed in the ordinary stream is queued for
    /// expansion.
    ///
    /// It governs *queueing*, not draining: a sample already in a cursor's
    /// queue is always finished, whatever this says. Turning it off mid-series
    /// would otherwise strand readings whose aggregate has already been
    /// exported promising them, and leave a cursor that never empties.
    private var encodingErrors: [HealthTypeKey: Int] = [:]
    private var medicationDirectory: [AnyHashable: MedicationConceptFacts]?

    public init(
        healthStore: HKHealthStore = HKHealthStore(),
        encoder: HealthSampleEncoder = HealthSampleEncoder(),
        types: [ExportableHealthType] = HealthKitTypeRegistry.exportableTypes(),
        quantitySeriesBackend: (any QuantitySeriesBackend)? = nil
    ) {
        self.healthStore = healthStore
        self.encoder = encoder
        self.quantitySeries = QuantitySeriesExpander(
            backend: quantitySeriesBackend
                ?? HealthKitQuantitySeriesBackend(healthStore: healthStore),
            encoder: encoder
        )
        self.routes = SeriesReader(
            shape: WorkoutRouteEncoding.shape,
            backend: HealthKitWorkoutRouteBackend(
                healthStore: healthStore,
                encoder: encoder
            ),
            encoder: encoder
        )
        self.electrocardiograms = SeriesReader(
            shape: ElectrocardiogramEncoding.shape,
            backend: HealthKitElectrocardiogramBackend(
                healthStore: healthStore,
                encoder: encoder
            ),
            encoder: encoder
        )
        self.typesByKey = Dictionary(
            types.map { ($0.catalogEntry.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The exportable type behind a key, or nil when Hozz cannot read it.
    func exportableType(for key: HealthTypeKey) -> ExportableHealthType? {
        typesByKey[key]
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

        // A series sample's content is a separate stream, so it is paged by
        // position inside the sample rather than by HealthKit's anchor alone.
        if exportable.catalogEntry.family == .series {
            switch type.rawValue {
            case WorkoutRouteEncoding.typeIdentifier:
                return try await routes.changes(after: anchor, limit: limit)
            case ElectrocardiogramEncoding.typeIdentifier:
                return try await electrocardiograms.changes(
                    after: anchor,
                    limit: limit
                )
            default:
                throw HealthKitSourceError.unsupportedType(type.rawValue)
            }
        }

        let cursor = try QuantityAnchor.decode(anchor)

        // Readings owed from an earlier page come before anything new. The
        // HealthKit anchor has already moved past these samples, so they will
        // never be offered again — finishing them is the only way they are
        // ever written.
        if cursor.pendingSample != nil {
            guard let unit = exportable.catalogEntry.canonicalUnit else {
                // Unreachable: nothing without a canonical unit is ever
                // queued. Failing loudly leaves the cursor where it is, which
                // keeps the readings, rather than dropping the queue.
                throw HealthKitSourceError.unsupportedType(type.rawValue)
            }
            let expansion = try await quantitySeries.expand(
                from: cursor,
                type: type,
                unit: unit,
                recordLimit: limit
            )
            // A sample whose readings could not be had is an encoding failure
            // like any other, and the run's manifest reports how many there
            // were. Leaving these out would understate what the export says
            // about itself.
            encodingErrors[type, default: 0] += expansion.failures
            return HealthChangeBatch(
                changes: expansion.changes,
                proposedAnchor: try expansion.anchor.token()
            )
        }

        let startAnchor = try HealthKitAnchorCoding.anchor(
            for: cursor.healthKitAnchor.map { AnchorToken(data: $0) }
        )
        let page = try await page(
            type: exportable,
            anchor: startAnchor,
            limit: limit,
            medications: try await medications(for: exportable)
        )
        encodingErrors[type, default: 0] += page.encodingErrors

        return HealthChangeBatch(
            changes: page.changes,
            proposedAnchor: try QuantityAnchor(
                healthKitAnchor: page.anchor.data,
                pendingSeries: page.seriesSamples
            ).token()
        )
    }

    private struct Page: Sendable {
        let changes: [HealthChange]
        let anchor: AnchorToken
        let encodingErrors: Int
        /// Samples this page saw that stand for more than one reading.
        ///
        /// They are noticed here and nowhere else. HealthKit has no predicate
        /// for "samples that are series", so the only way to find one is to
        /// look at every sample of every type as it goes past — which is why
        /// this lives in the drain that all of them share rather than in a
        /// series type of its own.
        let seriesSamples: [UUID]
    }

    /// What encoding a batch of samples produced, whatever query found them.
    struct Encoded: Sendable {
        var changes: [HealthChange] = []
        var encodingErrors = 0
        var seriesSamples: [UUID] = []
    }

    /// Turns HealthKit samples into records, identically for every query.
    ///
    /// Shared rather than written twice because the anchored sweep and the
    /// dated prime must produce *byte-identical* records for the same sample.
    /// The receiver upserts on `(id, type)`, so a record that arrives by both
    /// routes is meant to be the same record; two encoders that drifted apart
    /// would turn a harmless repeat into a value that changes depending on
    /// which reader happened to get there last.
    ///
    /// `nonisolated` because it touches nothing but its arguments, which lets
    /// it run inside a HealthKit completion handler without hopping actors.
    /// - Parameter expandsSeries: Whether the caller is going to deliver the
    ///   readings behind a series sample. Only the anchored sweep can, so only
    ///   it may have its records claim so.
    nonisolated static func encode(
        samples: [HKSample],
        key: HealthTypeKey,
        catalogEntry: HealthCatalogEntry,
        encoder: HealthSampleEncoder,
        medications: [AnyHashable: MedicationConceptFacts],
        expandsSeries: Bool = true
    ) -> Encoded {
        var result = Encoded()
        result.changes.reserveCapacity(samples.count)

        for sample in samples {
            do {
                let payload = try encoder.encode(
                    sample: sample,
                    catalogEntry: catalogEntry,
                    medications: medications,
                    expandsSeries: expandsSeries
                )
                result.changes.append(
                    .upsert(
                        CapturedHealthObject(
                            id: sample.uuid,
                            type: key,
                            canonicalPayload: payload
                        )
                    )
                )
                // Noticed only after the sample encodes, so a reading
                // page is never the only thing an export holds about a
                // sample it could not otherwise describe.
                if
                    let quantity = sample as? HKQuantitySample,
                    QuantitySeriesEncoding.isExpandable(
                        count: quantity.count,
                        canonicalUnit: catalogEntry.canonicalUnit
                    )
                {
                    result.seriesSamples.append(quantity.uuid)
                }
            } catch {
                // A sample Hozz cannot encode losslessly is recorded as
                // an explicit error in the output rather than dropped,
                // so the export never overstates its own coverage.
                result.encodingErrors += 1
                guard
                    let payload = try? encoder.encodeEncodingFailure(
                        id: sample.uuid,
                        typeIdentifier: key.rawValue,
                        message: String(describing: error)
                    )
                else {
                    continue
                }
                result.changes.append(
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

        return result
    }

    /// The medication list, read once and reused.
    ///
    /// A course of tablets is thousands of dose events pointing at the same
    /// handful of medicines, so looking each one up per dose would be absurd.
    /// A medication added mid-drain simply misses the cache and its dose says
    /// the medication is unresolved, which is true rather than invented.
    func medications(
        for type: ExportableHealthType
    ) async throws -> [AnyHashable: MedicationConceptFacts] {
        guard type.catalogEntry.family == .medication else {
            return [:]
        }
        if let medicationDirectory {
            return medicationDirectory
        }
        guard #available(iOS 26.0, *) else {
            return [:]
        }
        // A directory that cannot be read leaves every dose unresolved rather
        // than failing the type: the doses themselves are still worth having.
        let loaded = (try? await HealthKitMedicationDirectory(
            healthStore: healthStore
        ).load()) ?? [:]
        medicationDirectory = loaded
        return loaded
    }

    private func page(
        type: ExportableHealthType,
        anchor: HKQueryAnchor?,
        limit: Int,
        medications: [AnyHashable: MedicationConceptFacts]
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
                let encoded = Self.encode(
                    samples: samples ?? [],
                    key: key,
                    catalogEntry: catalogEntry,
                    encoder: encoder,
                    medications: medications
                )
                changes = encoded.changes
                changes.reserveCapacity(
                    encoded.changes.count + (deletions?.count ?? 0)
                )

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
                            changes: changes,
                            anchor: token,
                            encodingErrors: encoded.encodingErrors,
                            seriesSamples: encoded.seriesSamples
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
