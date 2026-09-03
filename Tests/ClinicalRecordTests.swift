import Foundation
import HealthKit
import HozzCatalog
import HozzCore
import XCTest
@testable import HozzHealth

/// Clinical records are the one family where partial access is normal, the
/// identity is not the UUID, and the whole feature must stay switched off
/// until Apple approves the entitlement. These tests hold all three.
final class ClinicalRecordTests: XCTestCase {
    private let labResult = HealthTypeKey("HKClinicalTypeIdentifierLabResultRecord")

    private func fhir(
        identifier: String = "obs-1",
        resourceType: String = "Observation",
        json: String = #"{"resourceType":"Observation","id":"obs-1","status":"final"}"#
    ) -> FHIRResourceFacts {
        FHIRResourceFacts(
            resourceType: resourceType,
            identifier: identifier,
            fhirVersion: "4.0.1",
            sourceURL: URL(string: "https://example.org/fhir/Observation/obs-1"),
            data: Data(json.utf8)
        )
    }

    private func record(
        healthKitID: UUID = UUID(),
        source: String = "com.example.hospital",
        fhir: FHIRResourceFacts? = nil
    ) -> ClinicalRecordFacts {
        ClinicalRecordFacts(
            healthKitID: healthKitID,
            clinicalType: labResult.rawValue,
            displayName: "Haemoglobin",
            sourceBundleIdentifier: source,
            fhir: fhir ?? self.fhir()
        )
    }

    private func encode(_ facts: ClinicalRecordFacts) -> [String: Any] {
        var object: [String: Any] = [
            "schemaVersion": 1,
            "type": labResult.rawValue,
            "startDate": "2023-11-14T22:13:20.000Z",
            "endDate": "2023-11-14T22:13:20.000Z"
        ]
        ClinicalRecordEncoding.decorate(&object, record: facts)
        return object
    }

    // MARK: - Off unless deliberately switched on

    /// The constraint that matters most: a binary carrying the health-records
    /// entitlement before Apple approves it is rejected outright.
    func testClinicalRecordsAreCompiledOutOfTheDefaultBuild() {
        #if HOZZ_CLINICAL_RECORDS
        XCTAssertTrue(ClinicalRecordsSupport.isBuiltIn)
        #else
        XCTAssertFalse(
            ClinicalRecordsSupport.isBuiltIn,
            "The default build must not be able to ask for health records."
        )
        XCTAssertTrue(
            HealthKitTypeRegistry.clinicalTypes().isEmpty,
            "A build that cannot read them must not offer them either."
        )
        #endif
    }

    func testAnUnavailableBuildSaysSoRatherThanClaimingThereAreNoRecords() {
        let availability = ClinicalRecordsSupport.availability(
            isHealthDataAvailable: true,
            supportsHealthRecords: true
        )

        #if HOZZ_CLINICAL_RECORDS
        XCTAssertEqual(availability, .availableWithPermission)
        #else
        XCTAssertEqual(availability, .notInThisBuild)
        XCTAssertTrue(
            availability.explanation.contains("says nothing about whether you have any"),
            "Someone with a hospital connected must not be told their records are empty."
        )
        XCTAssertFalse(availability.canRead)
        #endif
    }

    func testHealthBeingUnavailableIsADistinctStateFromTheBuild() {
        let unavailable = ClinicalRecordsSupport.availability(
            isHealthDataAvailable: false,
            supportsHealthRecords: true
        )

        #if HOZZ_CLINICAL_RECORDS
        XCTAssertEqual(unavailable, .healthDataUnavailable)
        #else
        XCTAssertEqual(
            unavailable,
            .notInThisBuild,
            "The build is the more fundamental reason and is reported first."
        )
        #endif
    }

