import Foundation
import HealthKit
import HozzAcquire
import HozzCatalog
import HozzCore
import HozzHealthFake
import HozzStore
import XCTest
@testable import HozzHealth

/// Characteristics are the context that makes every measurement in an export
/// interpretable, so these tests care about two things: that the record is
/// there and cannot be lost, and that a fact Hozz does not have is reported as
/// unknown rather than as a failure or as a value.
final class HealthCharacteristicsTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let steps = HealthTypeKey("HKQuantityTypeIdentifierStepCount")
    private let dateOfBirth = HealthTypeKey(
        "HKCharacteristicTypeIdentifierDateOfBirth"
    )
    private let biologicalSex = HealthTypeKey(
        "HKCharacteristicTypeIdentifierBiologicalSex"
    )
    private let bloodType = HealthTypeKey(
        "HKCharacteristicTypeIdentifierBloodType"
    )
    private let wheelchairUse = HealthTypeKey(
        "HKCharacteristicTypeIdentifierWheelchairUse"
    )

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
    }

    private func makeStore() throws -> HozzStore {
        try HozzStore(directory: directory.url.appending(path: "store"))
    }

    private func upsert(_ identifier: String, type: HealthTypeKey) -> HealthChange {
        .upsert(
            CapturedHealthObject(
                id: UUID(),
                type: type,
                canonicalPayload: Data(
                    #"{"kind":"quantity","sample":"\#(identifier)"}"#.utf8
                )
            )
        )
    }

    private func makeEngine(
        store: HozzStore,
        source: any HealthDataSource,
        types: [HealthTypeKey],
        characteristics: (any HealthCharacteristicsSource)?,
        batchSize: Int = 2
    ) -> HealthExportEngine {
        HealthExportEngine(
            store: store,
            source: source,
            types: types,
            characteristics: characteristics,
            batchSize: batchSize,
            lease: ExportWriterLease()
        )
    }

    /// A person with two facts set, one deliberately not, and one refused.
    private func sampleCharacteristics() -> [HealthCharacteristic] {
        [
            .known(dateOfBirth, value: "1985-04-11"),
            .known(biologicalSex, value: "female", rawValue: 1),
            .notSet(bloodType, rawValue: 0),
            .unreadable(
                wheelchairUse,
                coverage: .authorizationIndeterminate,
                reason: "Health refused."
            )
        ]
    }

    private func characteristicsRecords(
        in fileURL: URL
    ) throws -> [[String: Any]] {
        try ExportArtifactReader.records(in: fileURL)
            .filter { $0["kind"] as? String == "characteristics" }
    }

    // MARK: - Presence in the export

    func testAnExportCarriesTheCharacteristicsRecord() async throws {
        let store = try makeStore()
        let source = ScriptedHealthDataSource(
            streams: [steps: [upsert("step-0", type: steps)]]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            types: [steps],
            characteristics: ScriptedCharacteristicsSource(
                sampleCharacteristics()
            )
        )

        let outcome = try await engine.export(format: .ndjson) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        let records = try characteristicsRecords(in: result.fileURL)
        XCTAssertEqual(records.count, 1)
        XCTAssertNotNil(records[0]["canonicalId"] as? String)
        XCTAssertEqual(
            records[0]["canonicalType"] as? String,
            "person.characteristics"
        )
        XCTAssertNotNil(records[0]["recordVersion"] as? Int64)
        XCTAssertNotNil(records[0]["sourceRecord"] as? [String: Any])
        XCTAssertFalse(
            (records[0]["lineage"] as? [[String: Any]] ?? []).isEmpty
        )
        let values = try XCTUnwrap(
            records[0]["characteristics"] as? [String: Any]
        )
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(
            records[0]["readAt"] as? String,
            "2023-11-14T22:13:20.000Z"
        )
        XCTAssertEqual(
            records[0]["catalogVersion"] as? String,
            HealthTypeCatalog.version
        )
    }

    func testTheCharacteristicsRecordFollowsTheManifest() async throws {
        let store = try makeStore()
        let engine = makeEngine(
            store: store,
            source: ScriptedHealthDataSource(streams: [steps: []]),
            types: [steps],
            characteristics: ScriptedCharacteristicsSource(
                sampleCharacteristics()
            )
        )

        let outcome = try await engine.export(format: .ndjson) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        let kinds = try ExportArtifactReader.records(in: result.fileURL)
            .compactMap { $0["kind"] as? String }
        XCTAssertEqual(
            Array(kinds.prefix(2)),
            ["manifest", "characteristics"],
            "The person should be described before their measurements."
        )
    }

    func testCharacteristicsAreNotCountedAsHealthRecords() async throws {
        let store = try makeStore()
        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<3).map { upsert("step-\($0)", type: steps) }]
        )
        let engine = makeEngine(
            store: store,
            source: source,
            types: [steps],
            characteristics: ScriptedCharacteristicsSource(
                sampleCharacteristics()
            )
        )

        let outcome = try await engine.export(format: .ndjson) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        XCTAssertEqual(
            result.recordCount,
            3,
            "A characteristic is context, not a sample, and must not inflate the count."
        )
    }

    func testAnExportWithoutACharacteristicsSourceInventsNothing() async throws {
        let store = try makeStore()
        let engine = makeEngine(
            store: store,
            source: ScriptedHealthDataSource(
                streams: [steps: [upsert("step-0", type: steps)]]
            ),
            types: [steps],
            characteristics: nil
        )

        let outcome = try await engine.export(format: .ndjson) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        XCTAssertTrue(
            try characteristicsRecords(in: result.fileURL).isEmpty,
            "With nothing read, the export must claim nothing."
        )
    }

    /// The part holding the first copy can be discarded unsealed, so a resumed
    /// run reads them again rather than trusting bytes that were never durable.
    func testAResumedRunStillCarriesCharacteristics() async throws {
        let store = try makeStore()
        let source = ScriptedHealthDataSource(
            streams: [steps: (0..<4).map { upsert("step-\($0)", type: steps) }]
        )
        let characteristics = ScriptedCharacteristicsSource(
            sampleCharacteristics()
        )

        // Leave an unsealed part behind, exactly as a kill would.
        let run = try await store.createRun(
            format: HealthExportFormat.ndjson.rawValue,
            attemptedTypeCount: 1,
            catalogVersion: "test"
        )
        let sink = SpooledExportSink(
            store: store,
            runID: run.id,
            format: .ndjson,
            spoolDirectory: await store.spoolDirectory,
            nextSequence: 0,
            totalRecordCount: 0
        )
        try await sink.writeRecord([
            "kind": "manifest",
            "schemaVersion": 1
        ])
        let coordinator = DrainCoordinator(source: source, sink: sink)
        _ = try await coordinator.drain(type: steps, batchLimit: 2)

        let engine = makeEngine(
            store: store,
            source: source,
            types: [steps],
            characteristics: characteristics
        )
        let outcome = try await engine.export(format: .ndjson) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The resumed run should have completed.")
        }
        XCTAssertTrue(result.wasResumed)

        let records = try characteristicsRecords(in: result.fileURL)
        XCTAssertEqual(
            records.count,
            1,
            "A resumed run must still describe the person it exported."
        )
        let readCount = await characteristics.readCount
        XCTAssertEqual(readCount, 1)
    }

    // MARK: - Honest states

    func testEveryStateSurvivesEncodingWithItsOwnMeaning() async throws {
        let store = try makeStore()
        let engine = makeEngine(
            store: store,
            source: ScriptedHealthDataSource(streams: [steps: []]),
            types: [steps],
            characteristics: ScriptedCharacteristicsSource(
                sampleCharacteristics() + [
                    .unrecognised(
                        HealthTypeKey(
                            "HKCharacteristicTypeIdentifierFitzpatrickSkinType"
                        ),
                        rawValue: 99
                    ),
                    .unavailable(
                        HealthTypeKey(
                            "HKCharacteristicTypeIdentifierActivityMoveMode"
                        ),
                        reason: "Needs a newer iOS."
                    )
                ]
            )
        )

        let outcome = try await engine.export(format: .ndjson) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }
        let values = try XCTUnwrap(
            try characteristicsRecords(in: result.fileURL)
                .first?["characteristics"] as? [String: Any]
        )

        let birth = try XCTUnwrap(values[dateOfBirth.rawValue] as? [String: Any])
        XCTAssertEqual(birth["state"] as? String, "known")
        XCTAssertEqual(birth["value"] as? String, "1985-04-11")
        XCTAssertNil(
            birth["rawValue"],
            "A date of birth has no HealthKit enumeration value to report."
        )

        let sex = try XCTUnwrap(values[biologicalSex.rawValue] as? [String: Any])
        XCTAssertEqual(sex["state"] as? String, "known")
        XCTAssertEqual(sex["value"] as? String, "female")
        XCTAssertEqual(sex["rawValue"] as? Int, 1)

        let blood = try XCTUnwrap(values[bloodType.rawValue] as? [String: Any])
        XCTAssertEqual(blood["state"] as? String, "notSet")
        XCTAssertNil(
            blood["value"],
            "An unset blood type has no value to report."
        )
        XCTAssertNil(
            blood["coverage"],
            "Not set is an unknown fact about the person, not a coverage failure."
        )

        let wheelchair = try XCTUnwrap(
            values[wheelchairUse.rawValue] as? [String: Any]
        )
        XCTAssertEqual(wheelchair["state"] as? String, "unreadable")
        XCTAssertEqual(
            wheelchair["coverage"] as? String,
            CoverageState.authorizationIndeterminate.rawValue
        )
        XCTAssertEqual(wheelchair["reason"] as? String, "Health refused.")

        let skin = try XCTUnwrap(
            values["HKCharacteristicTypeIdentifierFitzpatrickSkinType"]
                as? [String: Any]
        )
        XCTAssertEqual(skin["state"] as? String, "unrecognised")
        XCTAssertEqual(
            skin["rawValue"] as? Int,
            99,
            "A value with no name must still keep the number, or the fact is lost."
        )

        let moveMode = try XCTUnwrap(
            values["HKCharacteristicTypeIdentifierActivityMoveMode"]
                as? [String: Any]
        )
        XCTAssertEqual(moveMode["state"] as? String, "unavailable")
    }

    func testCharacteristicsSortAndEncodeDeterministically() {
        let first = HealthCharacteristics(
            readAt: Date(timeIntervalSince1970: 1),
            characteristics: [
                .known(biologicalSex, value: "male", rawValue: 2),
                .known(dateOfBirth, value: "1970-01-01")
            ]
        )
        let second = HealthCharacteristics(
            readAt: Date(timeIntervalSince1970: 1),
            characteristics: [
                .known(dateOfBirth, value: "1970-01-01"),
                .known(biologicalSex, value: "male", rawValue: 2)
            ]
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.characteristics.map(\.type),
            [biologicalSex, dateOfBirth]
        )
    }

    // MARK: - Formats

    func testCSVCarriesEveryCharacteristicIncludingTheUnsetOnes() async throws {
        let store = try makeStore()
        let engine = makeEngine(
            store: store,
            source: ScriptedHealthDataSource(
                streams: [steps: [upsert("step-0", type: steps)]]
            ),
            types: [steps],
            characteristics: ScriptedCharacteristicsSource(
                sampleCharacteristics()
            )
        )

        let outcome = try await engine.export(format: .csv) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        let entries = try ExportArtifactReader.readZipEntries(at: result.fileURL)
        let csv = try XCTUnwrap(entries["characteristics.csv"])
        let rows = String(decoding: csv, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)

        XCTAssertEqual(
            rows.first,
            "readAt,type,state,value,rawValue,coverage,reason"
        )
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(
            rows.contains { $0.contains(bloodType.rawValue) && $0.contains("notSet") },
            "A spreadsheet must show 'not set' rather than an unexplained blank."
        )

        // The lossless copy is still in the log, so CSV's flattening does not
        // become the only record of what Health said.
        let log = try XCTUnwrap(entries["export-log.ndjson"])
        let logged = try ExportArtifactReader.lines(in: log)
            .filter { $0["kind"] as? String == "characteristics" }
        XCTAssertEqual(logged.count, 1)
    }

    func testJSONKeepsTheCharacteristicsRecordWhole() async throws {
        let store = try makeStore()
        let engine = makeEngine(
            store: store,
            source: ScriptedHealthDataSource(streams: [steps: []]),
            types: [steps],
            characteristics: ScriptedCharacteristicsSource(
                sampleCharacteristics()
            )
        )

        let outcome = try await engine.export(format: .json) { _ in }
        guard case .completed(let result) = outcome else {
            return XCTFail("The run should have completed.")
        }

        let data = try ExportArtifactReader.readSingleZipEntry(at: result.fileURL)
        let array = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let records = array.filter { $0["kind"] as? String == "characteristics" }
        XCTAssertEqual(records.count, 1)
        XCTAssertNotNil(records[0]["characteristics"] as? [String: Any])
    }

    // MARK: - HealthKit classification

    func testHealthAnsweringWithNoDataIsUnsetRatherThanAFailure() {
        let error = NSError(
            domain: HKError.errorDomain,
            code: HKError.Code.errorNoData.rawValue
        )

        let characteristic = HealthKitCharacteristicsReader.classify(
            error,
            for: dateOfBirth
        )

        XCTAssertEqual(characteristic.state, .notSet)
        XCTAssertNil(
            characteristic.coverage,
            "A date of birth nobody entered is an unknown fact, not an export problem."
        )
    }

    func testARefusedCharacteristicIsReportedAsRefusedRatherThanUnset() {
        let error = NSError(
            domain: HKError.errorDomain,
            code: HKError.Code.errorAuthorizationDenied.rawValue
        )

        let characteristic = HealthKitCharacteristicsReader.classify(
            error,
            for: biologicalSex
        )

        XCTAssertEqual(characteristic.state, .unreadable)
        XCTAssertEqual(characteristic.coverage, .authorizationIndeterminate)
        XCTAssertNil(characteristic.value)
    }

    func testALockedDeviceIsReportedAsDeferredRatherThanUnset() {
        let error = NSError(
            domain: HKError.errorDomain,
            code: HKError.Code.errorDatabaseInaccessible.rawValue
        )

        let characteristic = HealthKitCharacteristicsReader.classify(
            error,
            for: bloodType
        )

        XCTAssertEqual(characteristic.state, .unreadable)
        XCTAssertEqual(characteristic.coverage, .deviceLockedDeferred)
    }

    func testUnavailableHealthDataIsUnavailableRatherThanUnreadable() {
        let error = NSError(
            domain: HKError.errorDomain,
            code: HKError.Code.errorHealthDataUnavailable.rawValue
        )

        let characteristic = HealthKitCharacteristicsReader.classify(
            error,
            for: wheelchairUse
        )

        XCTAssertEqual(characteristic.state, .unavailable)
        XCTAssertEqual(characteristic.coverage, .unsupported)
    }

    func testAnUnclassifiedErrorIsNeverReportedAsAValue() {
        let characteristic = HealthKitCharacteristicsReader.classify(
            CocoaError(.fileReadNoSuchFile),
            for: dateOfBirth
        )

        XCTAssertEqual(characteristic.state, .unreadable)
        XCTAssertEqual(characteristic.coverage, .unknown)
        XCTAssertNil(characteristic.value)
    }

    // MARK: - Registry

    func testEveryCatalogCharacteristicIsReadableOnASupportedOS() {
        let catalogued = HealthTypeCatalog.entries
            .filter { $0.family == .characteristic }
            .map(\.key)
        let readable = HealthKitTypeRegistry.characteristicTypes(
            operatingSystem: OperatingSystemVersion(
                majorVersion: 17,
                minorVersion: 0,
                patchVersion: 0
            )
        )

        XCTAssertEqual(catalogued.count, 6)
        XCTAssertEqual(
            readable.map(\.catalogEntry.key).sorted(),
            catalogued.sorted()
        )
    }

    func testACharacteristicIsNotOfferedBeforeTheOSThatAddedIt() {
        let readable = HealthKitTypeRegistry.characteristicTypes(
            operatingSystem: OperatingSystemVersion(
                majorVersion: 8,
                minorVersion: 0,
                patchVersion: 0
            )
        )

        XCTAssertEqual(
            readable.map(\.catalogEntry.key).sorted(),
            [biologicalSex, bloodType, dateOfBirth].sorted(),
            "Move mode, skin type, and wheelchair use all postdate iOS 8."
        )
    }

    func testCharacteristicsAreRequestedAlongsideTheSampleTypes() {
        let requested = HealthKitTypeRegistry.authorizationReadTypes()
        let characteristics = HealthKitTypeRegistry.characteristicTypes()
            .map(\.characteristicType)

        XCTAssertFalse(characteristics.isEmpty)
        for type in characteristics {
            XCTAssertTrue(
                requested.contains(type),
                "\(type.identifier) is read, so it must also be asked for."
            )
        }
    }

    func testCharacteristicsStayOutOfTheSampleStream() {
        let families = Set(
            HealthKitTypeRegistry.exportableTypes().map(\.catalogEntry.family)
        )

        XCTAssertFalse(
            families.contains(.characteristic),
            "A characteristic has no anchor, so it must not join the anchored drain."
        )
    }
}
