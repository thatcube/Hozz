import Foundation
import HozzCore
import HozzMCP
import HozzReceive
import XCTest

/// Covers the MCP surface an assistant actually drives.
///
/// The failure mode that matters most here is not a crash — it is a confidently
/// wrong answer. An assistant told "empty" when it asked for a mistyped type
/// will report zero steps rather than "that type does not exist", so those
/// paths are pinned explicitly.
final class MCPTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() throws -> IngestStore {
        try IngestStore(directory: root.appending(path: "store"))
    }

    private func seed(_ store: IngestStore) async throws {
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"id":"a","type":"HKQuantityTypeIdentifierStepCount","startDate":"2026-01-01T09:00:00.000Z","value":100,"unit":"count"}
                    {"id":"b","type":"HKQuantityTypeIdentifierStepCount","startDate":"2026-01-01T18:00:00.000Z","value":300,"unit":"count"}
                    {"id":"c","type":"HKQuantityTypeIdentifierStepCount","startDate":"2026-01-02T09:00:00.000Z","value":50,"unit":"count"}
                    """.utf8
                )
            ),
            idempotencyKey: "seed"
        )
    }

    private func send(
        _ server: MCPServer,
        _ message: [String: Any]
    ) async throws -> [String: Any]? {
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let reply = await server.handle(data) else {
            return nil
        }
        return try JSONSerialization.jsonObject(with: reply) as? [String: Any]
    }

    private func text(_ response: [String: Any]?) throws -> String {
        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    func testInitializeAdvertisesToolSupport() async throws {
        let server = MCPServer(store: try makeStore())

        let response = try await send(server, [
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]
        ])

        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, MCPServer.protocolVersion)
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["tools"])
    }

    /// A notification has no id. Replying to one is a protocol violation that
    /// some clients treat as fatal.
    func testNotificationsAreNotAnswered() async throws {
        let server = MCPServer(store: try makeStore())

        let reply = try await send(server, [
            "jsonrpc": "2.0", "method": "notifications/initialized"
        ])

        XCTAssertNil(reply)
    }

    func testToolsAreListedWithSchemas() async throws {
        let server = MCPServer(store: try makeStore())

        let response = try await send(server, [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list"
        ])

        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("list_health_types"))
        XCTAssertTrue(names.contains("aggregate_health_data"))
        for tool in tools {
            XCTAssertNotNil(tool["inputSchema"], "Every tool needs a schema.")
            XCTAssertNotNil(tool["description"], "Every tool needs a description.")
        }
    }

    func testAggregationAnswersATrendQuestion() async throws {
        let store = try makeStore()
        try await seed(store)
        let server = MCPServer(store: store)

        let response = try await send(server, [
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": [
                "name": "aggregate_health_data",
                "arguments": ["type": "HKQuantityTypeIdentifierStepCount", "bucket": "day"]
            ]
        ])

        let body = try text(response)
        XCTAssertTrue(body.contains("400"), "Day one sums to 400.")
        XCTAssertTrue(body.contains("200"), "Day one averages 200.")
        XCTAssertTrue(
            body.lowercased().contains("sum") && body.lowercased().contains("average"),
            "Both must be present, because which is correct depends on the type."
        )
    }

    /// The single most dangerous outcome: an assistant asked about a mistyped
    /// type gets "empty" and reports a confident zero.
    func testAnUnknownTypeIsNotReportedAsZero() async throws {
        let store = try makeStore()
        try await seed(store)
        let server = MCPServer(store: store)

        let response = try await send(server, [
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": [
                "name": "aggregate_health_data",
                "arguments": ["type": "StepCount"]
            ]
        ])

        let body = try text(response)
        XCTAssertTrue(
            body.contains("no type called"),
            "A wrong type name must be named as such, not answered with silence."
        )
        XCTAssertTrue(
            body.contains("HKQuantityTypeIdentifierStepCount"),
            "The real type names should be offered so the caller can correct itself."
        )
    }

    func testAnEmptyStoreSaysSoRatherThanReturningNothing() async throws {
        let server = MCPServer(store: try makeStore())

        let response = try await send(server, [
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": ["name": "list_health_types", "arguments": [:]]
        ])

        let body = try text(response)
        XCTAssertTrue(body.contains("No Health data"))
    }

    func testAMissingRequiredArgumentIsReportedAsToolError() async throws {
        let server = MCPServer(store: try makeStore())

        let response = try await send(server, [
            "jsonrpc": "2.0", "id": 6, "method": "tools/call",
            "params": ["name": "aggregate_health_data", "arguments": [:]]
        ])

        let result = try XCTUnwrap(response?["result"] as? [String: Any])
        XCTAssertEqual(
            result["isError"] as? Bool,
            true,
            "A tool problem is reported as tool output, not a transport error."
        )
    }

    func testAnUnknownMethodIsAProtocolError() async throws {
        let server = MCPServer(store: try makeStore())

        let response = try await send(server, [
            "jsonrpc": "2.0", "id": 7, "method": "does/not/exist"
        ])

        let error = try XCTUnwrap(response?["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    func testMalformedJSONIsAParseError() async {
        let server = MCPServer(store: try! makeStore())

        let reply = await server.handle(Data("{not json".utf8))

        let object = try? JSONSerialization.jsonObject(with: reply ?? Data()) as? [String: Any]
        let error = (object as? [String: Any])?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32700)
    }

    func testSampleListingIsCappedAndSaysSo() async throws {
        let store = try makeStore()
        try await seed(store)
        let server = MCPServer(store: store)

        let response = try await send(server, [
            "jsonrpc": "2.0", "id": 8, "method": "tools/call",
            "params": [
                "name": "list_health_samples",
                "arguments": ["type": "HKQuantityTypeIdentifierStepCount", "limit": 2]
            ]
        ])

        let body = try text(response)
        XCTAssertTrue(
            body.contains("Truncated"),
            "A truncated list must say so, or the caller treats it as complete."
        )
    }

    // MARK: - Characteristics

    private func seedCharacteristics(_ store: IngestStore) async throws {
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(
                    """
                    {"kind":"characteristics","schemaVersion":1,"readAt":"2026-01-02T15:00:00.000Z","characteristics":{"HKCharacteristicTypeIdentifierDateOfBirth":{"state":"known","value":"1985-03-04"},"HKCharacteristicTypeIdentifierBiologicalSex":{"state":"known","value":"Male","rawValue":2},"HKCharacteristicTypeIdentifierBloodType":{"state":"notSet"}}}
                    """.utf8
                )
            ),
            idempotencyKey: "characteristics"
        )
    }

    /// An assistant asked "is this normal for me" cannot answer without
    /// knowing who "me" is, so the context arrives with the overview rather
    /// than behind a second call it might never make.
    func testTheOverviewCarriesThePersonsOwnCharacteristics() async throws {
        let store = try makeStore()
        try await seed(store)
        try await seedCharacteristics(store)
        let server = MCPServer(store: store)

        let body = try text(
            try await send(server, [
                "jsonrpc": "2.0", "id": 20, "method": "tools/call",
                "params": ["name": "summarise_health_data", "arguments": [:] as [String: Any]]
            ])
        )

        XCTAssertTrue(body.contains("About the person"), body)
        XCTAssertTrue(body.contains("Biological Sex: Male"), body)
        XCTAssertTrue(
            body.contains("age "),
            "Reference ranges are keyed to age, so it is derived here rather than left to the caller: \(body)"
        )
        XCTAssertTrue(
            body.contains("Blood Type: not set by the person"),
            "'Not set' is a fact about the person, not a blank: \(body)"
        )
        // The measurements still come through.
        XCTAssertTrue(body.contains("HKQuantityTypeIdentifierStepCount"), body)
    }

    func testTheOverviewSaysWhenRecordsCouldNotBeUnderstood() async throws {
        let store = try makeStore()
        try await seed(store)
        _ = try await store.ingest(
            try BatchParser.parse(
                Data(#"{"kind":"electrocardiogram","averageHeartRate":62}"#.utf8)
            ),
            idempotencyKey: "future"
        )
        let server = MCPServer(store: store)

        let body = try text(
            try await send(server, [
                "jsonrpc": "2.0", "id": 21, "method": "tools/call",
                "params": ["name": "summarise_health_data", "arguments": [:] as [String: Any]]
            ])
        )

        XCTAssertTrue(
            body.contains("cannot read yet"),
            "A partial picture must not be described as a complete one: \(body)"
        )
        XCTAssertTrue(body.contains("electrocardiogram"), body)
    }

    /// A store holding only characteristics is not an empty store.
    func testAStoreWithOnlyCharacteristicsIsNotReportedAsEmpty() async throws {
        let store = try makeStore()
        try await seedCharacteristics(store)
        let server = MCPServer(store: store)

        let body = try text(
            try await send(server, [
                "jsonrpc": "2.0", "id": 22, "method": "tools/call",
                "params": ["name": "summarise_health_data", "arguments": [:] as [String: Any]]
            ])
        )

        XCTAssertTrue(body.contains("About the person"), body)
        XCTAssertFalse(
            body.hasPrefix("No Health data has been received yet."),
            "Characteristics had arrived, so this is not 'nothing received': \(body)"
        )
    }

    func testAgeIsWholeYearsAndRespectsAnUnreachedBirthday() {
        let reference = Timestamps.date(from: "2026-03-03T12:00:00.000Z")!
        XCTAssertEqual(
            MCPServer.age(fromDateOfBirth: "1985-03-04", now: reference),
            40,
            "The birthday has not happened yet this year."
        )
        let afterBirthday = Timestamps.date(from: "2026-03-05T12:00:00.000Z")!
        XCTAssertEqual(
            MCPServer.age(fromDateOfBirth: "1985-03-04", now: afterBirthday),
            41
        )
        XCTAssertNil(MCPServer.age(fromDateOfBirth: "not a date"))
    }
}
