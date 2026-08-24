import Foundation
import HealthKit
import HozzCatalog
import HozzCore

/// Reading Health by date, for the recent-first prime.
///
/// The anchored sweep and this are two readers of the same store with opposite
/// strengths, and the prime exists because neither alone is enough. The sweep
/// sees every change including deletions, and will eventually have everything,
/// but it arrives in Health's storage order — so a phone that has been running
/// for a week may hold nothing newer than 2023, and no rearranging of the sweep
/// can fix that without giving up the guarantee that makes it worth having.
/// This asks the other question: what happened in these dates. It cannot see a
/// deletion and cannot promise a type is complete, so it never advances an
/// anchor and never records coverage. It just makes the recent past turn up.
extension HealthKitHealthDataSource: DatedHealthDataSource {
    public func changes(
        for type: HealthTypeKey,
        from start: Date,
        to end: Date,
        limit: Int
    ) async throws -> DatedHealthChanges {
        guard limit > 0 else {
            throw HealthKitSourceError.invalidLimit
        }
        guard start < end else {
            return DatedHealthChanges(changes: [])
        }
        guard let exportable = exportableType(for: type) else {
            throw HealthKitSourceError.unsupportedType(type.rawValue)
        }
        // A series type's content is a second stream hanging off each sample,
        // paged by position inside it, and a dated query has nowhere to put
        // that position. Priming one would deliver route samples whose points
        // were still missing, so they are left to the sweep, which is built for
        // it. A type with no prime row simply reports no primed window, which
        // is the truth about it.
        guard exportable.catalogEntry.family != .series else {
            throw HealthKitSourceError.unsupportedType(type.rawValue)
        }

        let medications = try await medications(for: exportable)
        return try await datedPage(
            type: exportable,
            start: start,
            end: end,
            limit: limit,
            medications: medications
        )
    }

    private func datedPage(
        type: ExportableHealthType,
        start: Date,
        end: Date,
        limit: Int,
        medications: [AnyHashable: MedicationConceptFacts]
    ) async throws -> DatedHealthChanges {
        let encoder = self.encoder
        let key = type.catalogEntry.key
        let catalogEntry = type.catalogEntry
        let sampleType = type.sampleType

        // `strictStartDate` files each sample by where it began, so abutting
        // windows partition them and a long sample cannot be read into every
        // window it happens to overlap. Without it, a nine-hour sleep would be
        // returned by both of the chunks it straddles — harmless, since the
        // receiver upserts, but it would also make each chunk's record count a
        // lie about that chunk's density, and the walk sizes itself from that
        // count.
        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: [.strictStartDate]
        )
        // One more than the caller will accept, so the reply can distinguish
        // "this is the window" from "there is more of it than you asked for"
        // without a second query.
        let ceiling = limit == Int.max ? limit : limit + 1

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: ceiling,
                sortDescriptors: [
                    NSSortDescriptor(
                        key: HKSampleSortIdentifierStartDate,
                        ascending: false
                    )
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(
                        throwing: HealthKitFailure.classify(
                            error,
                            typeIdentifier: key.rawValue
                        )
                    )
                    return
                }

                let found = samples ?? []
                // Checked before encoding, not after. A window that overflowed
                // is going to be asked for again in smaller pieces, and
                // encoding five hundred samples in order to throw them away is
                // the difference between a background launch finishing and
                // being killed.
                guard found.count <= limit else {
                    continuation.resume(returning: .truncated)
                    return
                }

                let encoded = Self.encode(
                    samples: found,
                    key: key,
                    catalogEntry: catalogEntry,
                    encoder: encoder,
                    medications: medications
                )
                continuation.resume(
                    returning: DatedHealthChanges(changes: encoded.changes)
                )
            }
            healthStore.execute(query)
        }
    }
}