    /// The two switches have to agree, and the failure when they do not is
    /// fatal rather than merely unhelpful: asking HealthKit about a clinical
    /// type without the entitlement raises, and the app is gone.
    func testAnEntitledBuildOnAnUnsupportingDeviceRefusesToAsk() {
        let availability = ClinicalRecordsSupport.availability(
            isHealthDataAvailable: true,
            supportsHealthRecords: false
        )

        #if HOZZ_CLINICAL_RECORDS
        XCTAssertEqual(availability, .unsupportedOnThisDevice)
        #else
        XCTAssertEqual(availability, .notInThisBuild)
        #endif
        XCTAssertFalse(
            availability.canRead,
            "Nothing may ask HealthKit about a clinical type here."
        )
        XCTAssertTrue(
            availability.explanation.contains("says nothing about whether you have any"),
            "An unsupported device is not a statement about the person's records."
        )
    }

    /// Lifting the per-object filter for clinical records must not quietly
    /// admit anything else it was holding back.
    func testNothingElsePerObjectAuthorizedSlipsIntoTheOfferedSet() {
        for exportable in HealthKitTypeRegistry.exportableTypes()
            + HealthKitTypeRegistry.clinicalTypes() {
            guard exportable.sampleType.requiresPerObjectAuthorization() else {
                continue
            }
            XCTAssertEqual(
                exportable.catalogEntry.family,
                .clinical,
                "\(exportable.catalogEntry.key.rawValue) needs per-object consent and is not a clinical record."
            )
        }
    }

    func testClinicalTypesAreAbsentFromTheOrdinaryOfferedSet() {
        let families = Set(
            HealthKitTypeRegistry.exportableTypes().map(\.catalogEntry.family)
        )

        XCTAssertFalse(
            families.contains(.clinical),
            "The main Health prompt must never ask for someone's lab results."
        )
    }

    func testAskingForClinicalRecordsRequestsOnlyClinicalRecords() {
        let clinical = Set(
            HealthKitTypeRegistry.clinicalTypes().map(\.catalogEntry.key)
        )
        let ordinary = Set(
            HealthKitTypeRegistry.exportableTypes().map(\.catalogEntry.key)
        )

        XCTAssertTrue(
            clinical.isDisjoint(with: ordinary),
            "The two consent flows must not overlap."
        )
    }

    // MARK: - Identity

    /// Apple says a clinical record's UUID is not a stable identifier and that
    /// source, resource type, and FHIR identifier should be used instead. Every
    /// destination deduplicates on the identifier, so getting this wrong files
    /// the same lab result again on every sync.
    func testARecordKeepsTheSameIdentityAcrossDifferentHealthKitUUIDs() {
        let first = ClinicalRecordEncoding.identity(
            for: record(healthKitID: UUID())
        )
        let second = ClinicalRecordEncoding.identity(
            for: record(healthKitID: UUID())
        )

        XCTAssertTrue(first.isStable)
        XCTAssertEqual(
            first.id,
            second.id,
            "A UUID that changes must not become a new record every sync."
        )
    }

    func testDifferentResourcesAreDifferentRecords() {
        let observation = ClinicalRecordEncoding.identity(for: record())
        let other = ClinicalRecordEncoding.identity(
            for: record(fhir: fhir(identifier: "obs-2"))
        )
        let otherProvider = ClinicalRecordEncoding.identity(
            for: record(source: "com.example.other")
        )
        let otherType = ClinicalRecordEncoding.identity(
            for: record(fhir: fhir(resourceType: "Condition"))
        )

        XCTAssertEqual(
            Set([observation.id, other.id, otherProvider.id, otherType.id]).count,
            4,
            "Two providers can use the same resource identifier."
        )
    }

    func testARecordWithNoFHIRResourceKeepsItsUUIDAndSaysSo() throws {
        let id = UUID()
        var facts = record(healthKitID: id)
        facts = ClinicalRecordFacts(
            healthKitID: facts.healthKitID,
            clinicalType: facts.clinicalType,
            displayName: facts.displayName,
            sourceBundleIdentifier: facts.sourceBundleIdentifier,
            fhir: nil
        )
        let object = encode(facts)

        XCTAssertEqual(object["id"] as? String, id.uuidString.lowercased())
        XCTAssertEqual(
            object["identityIsStable"] as? Bool,
            false,
            "Nothing stable to derive from is a fact worth stating."
        )
        let fhir = try XCTUnwrap(object["fhir"] as? [String: Any])
        XCTAssertEqual(fhir["state"] as? String, "absent")
    }

