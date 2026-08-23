import Foundation
import HozzCore

/// Reads clinical records, which cannot go through the anchored drain.
///
/// HealthKit does not support `HKAnchoredObjectQuery` for clinical types, so
/// the incremental machinery every other type inherits — an opaque cursor, a
/// deletion stream, a resumable position — simply does not exist here. It has
/// to be replaced with something, and the choice matters.
///
/// **A date cursor was rejected.** It is the obvious substitute and it is the
/// one thing Hozz has spent its whole design avoiding: Health accepts records
/// written retroactively, and a date window silently skips them. Clinical
/// records are the worst case for that, not the best — a provider import
/// arrives in bulk, all at once, carrying results dated months or years
/// earlier. A cursor set to "now" after the first import would skip the entire
/// history the next import brings in, and skip it silently.
///
/// **So every record is read every time, and identity does the work instead.**
/// A clinical record's identity is derived from source, resource type, and
/// FHIR identifier, which is stable across reads — Apple says the UUID is not
/// — so re-reading produces byte-identical records that a receiver recognises
/// as ones it already holds. Nothing is duplicated and nothing is skipped.
///
/// That trade is only sound because the volume is small: a person's lab
/// results, conditions, medications and immunisations are hundreds of records,
/// not the millions a quantity type can hold. If that ever stops being true,
/// the answer is still not a date cursor.
public protocol ClinicalRecordBackend: Sendable {
    /// Every record of one type, read whole. `nil` reports a type Health
    /// refused or could not answer for, which is not the same as an empty one.
    func records(
        of type: ExportableHealthType
    ) async throws -> [ClinicalRecordFacts]
}

public struct ClinicalReadOutcome: Equatable, Sendable {
    public let changes: [HealthChange]
    /// Types Health would not answer for, with the reason. Reported rather
    /// than counted as empty: a refused type and a type with no records look
    /// identical in the output otherwise, and only one of them is coverage.
    public let failures: [HealthTypeKey: String]

    public init(changes: [HealthChange], failures: [HealthTypeKey: String]) {
        self.changes = changes
        self.failures = failures
    }
}

public actor ClinicalRecordReader {
    private let backend: any ClinicalRecordBackend
    private let types: [ExportableHealthType]

    public init(
        backend: any ClinicalRecordBackend,
        types: [ExportableHealthType] = HealthKitTypeRegistry.clinicalTypes()
    ) {
        self.backend = backend
        self.types = types
    }

    /// Reads every clinical type the person has shared.
    ///
    /// One type failing does not stop the others. Partial access is the normal
    /// case here — consent is per record, and Hozz cannot see what was
    /// withheld — so a small result is never treated as an error.
    public func read() async -> ClinicalReadOutcome {
        var changes: [HealthChange] = []
        var failures: [HealthTypeKey: String] = [:]

        for type in types {
            let key = type.catalogEntry.key
            do {
                let records = try await backend.records(of: type)
                for record in records {
                    guard let change = Self.change(for: record, type: key) else {
                        continue
                    }
                    changes.append(change)
                }
            } catch {
                failures[key] = HealthKitFailure.classify(
                    error,
                    typeIdentifier: key.rawValue
                ).underlyingDescription
            }
        }

        // Sorted by identity so the same set of records always produces the
        // same bytes, whatever order Health returned them in.
        changes.sort { first, second in
            first.identifierForOrdering < second.identifierForOrdering
        }
        return ClinicalReadOutcome(changes: changes, failures: failures)
    }

    static func change(
        for record: ClinicalRecordFacts,
        type: HealthTypeKey
    ) -> HealthChange? {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "type": type.rawValue,
            "startDate": timestamp(record.startDate),
            "endDate": timestamp(record.endDate),
            "source": [
                "name": record.sourceName,
                "bundleIdentifier": record.sourceBundleIdentifier
            ]
        ]
        ClinicalRecordEncoding.decorate(&object, record: record)

        guard
            JSONSerialization.isValidJSONObject(object),
            let payload = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        else {
            return nil
        }
        return .upsert(
            CapturedHealthObject(
                id: ClinicalRecordEncoding.identity(for: record).id,
                type: type,
                canonicalPayload: payload
            )
        )
    }

    private static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(
            includingFractionalSeconds: true,
            timeZone: .gmt
        ).format(date)
    }
}

private extension HealthChange {
    var identifierForOrdering: String {
        switch self {
        case .upsert(let object):
            object.id.uuidString
        case .delete(let deletion):
            deletion.id.uuidString
        }
    }
}
