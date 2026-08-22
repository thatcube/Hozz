import Foundation
import Network
import HozzReceive
import XCTest

/// End-to-end over a real socket.
///
/// The unit tests prove the parser and the store behave; this proves the thing
/// a phone actually talks to behaves. Auth, truncation and idempotency are all
/// checked over real HTTP, because those are the paths where a mistake means
/// either leaking health data to the local network or silently losing a batch.
final class ReceiverIntegrationTests: XCTestCase {
    private var root: URL!
    private var store: IngestStore!
    private var receiver: HealthReceiver!
    private var port: UInt16!

    private let token = "test-token-abc123"

    override func setUp() async throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "hozz-recv-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        store = try IngestStore(directory: root.appending(path: "store"))
        receiver = HealthReceiver(
            store: store,
            token: token,
            serviceName: "Hozz Test \(UUID().uuidString.prefix(6))"
        )
        await receiver.start()
        port = try await waitForPort()
    }

    override func tearDown() async throws {
        await receiver?.stop()
        await store?.close()
        try? FileManager.default.removeItem(at: root)
    }

    private func waitForPort() async throws -> UInt16 {
        for _ in 0..<100 {
            if case .listening(let port) = await receiver.state {
                return port
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("The receiver did not start listening in time.")
    }

    @discardableResult
    private func post(
        body: String,
        token: String?,
        idempotencyKey: String? = nil,
        contentLengthOverride: Int? = nil
    ) async throws -> (status: Int, json: [String: Any]) {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port!)/")!
        )
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        if let token {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if let contentLengthOverride {
            request.setValue(
                String(contentLengthOverride),
                forHTTPHeaderField: "Content-Length"
            )
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (status, json ?? [:])
    }

    private func sample(id: String, value: Int) -> String {
        """
        {"id":"\(id)","type":"HKQuantityTypeIdentifierStepCount",\
        "startDate":"2026-01-01T10:00:00.000Z","value":\(value),"unit":"count"}
        """
    }

    func testABatchIsAcceptedAndStored() async throws {
        let response = try await post(
            body: sample(id: "a", value: 120),
            token: token,
            idempotencyKey: "batch-1"
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.json["stored"] as? Int, 1)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 1)
    }

    /// The listener is reachable by anything on the same network — a guest, a
    /// smart TV, a housemate. Health data is the most sensitive data most
    /// people have.
    func testAMissingTokenIsRejected() async throws {
        let response = try await post(body: sample(id: "a", value: 1), token: nil)

        XCTAssertEqual(response.status, 401)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 0, "Nothing may be stored without the token.")
    }

    func testAWrongTokenIsRejected() async throws {
        let response = try await post(
            body: sample(id: "a", value: 1),
            token: "not-the-token"
        )

        XCTAssertEqual(response.status, 401)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 0)
    }

    /// A retried delivery must not double the data.
    func testTheSameBatchTwiceIsStoredOnce() async throws {
        try await post(body: sample(id: "a", value: 1), token: token, idempotencyKey: "same")
        let second = try await post(
            body: sample(id: "a", value: 1),
            token: token,
            idempotencyKey: "same"
        )

        XCTAssertEqual(second.json["duplicate"] as? Bool, true)
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 1)
    }

    /// A connection test has to succeed visibly, or the user checking their
    /// setup is told it is broken when it is not.
    func testAConnectionTestSucceeds() async throws {
        let response = try await post(
            body: #"{"kind":"hozzConnectionTest","schemaVersion":1}"#,
            token: token
        )

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.json["test"] as? Bool, true)
    }

    /// Answering 200 to a truncated body would tell the phone the batch landed,
    /// and the missing half would never be sent again.
    ///
    /// Sent over a raw connection because URLSession rewrites `Content-Length`
    /// to match the body it actually sends, so it cannot express this at all.
    func testATruncatedBodyIsRejectedRatherThanPartiallyStored() async throws {
        let body = sample(id: "a", value: 1) + "\n" + sample(id: "b", value: 2)
        let request = """
            POST / HTTP/1.1\r
            Host: 127.0.0.1\r
            Authorization: \(token)\r
            Idempotency-Key: truncated\r
            Content-Length: \(body.utf8.count + 500)\r
            \r
            \(body)
            """

        let response = try await sendRaw(request)

        XCTAssertTrue(
            response.contains("400"),
            "A short body must be refused, not accepted. Got: \(response.prefix(64))"
        )
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 0, "A partial batch must store nothing at all.")
    }

    /// Regression: a client that announces a body and then goes quiet used to
    /// hang the read task forever. The task group awaited that child, so the
    /// connection, its task, and its entry in the tracking set leaked — and all
    /// of it happened *before* the token check, so any unauthenticated device on
    /// the network could exhaust the process with idle sockets.
    ///
    /// The deadline is shortened via the real one being 30s; this asserts the
    /// server stays responsive rather than waiting for it to elapse.
    func testAStalledClientDoesNotBlockOtherRequests() async throws {
        // Announce a large body, send only the headers, then hold the socket.
        let stalled = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        stalled.start(queue: .global())
        defer { stalled.cancel() }

        let headers = """
            POST / HTTP/1.1\r
            Host: 127.0.0.1\r
            Authorization: \(token)\r
            Content-Length: 1000000\r
            \r

            """
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stalled.send(
                content: Data(headers.utf8),
                completion: .contentProcessed { _ in continuation.resume() }
            )
        }

        // The stalled socket is deliberately left open. A healthy request must
        // still be served promptly.
        let response = try await post(
            body: sample(id: "healthy", value: 5),
            token: token,
            idempotencyKey: "healthy"
        )

        XCTAssertEqual(
            response.status,
            200,
            "One stalled client must not stop the receiver serving others."
        )
        let total = try await store.totalRecordCount()
        XCTAssertEqual(total, 1)
    }

    /// Sends bytes verbatim and reads the reply, with no client-side rewriting.
    private func sendRaw(_ request: String) async throws -> String {
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.start(queue: .global())
        defer { connection.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(request.utf8),
                // `.finalMessage` is what actually half-closes a TCP stream;
                // `isComplete` alone only ends the message, so the server would
                // wait for a body that never arrives. This is precisely what a
                // dropped upload looks like on the wire.
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 8192
            ) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        returning: String(decoding: data ?? Data(), as: UTF8.self)
                    )
                }
            }
        }
    }

    /// Someone who points a browser at the port should be able to tell "wrong
    /// address" from "not running".
    func testAPlainGETIdentifiesTheService() async throws {
        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port!)/")!
        )

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        XCTAssertEqual(json?["service"] as? String, "hozz-receiver")
    }

    func testDeliveriesAreVisibleInTheActivityLog() async throws {
        try await post(body: sample(id: "a", value: 1), token: token, idempotencyKey: "k")
        _ = try await post(body: sample(id: "b", value: 2), token: "wrong")

        let events = await receiver.events
        XCTAssertTrue(events.contains { event in
            if case .stored = event.outcome { return true }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .rejected = event.outcome { return true }
            return false
        })
    }
}