    // MARK: - The resource itself

    func testTheProvidersFHIRResourceIsCarriedThroughUnchanged() throws {
        let object = encode(record())
        let fhir = try XCTUnwrap(object["fhir"] as? [String: Any])
        let resource = try XCTUnwrap(fhir["resource"] as? [String: Any])

        XCTAssertEqual(fhir["state"] as? String, "present")
        XCTAssertEqual(fhir["resourceType"] as? String, "Observation")
        XCTAssertEqual(fhir["identifier"] as? String, "obs-1")
        XCTAssertEqual(fhir["fhirVersion"] as? String, "4.0.1")
        XCTAssertEqual(
            resource["status"] as? String,
            "final",
            "The resource is the clinical meaning and is not reshaped."
        )
        XCTAssertEqual(resource["id"] as? String, "obs-1")
    }

    func testAResourceHozzCannotParseIsKeptRatherThanDiscarded() throws {
        let object = encode(
            record(fhir: fhir(json: "this is not JSON"))
        )
        let fhir = try XCTUnwrap(object["fhir"] as? [String: Any])

        XCTAssertEqual(fhir["state"] as? String, "present")
        XCTAssertEqual(fhir["encoding"] as? String, "base64")
        XCTAssertEqual(
            (fhir["resourceData"] as? String)
                .flatMap { Data(base64Encoded: $0) }
                .map { String(decoding: $0, as: UTF8.self) },
            "this is not JSON",
            "Unreadable is not the same as absent."
        )
    }

    func testTheHealthKitUUIDIsKeptButLabelled() throws {
        let id = UUID()
        let object = encode(record(healthKitID: id))

        XCTAssertEqual(
            object["healthKitUUID"] as? String,
            id.uuidString.lowercased()
        )
        XCTAssertNotEqual(
            object["id"] as? String,
            id.uuidString.lowercased(),
            "The identity is derived; the UUID is kept only for tracing."
        )
        XCTAssertEqual(
            object["canonicalId"] as? String,
            "apple.healthkit:\(object["id"] as? String ?? "")"
        )
        XCTAssertEqual(
            object["canonicalType"] as? String,
            "clinical.record"
        )
        XCTAssertEqual(object["kind"] as? String, "clinicalRecord")
        XCTAssertEqual(object["displayName"] as? String, "Haemoglobin")
    }

    func testAStableClinicalIdentityCarriesAMonotonicObservedVersion() throws {
        let first = ClinicalRecordFacts(
            healthKitID: UUID(),
            clinicalType: labResult.rawValue,
            displayName: "Haemoglobin",
            sourceBundleIdentifier: "com.example.hospital",
            startDate: Date(timeIntervalSince1970: 100),
            endDate: Date(timeIntervalSince1970: 100),
            fhir: fhir()
        )
        let second = ClinicalRecordFacts(
            healthKitID: UUID(),
            clinicalType: labResult.rawValue,
            displayName: "Haemoglobin",
            sourceBundleIdentifier: "com.example.hospital",
            startDate: Date(timeIntervalSince1970: 200),
            endDate: Date(timeIntervalSince1970: 200),
            fhir: fhir()
        )

        let firstObject = encode(first)
        let secondObject = encode(second)

        XCTAssertEqual(firstObject["canonicalId"] as? String, secondObject["canonicalId"] as? String)
        XCTAssertEqual(firstObject["recordVersion"] as? Int64, 100_000)
        XCTAssertEqual(secondObject["recordVersion"] as? Int64, 200_000)
    }

    func testTheSameRecordEncodesTheSameWayTwice() {
        let facts = record(healthKitID: UUID())

        let first = try? JSONSerialization.data(
            withJSONObject: encode(facts),
            options: [.sortedKeys]
        )
        let second = try? JSONSerialization.data(
            withJSONObject: encode(facts),
            options: [.sortedKeys]
        )

        XCTAssertEqual(first, second)
    }
}
