import Foundation
@testable import HozzDeliver
import XCTest

/// What a POST says about itself before anything opens the body.
///
/// A receiver should be able to route a payload — this destination, this shape,
/// this device — without parsing it. Everything asserted here is configuration.
/// No header may carry a reading, a value, or a credential.
final class DeliveryHeaderTests: XCTestCase {
    private func channel() -> RESTDeliveryChannel {
        RESTDeliveryChannel(
            session: StubProtocol.session(),
            credentials: DestinationCredentials(service: "hozz.tests.headers"),
            deviceName: "Brandon\u{2019}s iPhone"
        )
    }

    private let payload = Data(
        #"{"id":"a","kind":"quantity","startDate":"2026-08-22T09:00:00.000Z"}"#
            .utf8
    )

    private func batch() -> DeliveryBatch {
        DeliveryBatch(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            sequence: 12,
            createdAt: .now,
            recordCount: 1,
            payload: payload,
            format: .metrics
        )
    }

    private func destination(name: String = "Home Assistant") -> Destination {
        Destination(
            name: name,
            kind: .restAPI,
            format: .metrics,
            endpointURL: URL(string: "https://example.com/health"),
            payloadSchema: .healthAutoExport,
            deliveryWindow: .sinceSevenDaysAgo
        )
    }

    private func send(_ destination: Destination) async throws -> URLRequest {
        StubProtocol.reset()
        _ = try await channel().deliver(batch(), to: destination)
        return try XCTUnwrap(StubProtocol.seen().requests.first)
    }

    // MARK: - What a receiver can route on

    func testEveryPostSaysWhichDestinationItIsFor() async throws {
        let destination = destination()
        let request = try await send(destination)

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Hozz-Destination-Id"),
            destination.id.uuidString.lowercased()
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Hozz-Destination-Name"),
            "Home Assistant"
        )
    }

    func testEveryPostSaysWhatShapeTheBodyIsIn() async throws {
        let request = try await send(destination())

        XCTAssertEqual(request.value(forHTTPHeaderField: "Hozz-Format"), "metrics")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Hozz-Schema"),
            "healthAutoExport"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
    }

    func testEveryPostSaysHowFarBackItWasAllowedToReach() async throws {
        let request = try await send(destination())

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Hozz-Window"),
            "sinceSevenDaysAgo",
            "A server ought to be able to tell a limited feed from a complete one."
        )
    }

    func testTheBatchHeadersAreStillThere() async throws {
        let request = try await send(destination())

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Hozz-Batch-Id"),
            "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Hozz-Batch-Sequence"), "12")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Idempotency-Key"),
            "11111111-2222-3333-4444-555555555555"
        )
    }

    // MARK: - Values that are not ASCII

    /// iOS names a phone with a typographic apostrophe by default, so this is
    /// the common case rather than an edge one. Sent raw it is bytes a server
    /// may refuse, and that most frameworks decode as Latin-1 into nonsense.
    func testANameThatIsNotASCIIIsEncodedRatherThanSentRaw() async throws {
        let request = try await send(destination(name: "Zuhause \u{1F3E0}"))

        let device = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Hozz-Device"))
        let name = try XCTUnwrap(
            request.value(forHTTPHeaderField: "Hozz-Destination-Name")
        )

        XCTAssertTrue(
            device.allSatisfy { $0.isASCII },
            "A header value has to be ASCII: \(device)"
        )
        XCTAssertTrue(name.allSatisfy { $0.isASCII }, name)

        // Decoded independently, against the UTF-8 bytes worked out here.
        XCTAssertEqual(device, "Brandon%E2%80%99s iPhone")
        XCTAssertEqual(device.removingPercentEncoding, "Brandon\u{2019}s iPhone")
        XCTAssertEqual(name.removingPercentEncoding, "Zuhause \u{1F3E0}")
    }

    /// A name that is already ASCII must come out untouched, or this would
    /// change what every existing receiver sees.
    func testAPlainNameIsNotEncodedAtAll() {
        XCTAssertEqual(RESTDeliveryChannel.headerSafe("Home Assistant"), "Home Assistant")
        XCTAssertEqual(RESTDeliveryChannel.headerSafe("my-server_01"), "my-server_01")
    }

    /// The percent sign is the escape, so a name containing one has to be
    /// escaped too or it decodes into something the user never typed.
    func testAPercentSignInANameSurvivesTheRoundTrip() throws {
        let encoded = try XCTUnwrap(RESTDeliveryChannel.headerSafe("100% backup"))

        XCTAssertEqual(encoded, "100%25 backup")
        XCTAssertEqual(encoded.removingPercentEncoding, "100% backup")
    }

    /// A newline in a header value is how a request gets a header nobody asked
    /// for. It must never reach the wire as a newline.
    func testAControlCharacterCannotSplitTheHeader() throws {
        let encoded = try XCTUnwrap(
            RESTDeliveryChannel.headerSafe("evil\r\nX-Injected: yes")
        )

        XCTAssertFalse(encoded.contains("\r"))
        XCTAssertFalse(encoded.contains("\n"))
        XCTAssertEqual(encoded, "evil%0D%0AX-Injected: yes")
    }

    /// A proxy with a header limit refuses the whole request, and losing a
    /// batch over a long label would be a poor trade.
    func testAVeryLongNameIsCutRatherThanRiskingTheRequest() throws {
        let encoded = try XCTUnwrap(
            RESTDeliveryChannel.headerSafe(String(repeating: "a", count: 5_000))
        )

        XCTAssertLessThanOrEqual(encoded.count, 210)
    }

    func testAnEmptyNameSendsNoHeaderAtAll() {
        XCTAssertNil(RESTDeliveryChannel.headerSafe(""))
        XCTAssertNil(RESTDeliveryChannel.headerSafe("   "))
    }

    // MARK: - What must never be in a header

    /// Logs and diagnostics carry statuses, never sample values. A header is
    /// both of those things at once — it is written down by every proxy on the
    /// way — so the rule is at its strictest here.
    func testNoHeaderCarriesACredentialOrAReading() async throws {
        var destination = destination()
        destination.authorizationHeader = "X-API-Key"
        let credentials = DestinationCredentials(service: "hozz.tests.headers.secret")
        try credentials.save("s3cret-token", for: destination.credentialKey)
        defer { try? credentials.delete(for: destination.credentialKey) }

        StubProtocol.reset()
        _ = try await RESTDeliveryChannel(
            session: StubProtocol.session(),
            credentials: credentials,
            deviceName: "Test"
        ).deliver(batch(), to: destination)

        let request = try XCTUnwrap(StubProtocol.seen().requests.first)
        let headers = request.allHTTPHeaderFields ?? [:]

        // The secret belongs in exactly one header, the one the user named.
        XCTAssertEqual(headers["X-API-Key"], "s3cret-token")
        for (name, value) in headers where name != "X-API-Key" {
            XCTAssertFalse(
                value.contains("s3cret"),
                "\(name) must not repeat the credential."
            )
        }
        for (name, value) in headers {
            XCTAssertFalse(
                value.contains("quantity") || value.contains("startDate"),
                "\(name) must not carry anything from the body."
            )
        }
    }
}
