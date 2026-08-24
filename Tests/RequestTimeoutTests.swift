import Foundation
@testable import HozzDeliver
import XCTest

/// A stub that answers HTTP without a network, and remembers what it was asked.
///
/// Registered per session rather than globally so tests can run in parallel
/// without one handler answering another's request.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    /// What every request should be answered with, and what was seen.
    struct Exchange: @unchecked Sendable {
        var statusCode: Int = 200
        var requests: [URLRequest] = []
        var bodies: [Data] = []
        /// Status codes to answer with in order; the last repeats.
        var statusSequence: [Int] = []
    }

    nonisolated(unsafe) private static var exchange = Exchange()
    private static let lock = NSLock()

    static func reset(statusCode: Int = 200, sequence: [Int] = []) {
        lock.lock()
        defer { lock.unlock() }
        exchange = Exchange(statusCode: statusCode, statusSequence: sequence)
    }

    static func seen() -> (requests: [URLRequest], bodies: [Data]) {
        lock.lock()
        defer { lock.unlock() }
        return (exchange.requests, exchange.bodies)
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(StubProtocol.read) ?? Data()
        let status: Int = StubProtocol.lock.withLock {
            StubProtocol.exchange.requests.append(request)
            StubProtocol.exchange.bodies.append(body)
            let index = StubProtocol.exchange.requests.count - 1
            let sequence = StubProtocol.exchange.statusSequence
            guard !sequence.isEmpty else {
                return StubProtocol.exchange.statusCode
            }
            return sequence[min(index, sequence.count - 1)]
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4_096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            guard read > 0 else {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// The per-destination timeout, and what falls back to what.
final class RequestTimeoutTests: XCTestCase {
    private func destination(timeout: String?) -> Destination {
        Destination(
            name: "Home server",
            kind: .restAPI,
            endpointURL: URL(string: "https://example.com/health"),
            options: timeout.map { [Destination.timeoutKey: $0] } ?? [:]
        )
    }

    // MARK: - Reading the stored value

    func testAStoredTimeoutIsUsedExactly() {
        XCTAssertEqual(destination(timeout: "300").requestTimeout, 300)
        XCTAssertEqual(destination(timeout: "1800").requestTimeout, 1_800)
        XCTAssertEqual(destination(timeout: "10").requestTimeout, 10)
    }

    /// A destination saved before this setting existed has to behave exactly as
    /// it did on the previous build.
    func testADestinationWithNoTimeoutGetsTheOldBehaviour() {
        XCTAssertEqual(destination(timeout: nil).requestTimeout, 60)
        XCTAssertEqual(
            RequestTimeout.default,
            60,
            "URLSession's own default. Changing it would change every existing "
                + "destination silently."
        )
    }

    /// Unlike a format or a precision, a timeout cannot change the *meaning* of
    /// what is delivered. Parking the destination over an unreadable one would
    /// cost the user their data to protect them from nothing.
    func testAnUnreadableTimeoutFallsBackRatherThanParkingTheDestination() {
        for value in ["", "soon", "-5", "0", "99999", "60.0.0"] {
            let destination = destination(timeout: value)
            XCTAssertEqual(
                destination.requestTimeout,
                60,
                "\(value) should fall back."
            )
            XCTAssertTrue(
                destination.isUsable,
                "\(value) must not take the destination out of service."
            )
        }
    }

    /// A number outside the offered list but inside the accepted range is
    /// honoured, so a value written by a newer build is not thrown away.
    func testAValueOutsideTheOfferedListIsStillHonoured() {
        XCTAssertEqual(destination(timeout: "45").requestTimeout, 45)
        XCTAssertEqual(destination(timeout: "3600").requestTimeout, 3_600)
    }

    func testEveryOfferedChoiceIsAcceptedBack() {
        for seconds in RequestTimeout.choices {
            XCTAssertEqual(
                destination(timeout: String(Int(seconds))).requestTimeout,
                seconds
            )
        }
    }

    // MARK: - Names, checked against the seconds independently

    func testTheNamesSayWhatTheSecondsMean() {
        XCTAssertEqual(RequestTimeout.displayName(for: 10), "10 seconds")
        XCTAssertEqual(RequestTimeout.displayName(for: 30), "30 seconds")
        XCTAssertEqual(RequestTimeout.displayName(for: 60), "1 minute")
        XCTAssertEqual(RequestTimeout.displayName(for: 300), "5 minutes")
        XCTAssertEqual(RequestTimeout.displayName(for: 1_800), "30 minutes")
        XCTAssertEqual(RequestTimeout.displayName(for: 3_600), "1 hour")
    }

    // MARK: - It reaches the request

    func testTheRequestCarriesTheDestinationsTimeout() async throws {
        StubProtocol.reset()
        let channel = RESTDeliveryChannel(
            session: StubProtocol.session(),
            credentials: DestinationCredentials(service: "hozz.tests.timeout"),
            deviceName: "Test"
        )
        let batch = DeliveryBatch(
            id: UUID(),
            sequence: 0,
            createdAt: .now,
            recordCount: 1,
            payload: Data("{\"id\":\"a\"}\n".utf8),
            format: .ndjson
        )

        _ = try await channel.deliver(batch, to: destination(timeout: "1800"))

        let seen = StubProtocol.seen()
        XCTAssertEqual(seen.requests.count, 1)
        XCTAssertEqual(seen.requests[0].timeoutInterval, 1_800)
    }

    func testADestinationWithNoTimeoutStillSendsTheDefault() async throws {
        StubProtocol.reset()
        let channel = RESTDeliveryChannel(
            session: StubProtocol.session(),
            credentials: DestinationCredentials(service: "hozz.tests.timeout"),
            deviceName: "Test"
        )
        let batch = DeliveryBatch(
            id: UUID(),
            sequence: 0,
            createdAt: .now,
            recordCount: 1,
            payload: Data("{\"id\":\"a\"}\n".utf8),
            format: .ndjson
        )

        _ = try await channel.deliver(batch, to: destination(timeout: nil))

        XCTAssertEqual(StubProtocol.seen().requests[0].timeoutInterval, 60)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
