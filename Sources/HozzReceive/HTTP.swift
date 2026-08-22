import Foundation
import Network

/// One parsed HTTP request.
public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    /// Header lookup is case-insensitive because HTTP header names are.
    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public var contentLength: Int? {
        header("content-length").flatMap(Int.init)
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let contentType: String

    public init(status: Int, body: Data, contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    public init(status: Int, json: [String: Any]) {
        let encoded = (try? JSONSerialization.data(
            withJSONObject: json,
            options: [.sortedKeys]
        )) ?? Data("{}".utf8)
        self.init(status: status, body: encoded)
    }
}

public enum HTTPError: Error, Sendable {
    case closed
    case malformed
    case tooLarge
    case timedOut
}

/// Reads one HTTP request off a connection.
///
/// Written by hand rather than pulled from a package because this listens on
/// the user's home network with their health data behind it, and every
/// dependency here is something that could later ship a change nobody audited.
public enum HTTPRequestReader {
    /// Bodies are capped so a hostile or broken client cannot exhaust memory.
    /// Well above any batch Hozz sends, which is bounded by its own drain size.
    public static let maximumBodyBytes = 64 * 1024 * 1024

    /// How long one request may take to arrive in full.
    ///
    /// A client that announces a `Content-Length` and then stalls would
    /// otherwise hold a connection and its task open forever. On a home network
    /// that need not even be malicious — a phone that loses Wi-Fi mid-upload
    /// does exactly this.
    public static let requestTimeout: Duration = .seconds(30)

    public static func read(from connection: NWConnection) async throws -> HTTPRequest {
        try await withThrowingTaskGroup(of: HTTPRequest?.self) { group in
            group.addTask {
                try await readRequest(from: connection)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: requestTimeout)
                } catch {
                    // Cancelled because the request already arrived. Returning
                    // here is essential: swallowing this and falling through
                    // would cancel the connection out from under a response
                    // that is about to be written.
                    return nil
                }
                // Cancelling the *connection*, not just the task, is what makes
                // this a real deadline. A pending `receive` only calls back on
                // bytes, an error, or cancellation, and a checked continuation
                // has no cancellation handling — so cancelling the task alone
                // would leave the reader suspended forever while the task group
                // waited for it, which is precisely a slowloris.
                connection.cancel()
                return nil
            }

            while let result = try await group.next() {
                if let request = result {
                    group.cancelAll()
                    return request
                }
                // The deadline passed. The reader is now unblocked by the
                // cancellation above and will finish on the next iteration.
            }
            throw HTTPError.timedOut
        }
    }

    private static func readRequest(
        from connection: NWConnection
    ) async throws -> HTTPRequest {
        var buffer = Data()

        // Headers first, up to the blank line that ends them.
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            guard let chunk = try await receive(on: connection) else {
                throw HTTPError.closed
            }
            buffer.append(chunk)
            headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8))
            if headerEnd == nil, buffer.count > 128 * 1024 {
                // No sane request has headers this large.
                throw HTTPError.malformed
            }
        }

        guard let headerEnd else {
            throw HTTPError.malformed
        }
        let headerText = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else {
            throw HTTPError.malformed
        }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            throw HTTPError.malformed
        }
        let method = String(requestLine[0]).uppercased()
        let path = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        var body = Data(buffer[headerEnd.upperBound...])
        if let declared = headers["content-length"].flatMap(Int.init) {
            guard declared <= maximumBodyBytes else {
                throw HTTPError.tooLarge
            }
            // Read until the declared length arrives or the peer goes away. A
            // short read is reported to the caller rather than papered over,
            // because a truncated batch stored as complete is data loss.
            while body.count < declared {
                guard let chunk = try await receive(on: connection) else {
                    break
                }
                body.append(chunk)
            }
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private static func receive(on connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 1 << 16
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    // No bytes and no error means the peer is done. Returning
                    // an empty chunk instead would let both read loops spin
                    // forever appending nothing, holding a core at 100% for a
                    // client that simply went away.
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

public enum HTTPResponder {
    public static func send(
        _ response: HTTPResponse,
        on connection: NWConnection
    ) async throws {
        var head = "HTTP/1.1 \(response.status) \(reason(for: response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(response.body)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: payload,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 405: "Method Not Allowed"
        case 500: "Internal Server Error"
        default: "Unknown"
        }
    }
}
