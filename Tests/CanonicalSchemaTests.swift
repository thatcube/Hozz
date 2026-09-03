import Foundation
import HozzCore
@testable import HozzHealth
import XCTest

final class CanonicalSchemaTests: XCTestCase {
    private var schemaRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "schema/hozz/v1")
    }

    func testSchemasAndGeneratedConstantsAgreeOnVersion() throws {
        let manifest = try object(
            at: schemaRoot.appending(path: "archive-manifest.schema.json")
        )
        let properties = try XCTUnwrap(manifest["properties"] as? [String: Any])
        let version = try XCTUnwrap(properties["schemaVersion"] as? [String: Any])

        XCTAssertEqual(version["const"] as? Int, HozzArchiveContract.schemaVersion)
        XCTAssertEqual(HozzArchiveContract.format, "hozz-ndjson")
        XCTAssertEqual(HozzArchiveContract.recordSchema, "hozz/v1/canonical-record")
    }

    func testMappingContractNamesEveryRequiredFirstSliceType() throws {
        let mappings = try object(
            at: schemaRoot.appending(path: "health-connect-mappings.json")
        )
        let records = try XCTUnwrap(
            mappings["recordMappings"] as? [[String: Any]]
        )
        let identifiers = Set(records.compactMap {
            $0["sourceIdentifier"] as? String
        })

        XCTAssertEqual(identifiers, HozzArchiveContract.healthConnectMappedTypes)
        XCTAssertTrue(identifiers.contains("HKQuantityTypeIdentifierStepCount"))
        XCTAssertTrue(identifiers.contains("HKQuantityTypeIdentifierHeartRate"))
        XCTAssertTrue(identifiers.contains("HKQuantityTypeIdentifierBodyMass"))
        XCTAssertTrue(identifiers.contains("HKQuantityTypeIdentifierHeight"))
        XCTAssertTrue(
            identifiers.contains("HKCategoryTypeIdentifierSleepAnalysis")
        )
        XCTAssertTrue(
            identifiers.contains("HKQuantityTypeIdentifierDistanceWalkingRunning")
        )
        XCTAssertTrue(
            identifiers.contains("HKQuantityTypeIdentifierActiveEnergyBurned")
        )
        XCTAssertTrue(identifiers.contains("HKWorkoutTypeIdentifier"))
    }

    func testCanonicalFixtureKeepsIdentityLineageAndSourceFacts() throws {
        let fixture = try String(
            contentsOf: schemaRoot
                .appending(path: "fixtures/canonical-records.ndjson"),
            encoding: .utf8
        )
        let records = try fixture
            .split(separator: "\n")
            .map { line -> [String: Any] in
                try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(line.utf8))
                        as? [String: Any]
                )
            }

        XCTAssertEqual(records.count, 3)
        for record in records {
            let id = try XCTUnwrap(record["id"] as? String)
            let canonicalID = try XCTUnwrap(record["canonicalId"] as? String)
            XCTAssertNotNil(record["canonicalType"] as? String)
            XCTAssertEqual(record["recordVersion"] as? Int, 1)
            let sourceRecord = try XCTUnwrap(
                record["sourceRecord"] as? [String: Any]
            )
            XCTAssertNotNil(sourceRecord["id"] as? String)
            XCTAssertNotNil(sourceRecord["type"] as? String)
            XCTAssertEqual(
                sourceRecord["store"] as? String,
                "apple.healthkit"
            )
            XCTAssertEqual(
                canonicalID,
                HozzArchiveContract.canonicalID(
                    store: "apple.healthkit",
                    id: id
                )
            )
            if let parent = record["parentCanonicalId"] as? String {
                XCTAssertEqual(
                    parent,
                    HozzArchiveContract.canonicalID(
                        store: "apple.healthkit",
                        id: try XCTUnwrap(sourceRecord["id"] as? String)
                    )
                )
            }
            XCTAssertFalse(
                (record["lineage"] as? [[String: Any]] ?? []).isEmpty
            )
        }
        let quantity = try XCTUnwrap(records[0]["quantity"] as? [String: Any])
        XCTAssertNotNil(quantity["canonical"] as? [String: Any])
        XCTAssertNotNil(quantity["original"] as? [String: Any])
    }

    func testEncodingFailureIdentityMatchesCrossPlatformFixture() throws {
        let vectors = try object(
            at: schemaRoot.appending(path: "fixtures/identity-vectors.json")
        )
        let vector = try XCTUnwrap(
            vectors["encodingFailure"] as? [String: Any]
        )
        let sourceID = try XCTUnwrap(
            UUID(uuidString: try XCTUnwrap(vector["sourceRecordId"] as? String))
        )
        let sourceType = try XCTUnwrap(vector["sourceType"] as? String)

        let result = HealthSampleEncoder.encodingFailureID(
            sourceRecordID: sourceID,
            typeIdentifier: sourceType
        )

        XCTAssertEqual(result.uuidString.lowercased(), vector["recordId"] as? String)
    }

    func testSeriesCompletionIdentityMatchesCrossPlatformFixture() throws {
        let vectors = try object(
            at: schemaRoot.appending(path: "fixtures/identity-vectors.json")
        )
        let vector = try XCTUnwrap(
            vectors["seriesCompletion"] as? [String: Any]
        )
        let sourceID = try XCTUnwrap(
            UUID(uuidString: try XCTUnwrap(vector["sourceRecordId"] as? String))
        )
        let sourceType = try XCTUnwrap(vector["sourceType"] as? String)
        let shape = SeriesShape(
            typeIdentifier: sourceType,
            headerKind: "workoutRoute",
            elementKind: "workoutRouteLocations",
            endKind: "workoutRouteEnd",
            elementsKey: "locations",
            elementsPerRecord: 500,
            recordsPerPage: 8
        )

        XCTAssertEqual(
            SeriesEncoding.completionCanonicalID(
                shape: shape,
                sample: sourceID
            ),
            vector["canonicalId"] as? String
        )
    }

    private func object(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
    }
}
