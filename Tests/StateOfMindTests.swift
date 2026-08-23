import Foundation
import HealthKit
import HozzAcquire
import HozzCatalog
import HozzCore
import HozzHealthFake
import HozzStore
import XCTest
@testable import HozzHealth

/// A mood entry is the one place where a blank and a zero are easiest to
/// confuse: valence runs from -1 to 1 and zero is neutral, not missing. These
/// tests exist mostly to keep that distinction true.
@available(iOS 18.0, *)
final class StateOfMindTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let moment = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
        try XCTSkipUnless(
            HKHealthStore.isHealthDataAvailable(),
            "State of Mind needs HealthKit."
        )
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private var catalogEntry: HealthCatalogEntry {
        get throws {
            try XCTUnwrap(
                HealthTypeCatalog.entriesByIdentifier[
                    StateOfMindEncoding.typeIdentifier
                ]
            )
        }
    }

    private func sample(
        valence: Double,
        kind: HKStateOfMind.Kind = .momentaryEmotion,
        labels: [HKStateOfMind.Label] = [.happy, .grateful],
        associations: [HKStateOfMind.Association] = [.work]
    ) -> HKStateOfMind {
        HKStateOfMind(
            date: moment,
            kind: kind,
            valence: valence,
            labels: labels,
            associations: associations
        )
    }

    private func encode(_ sample: HKStateOfMind) throws -> [String: Any] {
        let data = try HealthSampleEncoder().encode(
            sample: sample,
            catalogEntry: try catalogEntry
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: - The zero that is not a blank

    func testANeutralMoodIsWrittenRatherThanOmitted() throws {
        let object = try encode(sample(valence: 0))

        XCTAssertEqual(object["kind"] as? String, "stateOfMind")
        XCTAssertNotNil(
            object["valence"],
            "Zero valence is a neutral mood someone recorded, not a missing value."
        )
        XCTAssertEqual(object["valence"] as? Double, 0)
        let classification = try XCTUnwrap(
            object["valenceClassification"] as? [String: Any]
        )
        XCTAssertEqual(classification["name"] as? String, "neutral")
    }

    func testTheEndsOfTheScaleSurviveIntact() throws {
        let veryUnpleasant = try encode(sample(valence: -1))
        let veryPleasant = try encode(sample(valence: 1))

        XCTAssertEqual(veryUnpleasant["valence"] as? Double, -1)
        XCTAssertEqual(
            (veryUnpleasant["valenceClassification"] as? [String: Any])?["name"]
                as? String,
            "veryUnpleasant"
        )
        XCTAssertEqual(veryPleasant["valence"] as? Double, 1)
        XCTAssertEqual(
            (veryPleasant["valenceClassification"] as? [String: Any])?["name"]
                as? String,
            "veryPleasant"
        )
    }

    func testAnEntryWithNoLabelsKeepsAnEmptyListRatherThanNothing() throws {
        let object = try encode(
            sample(valence: 0.5, labels: [], associations: [])
        )

        XCTAssertEqual(
            (object["labels"] as? [[String: Any]])?.count,
            0,
            "Choosing no labels is a fact, and the list should say so."
        )
        XCTAssertNotNil(object["labels"])
        XCTAssertNotNil(object["associations"])
    }

    // MARK: - Shape

    func testLabelsAndAssociationsKeepTheirNamesAndNumbers() throws {
        let object = try encode(
            sample(
                valence: 0.8,
                labels: [.joyful, .proud],
                associations: [.family, .fitness]
            )
        )

        let labels = try XCTUnwrap(object["labels"] as? [[String: Any]])
        XCTAssertEqual(labels.compactMap { $0["name"] as? String }, ["joyful", "proud"])
        XCTAssertEqual(
            labels.compactMap { $0["rawValue"] as? Int },
            [HKStateOfMind.Label.joyful.rawValue, HKStateOfMind.Label.proud.rawValue],
            "A feeling Apple adds later must still arrive as its number."
        )

        let associations = try XCTUnwrap(
            object["associations"] as? [[String: Any]]
        )
        XCTAssertEqual(
            associations.compactMap { $0["name"] as? String },
            ["family", "fitness"]
        )
    }

    func testTheKindOfEntryIsCarried() throws {
        let momentary = try encode(sample(valence: 0.2, kind: .momentaryEmotion))
        let daily = try encode(sample(valence: 0.2, kind: .dailyMood))

        XCTAssertEqual(
            (momentary["kindOfEntry"] as? [String: Any])?["name"] as? String,
            "momentaryEmotion"
        )
        XCTAssertEqual(
            (daily["kindOfEntry"] as? [String: Any])?["name"] as? String,
            "dailyMood",
            "A daily mood and a momentary feeling are not the same reading."
        )
    }

    func testEveryLabelAndAssociationHasAName() {
        for raw in 1...38 {
            guard let label = HKStateOfMind.Label(rawValue: raw) else {
                continue
            }
            XCTAssertNotEqual(
                StateOfMindEncoding.named(label: label)["name"] as? String,
                "unrecognisedByHozz",
                "Label \(raw) has no name, so an entry using it would lose its meaning."
            )
        }
        for raw in 1...18 {
            guard let association = HKStateOfMind.Association(rawValue: raw) else {
                continue
            }
            XCTAssertNotEqual(
                StateOfMindEncoding.named(association: association)["name"] as? String,
                "unrecognisedByHozz",
                "Association \(raw) has no name."
            )
        }
    }

    func testAMoodEntryCarriesTheDatesTheReceiverNeeds() throws {
        let object = try encode(sample(valence: 0))

        XCTAssertNotNil(object["startDate"] as? String)
        XCTAssertNotNil(object["endDate"] as? String)
        XCTAssertEqual(
            object["type"] as? String,
            StateOfMindEncoding.typeIdentifier
        )
    }

    func testTheEncodingIsStableForTheSameEntry() throws {
        let entry = sample(valence: -0.4)
        let encoder = HealthSampleEncoder()

        let first = try encoder.encode(sample: entry, catalogEntry: try catalogEntry)
        let second = try encoder.encode(sample: entry, catalogEntry: try catalogEntry)

        XCTAssertEqual(first, second)
    }

    // MARK: - Through an export

    func testCSVKeepsTheValenceAndTheLabels() async throws {
        let store = try makeStore()
        let entry = sample(
            valence: 0,
            labels: [.calm, .content],
            associations: [.selfCare]
        )
        let payload = try HealthSampleEncoder().encode(
            sample: entry,
            catalogEntry: try catalogEntry
        )
        let engine = HealthExportEngine(
            store: store,
            source: ScriptedHealthDataSource(
                streams: [
                    StateOfMindEncoding.typeKey: [
                        .upsert(
                            CapturedHealthObject(
                                id: entry.uuid,
                                type: StateOfMindEncoding.typeKey,
                                canonicalPayload: payload
                            )
                        )
                    ]
                ]
            ),
            types: [StateOfMindEncoding.typeKey],
            lease: ExportWriterLease()
        )

        let outcome = try await engine.export(format: .csv) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }
        let entries = try ExportArtifactReader.readZipEntries(at: result.fileURL)

        let csv = try XCTUnwrap(entries["StateOfMind.csv"])
        let rows = String(decoding: csv, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(
            rows[0].hasPrefix("id,startDate,endDate,kind,valence,valenceClassification,labels,associations")
        )
        let fields = rows[1].split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        XCTAssertTrue(
            fields.contains("0"),
            "A neutral mood must appear as 0 rather than as an empty cell."
        )
        XCTAssertTrue(rows[1].contains("calm;content"))
        XCTAssertTrue(rows[1].contains("selfCare"))
    }

    func testAMoodEntryCanBeChartedByValence() throws {
        let payload = try HealthSampleEncoder().encode(
            sample: sample(valence: -0.6),
            catalogEntry: try catalogEntry
        )
        let record = try XCTUnwrap(ExportRecord(line: payload))

        XCTAssertEqual(record.kind, "stateOfMind")
        XCTAssertEqual(
            record.value,
            -0.6,
            "Mood is only useful over time if it carries a number to chart."
        )
        XCTAssertNil(record.unit, "Valence is a scale, not a unit of measure.")
        XCTAssertFalse(record.isRunRecord)
    }

    // MARK: - Catalog and registry

    func testStateOfMindIsCataloguedAndOffered() throws {
        let entry = try catalogEntry

        XCTAssertEqual(entry.family, .stateOfMind)
        XCTAssertEqual(entry.displayName, "State of Mind")
        XCTAssertEqual(entry.introduced, IOSVersion(major: 18, minor: 0))
        XCTAssertTrue(
            HealthKitTypeRegistry.exportableTypes().contains {
                $0.catalogEntry.key == StateOfMindEncoding.typeKey
            }
        )
        XCTAssertTrue(
            HealthKitTypeRegistry.authorizationReadTypes().contains(
                HKObjectType.stateOfMindType()
            ),
            "A type Hozz reads must also be one it asked for."
        )
    }

    func testStateOfMindIsNotOfferedBeforeTheOSThatAddedIt() {
        let onSeventeen = HealthKitTypeRegistry.exportableTypes(
            operatingSystem: OperatingSystemVersion(
                majorVersion: 17,
                minorVersion: 0,
                patchVersion: 0
            )
        )

        XCTAssertFalse(
            onSeventeen.contains {
                $0.catalogEntry.key == StateOfMindEncoding.typeKey
            },
            "Offering a type the OS does not have could only ever report nothing."
        )
    }
}
