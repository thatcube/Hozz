import CryptoKit
import Foundation
import HozzCatalog
import HozzCore

/// The FHIR resource behind a clinical record, as values.
public struct FHIRResourceFacts: Equatable, Sendable {
    public let resourceType: String
    /// The identifier the provider gave this resource. Stable, unlike the
    /// record's HealthKit UUID.
    public let identifier: String
    public let fhirVersion: String?
    public let sourceURL: URL?
    /// The resource's own JSON, exactly as the provider sent it.
    public let data: Data

    public init(
        resourceType: String,
        identifier: String,
        fhirVersion: String?,
        sourceURL: URL?,
        data: Data
    ) {
        self.resourceType = resourceType
        self.identifier = identifier
        self.fhirVersion = fhirVersion
        self.sourceURL = sourceURL
        self.data = data
    }
}

public struct ClinicalRecordFacts: Equatable, Sendable {
    public let healthKitID: UUID
    public let clinicalType: String
    public let displayName: String
    public let sourceName: String
    public let sourceBundleIdentifier: String
    /// The dates Health assigned, which for a clinical record are when it was
    /// added to Health rather than when the care happened. The clinical dates
    /// live inside the FHIR resource.
    public let startDate: Date
    public let endDate: Date
    /// Absent for a record Health holds without a FHIR resource behind it.
    public let fhir: FHIRResourceFacts?

    public init(
        healthKitID: UUID,
        clinicalType: String,
        displayName: String,
        sourceName: String = "",
        sourceBundleIdentifier: String,
        startDate: Date = Date(timeIntervalSince1970: 0),
        endDate: Date = Date(timeIntervalSince1970: 0),
        fhir: FHIRResourceFacts?
    ) {
        self.healthKitID = healthKitID
        self.clinicalType = clinicalType
        self.displayName = displayName
        self.sourceName = sourceName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.startDate = startDate
        self.endDate = endDate
        self.fhir = fhir
    }
}

public enum ClinicalRecordEncoding {
    public static let kind = "clinicalRecord"

    /// A clinical record's identity, which is **not** its HealthKit UUID.
    ///
    /// Apple says so directly: for clinical records the UUID is not a stable
    /// identifier for a given sample, and the combination of source, FHIR
    /// resource type, and FHIR identifier should be used instead.
    ///
    /// That matters more here than anywhere else in Hozz. Every destination
    /// deduplicates on the record identifier, so keying a lab result on a UUID
    /// that changes would file the same result again on every sync — a growing
    /// pile of identical results, which in a medical record is not merely
    /// untidy but misleading.
    ///
    /// A record with no FHIR resource has nothing stable to derive from, so it
    /// keeps its UUID and says that it did.
    public static func identity(for record: ClinicalRecordFacts) -> (id: UUID, isStable: Bool) {
        guard let fhir = record.fhir, !fhir.identifier.isEmpty else {
            return (record.healthKitID, false)
        }

        var hasher = SHA256()
        hasher.update(data: Data("HKClinicalRecord".utf8))
        hasher.update(data: Data(record.sourceBundleIdentifier.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(fhir.resourceType.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(fhir.identifier.utf8))
        var bytes = Array(Array(hasher.finalize()).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return (
            UUID(
                uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                )
            ),
            true
        )
    }

    /// Adds the clinical fields to a record's base object.
    ///
    /// The FHIR resource is carried through as the provider sent it rather
    /// than reshaped into Hozz's own vocabulary. It is the authoritative
    /// artefact — a lab result's units, reference ranges, and coding systems
    /// are the clinical meaning, and any projection of ours would lose some of
    /// it while looking complete.
    public static func decorate(
        _ object: inout [String: Any],
        record: ClinicalRecordFacts
    ) {
        let identity = identity(for: record)
        object["kind"] = kind
        object["id"] = identity.id.uuidString.lowercased()
        object["clinicalType"] = record.clinicalType
        object["displayName"] = record.displayName
        // Kept so a record can still be traced back to this device's Health
        // database, and labelled so nobody mistakes it for the identity.
        object["healthKitUUID"] = record.healthKitID.uuidString.lowercased()
        object["identityIsStable"] = identity.isStable

        guard let fhir = record.fhir else {
            object["fhir"] = [
                "state": "absent",
                "reason": "Health holds this record without a FHIR resource behind it."
            ]
            return
        }

        var resource: [String: Any] = [
            "state": "present",
            "resourceType": fhir.resourceType,
            "identifier": fhir.identifier
        ]
        if let version = fhir.fhirVersion {
            resource["fhirVersion"] = version
        }
        if let url = fhir.sourceURL {
            resource["sourceURL"] = url.absoluteString
        }

        if
            let parsed = try? JSONSerialization.jsonObject(with: fhir.data),
            JSONSerialization.isValidJSONObject(parsed)
        {
            resource["resource"] = parsed
        } else {
            // Unparsable is not the same as absent. The bytes are kept so
            // nothing the provider sent is thrown away because Hozz could not
            // read it.
            resource["encoding"] = "base64"
            resource["resourceData"] = fhir.data.base64EncodedString()
        }
        object["fhir"] = resource
    }
}
