import Foundation
import HealthKit
import HozzAcquire
import HozzCatalog
import HozzCore
import HozzHealthFake
import HozzStore
import XCTest
@testable import HozzHealth

/// `HKMedicationDoseEvent` has no public initialiser and no factory, so a dose
/// cannot be fabricated. The shaping is therefore tested through the value
/// types the HealthKit bridge converts into, which is the seam that makes any
/// of this checkable at all.
final class MedicationTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let taken = NamedValue(name: "taken", rawValue: 4)
    private let scheduled = NamedValue(name: "schedule", rawValue: 2)
    private let scheduledDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private func dose(
        doseQuantity: Double? = 1,
        scheduledDoseQuantity: Double? = 1,
        scheduledDate: Date? = nil,
        logStatus: NamedValue? = nil
    ) -> MedicationDoseFacts {
        MedicationDoseFacts(
            scheduleType: scheduled,
            logStatus: logStatus ?? taken,
            unit: "count",
            doseQuantity: doseQuantity,
            scheduledDoseQuantity: scheduledDoseQuantity,
            scheduledDate: scheduledDate
        )
    }

    private var medication: MedicationConceptFacts {
        .resolved(
            displayText: "Atorvastatin 20 mg",
            nickname: "Statin",
            generalForm: "Tablet",
            isArchived: false,
            hasSchedule: true,
            codings: [
                MedicationCoding(system: "http://www.nlm.nih.gov/research/umls/rxnorm", code: "617312", version: nil),
                MedicationCoding(system: "http://snomed.info/sct", code: "108600003", version: "2024")
            ]
        )
    }

    // MARK: - Absent is not zero

    func testADoseNobodyLoggedIsAbsentRatherThanZero() {
        let object = MedicationEncoding.object(
            for: dose(doseQuantity: nil, scheduledDoseQuantity: nil),
            medication: medication
        )

        XCTAssertNil(
            object["doseQuantity"],
            "Logging nothing and taking none are different facts, and only one is zero."
        )
        XCTAssertNil(object["scheduledDoseQuantity"])
        XCTAssertNotNil(object["logStatus"], "The status is what makes the dose meaningful.")
    }

    func testADoseOfZeroIsKeptAsAReading() {
        let object = MedicationEncoding.object(
            for: dose(doseQuantity: 0),
            medication: medication
        )

        XCTAssertEqual(
            object["doseQuantity"] as? Double,
            0,
            "A recorded dose of zero is something the person logged."
        )
    }

    func testAnUnscheduledDoseCarriesNoScheduledDate() {
        let asNeeded = MedicationEncoding.object(
            for: dose(scheduledDate: nil),
            medication: medication
        )
        let onSchedule = MedicationEncoding.object(
            for: dose(scheduledDate: scheduledDate),
            medication: medication
        )

        XCTAssertNil(asNeeded["scheduledDate"])
        XCTAssertEqual(
            onSchedule["scheduledDate"] as? String,
            "2023-11-14T22:13:20.000Z"
        )
    }

    // MARK: - Status

    /// Taken, skipped, and never answered are three different facts about
    /// someone's treatment, and only the first means the medicine was used.
    @available(iOS 26.0, *)
    func testEveryLogStatusKeepsItsNameAndNumber() {
        let statuses: [(HKMedicationDoseEvent.LogStatus, String)] = [
            (.notInteracted, "notInteracted"),
            (.notificationNotSent, "notificationNotSent"),
            (.snoozed, "snoozed"),
            (.taken, "taken"),
            (.skipped, "skipped"),
            (.notLogged, "notLogged")
        ]

        for (status, name) in statuses {
            let named = HealthKitMedicationDirectory.named(status)
            XCTAssertEqual(named.name, name)
            XCTAssertEqual(named.rawValue, status.rawValue)
        }
    }

    @available(iOS 26.0, *)
    func testScheduleTypesKeepTheirNameAndNumber() {
        for type in [
            HKMedicationDoseEvent.ScheduleType.asNeeded,
            HKMedicationDoseEvent.ScheduleType.schedule
        ] {
            let named = HealthKitMedicationDirectory.named(type)
            XCTAssertNotEqual(named.name, "unrecognisedByHozz")
            XCTAssertEqual(named.rawValue, type.rawValue)
        }
    }

    // MARK: - The medication behind the dose

    func testAResolvedMedicationCarriesWhatItIs() throws {
        let object = MedicationEncoding.object(
            for: dose(),
            medication: medication
        )
        let named = try XCTUnwrap(object["medication"] as? [String: Any])

        XCTAssertEqual(named["state"] as? String, "resolved")
        XCTAssertEqual(named["displayText"] as? String, "Atorvastatin 20 mg")
        XCTAssertEqual(named["nickname"] as? String, "Statin")
        XCTAssertEqual(named["generalForm"] as? String, "Tablet")
        XCTAssertEqual(named["isArchived"] as? Bool, false)

        let codings = try XCTUnwrap(named["codings"] as? [[String: Any]])
        XCTAssertEqual(codings.count, 2)
        XCTAssertEqual(
            codings.compactMap { $0["code"] as? String },
            ["108600003", "617312"],
            "Codings arrive as a set, so they are sorted to encode the same way twice."
        )
        XCTAssertEqual(codings[0]["version"] as? String, "2024")
        XCTAssertNil(
            codings[1]["version"],
            "A version HealthKit did not give must not be invented."
        )
    }

    func testAnUnresolvedMedicationSaysSoRatherThanGoingBlank() throws {
        let object = MedicationEncoding.object(
            for: dose(),
            medication: .unresolved(reason: "Not in the medication list.")
        )
        let named = try XCTUnwrap(object["medication"] as? [String: Any])

        XCTAssertEqual(named["state"] as? String, "unresolved")
        XCTAssertEqual(named["reason"] as? String, "Not in the medication list.")
        XCTAssertNil(
            named["displayText"],
            "An unresolved medication must not be given a name."
        )
    }

    func testCodingsSortIntoTheSameOrderWhicheverWayTheyArrive() {
        let forwards = MedicationEncoding.object(
            for: dose(),
            medication: .resolved(
                displayText: "x",
                nickname: nil,
                generalForm: "Tablet",
                isArchived: false,
                hasSchedule: false,
                codings: [
                    MedicationCoding(system: "a", code: "1", version: nil),
                    MedicationCoding(system: "b", code: "2", version: nil)
                ]
            )
        )
        let backwards = MedicationEncoding.object(
            for: dose(),
            medication: .resolved(
                displayText: "x",
                nickname: nil,
                generalForm: "Tablet",
                isArchived: false,
                hasSchedule: false,
                codings: [
                    MedicationCoding(system: "b", code: "2", version: nil),
                    MedicationCoding(system: "a", code: "1", version: nil)
                ]
            )
        )

        let first = (forwards["medication"] as? [String: Any])?["codings"]
            as? [[String: Any]]
        let second = (backwards["medication"] as? [String: Any])?["codings"]
            as? [[String: Any]]
        XCTAssertEqual(
            first?.compactMap { $0["system"] as? String },
            second?.compactMap { $0["system"] as? String }
        )
    }

    // MARK: - Through an export

    private func record(
        _ facts: MedicationDoseFacts,
        medication: MedicationConceptFacts,
        id: UUID = UUID()
    ) throws -> HealthChange {
        var object: [String: Any] = [
            "kind": "medicationDose",
            "schemaVersion": 1,
            "id": id.uuidString.lowercased(),
            "type": MedicationEncoding.typeIdentifier,
            "startDate": "2023-11-14T22:13:20.000Z",
            "endDate": "2023-11-14T22:13:20.000Z",
            "source": ["name": "Health", "bundleIdentifier": "com.apple.health"]
        ]
        object.merge(
            MedicationEncoding.object(for: facts, medication: medication)
        ) { current, _ in current }

        return .upsert(
            CapturedHealthObject(
                id: id,
                type: MedicationEncoding.typeKey,
                canonicalPayload: try JSONSerialization.data(
                    withJSONObject: object,
                    options: [.sortedKeys]
                )
            )
        )
    }

    func testCSVKeepsTheStatusAndLeavesAnUnloggedDoseBlank() async throws {
        let store = try makeStore()
        let engine = HealthExportEngine(
            store: store,
            source: ScriptedHealthDataSource(
                streams: [
                    MedicationEncoding.typeKey: [
                        try record(dose(), medication: medication),
                        try record(
                            dose(
                                doseQuantity: nil,
                                scheduledDoseQuantity: nil,
                                logStatus: NamedValue(name: "skipped", rawValue: 5)
                            ),
                            medication: .unresolved(reason: "gone")
                        )
                    ]
                ]
            ),
            types: [MedicationEncoding.typeKey],
            lease: ExportWriterLease()
        )

        let outcome = try await engine.export(format: .csv) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }
        let entries = try ExportArtifactReader.readZipEntries(at: result.fileURL)

        let csv = try XCTUnwrap(entries["MedicationDoses.csv"])
        let rows = String(decoding: csv, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows[0].hasPrefix("id,startDate,endDate,medication,nickname"))
        XCTAssertTrue(rows[1].contains("Atorvastatin 20 mg"))
        XCTAssertTrue(rows[1].contains("taken"))
        XCTAssertTrue(
            rows[2].contains("skipped"),
            "A skipped dose is a fact about treatment, not an empty row."
        )
        XCTAssertTrue(
            rows[2].contains("unresolved"),
            "A medication Hozz could not name must say so rather than go blank."
        )
    }

    // MARK: - Catalog and registry

    func testMedicationDosesAreCataloguedAndOffered() throws {
        let entry = try XCTUnwrap(
            HealthTypeCatalog.entriesByIdentifier[
                MedicationEncoding.typeIdentifier
            ]
        )

        XCTAssertEqual(entry.family, .medication)
        XCTAssertEqual(entry.displayName, "Medication Dose")
        XCTAssertEqual(entry.introduced, IOSVersion(major: 26, minor: 0))
    }

    func testMedicationDosesAreNotOfferedBeforeTheOSThatAddedThem() {
        let onEighteen = HealthKitTypeRegistry.exportableTypes(
            operatingSystem: OperatingSystemVersion(
                majorVersion: 18,
                minorVersion: 0,
                patchVersion: 0
            )
        )

        XCTAssertFalse(
            onEighteen.contains {
                $0.catalogEntry.key == MedicationEncoding.typeKey
            },
            "Offering a type the OS does not have could only ever report nothing."
        )
    }

    func testMedicationDosesAreNotClinicalRecords() {
        let clinical = HealthTypeCatalog.entries
            .filter { $0.family == .clinical }
            .map(\.key.rawValue)

        XCTAssertTrue(
            clinical.contains("HKClinicalTypeIdentifierMedicationRecord"),
            "The clinical medication record still exists and is a different thing."
        )
        XCTAssertFalse(
            clinical.contains(MedicationEncoding.typeIdentifier),
            "Dose logging needs no clinical entitlement and must not be filed as one."
        )
    }
}
