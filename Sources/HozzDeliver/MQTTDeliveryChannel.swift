import Foundation
import Network

/// Publishes batches to an MQTT broker.
///
/// This speaks just enough of MQTT 3.1.1 to connect, publish, and disconnect —
/// CONNECT, PUBLISH at QoS 0, DISCONNECT. A full client would bring a
/// dependency and a background-connection lifecycle for no benefit, because
/// Hozz publishes in short bursts when iOS wakes it rather than holding a
/// session open.
///
/// The honest limitation, surfaced in the UI: QoS 0 and a broker that keeps no
/// history mean a broker which is down misses that batch. Hozz will not advance
/// its cursor for a failed publish, so the data is resent, but MQTT is a weaker
/// guarantee than a folder or an endpoint that acknowledges.
public struct MQTTDeliveryChannel: DeliveryChannel {
    private let credentials: DestinationCredentials
    private let timeout: TimeInterval

    public init(
        credentials: DestinationCredentials = DestinationCredentials(),
        timeout: TimeInterval = 20
    ) {
        self.credentials = credentials
        self.timeout = timeout
    }

    public func deliver(
        _ batch: DeliveryBatch,
        to destination: Destination
    ) async throws -> DeliveryReceipt {
        guard
            let url = destination.endpointURL,
            let host = url.host
        else {
            throw DeliveryError.notConfigured
        }
        let port = UInt16(url.port ?? 1_883)
        let useTLS = url.scheme == "mqtts"

        let password: String?
        do {
            password = try credentials.secret(for: destination.credentialKey)
        } catch {
            throw DeliveryError.transport(
                "Hozz could not read this destination's saved credential yet."
            )
        }

        let topics = Self.topics(for: batch, destination: destination)
        let packets = try Self.packets(
            topics: topics,
            username: destination.headers["username"],
            password: password,
            clientID: "hozz-\(destination.id.uuidString.prefix(8).lowercased())"
        )

        try await send(packets, host: host, port: port, useTLS: useTLS)

        return DeliveryReceipt(
            destinationID: destination.id,
            attemptedAt: .now,
            recordCount: batch.recordCount,
            byteCount: UInt64(batch.payload.count),
            state: .delivered,
            detail: "Published \(topics.count) topics"
        )
    }

    // MARK: - Topics

    /// One retained topic per metric, plus the whole batch.
    ///
    /// Per-metric topics are what makes this useful in Home Assistant: a
    /// sensor can subscribe to `hozz/step_count` rather than parsing a batch.
    public static func topics(
        for batch: DeliveryBatch,
        destination: Destination
    ) -> [(topic: String, payload: Data)] {
        let root = destination.headers["topic"] ?? "hozz"
        var topics: [(String, Data)] = [(("\(root)/batch"), batch.payload)]

        guard
            let object = try? JSONSerialization.jsonObject(with: batch.payload)
                as? [String: Any],
            let data = object["data"] as? [String: Any],
            let metrics = data["metrics"] as? [[String: Any]]
        else {
            return topics
        }

        for metric in metrics {
            guard
                let name = metric["name"] as? String,
                let points = metric["data"] as? [[String: Any]],
                let latest = points.last,
                let encoded = try? JSONSerialization.data(
                    withJSONObject: latest,
                    options: [.sortedKeys]
                )
            else {
                continue
            }
            topics.append(("\(root)/\(name)", encoded))
        }
        return topics
    }

    // MARK: - Wire format

    public static func packets(
        topics: [(topic: String, payload: Data)],
        username: String?,
        password: String?,
        clientID: String
    ) throws -> Data {
        var out = Data()
        out.append(connectPacket(clientID: clientID, username: username, password: password))
        for entry in topics {
            out.append(publishPacket(topic: entry.topic, payload: entry.payload))
        }
        // DISCONNECT
        out.append(contentsOf: [0xE0, 0x00])
        return out
    }

    public static func connectPacket(
        clientID: String,
        username: String?,
        password: String?
    ) -> Data {
        var variable = Data()
        variable.append(string: "MQTT")
        variable.append(0x04)   // protocol level 4 = MQTT 3.1.1

        var flags: UInt8 = 0x02 // clean session
        if username != nil { flags |= 0x80 }
        if password != nil { flags |= 0x40 }
        variable.append(flags)
        variable.append(contentsOf: [0x00, 0x3C])   // 60 second keep-alive

        var payload = Data()
        payload.append(string: clientID)
        if let username {
            payload.append(string: username)
        }
        if let password {
            payload.append(string: password)
        }

        var packet = Data([0x10])
        packet.append(remainingLength: variable.count + payload.count)
        packet.append(variable)
        packet.append(payload)
        return packet
    }

    public static func publishPacket(topic: String, payload: Data) -> Data {
        var variable = Data()
        variable.append(string: topic)

        // QoS 0 with the retain flag set, so a subscriber that connects later
        // still sees the most recent value rather than nothing at all.
        var packet = Data([0x31])
        packet.append(remainingLength: variable.count + payload.count)
        packet.append(variable)
        packet.append(payload)
        return packet
    }

    // MARK: - Transport

    private func send(
        _ data: Data,
        host: String,
        port: UInt16,
        useTLS: Bool
    ) async throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 1_883
        )
        let parameters: NWParameters = useTLS ? .tls : .tcp
        let connection = NWConnection(to: endpoint, using: parameters)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Self.connectAndSend(connection, data: data)
            }
            group.addTask { [timeout] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw DeliveryError.transport("The broker did not respond in time.")
            }
            defer {
                group.cancelAll()
                connection.cancel()
            }
            try await group.next()
        }
    }

    private static func connectAndSend(
        _ connection: NWConnection,
        data: Data
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let resume = ResumeOnce(continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: data,
                        completion: .contentProcessed { error in
                            if let error {
                                resume.fail(
                                    DeliveryError.transport(error.localizedDescription)
                                )
                            } else {
                                resume.succeed()
                            }
                        }
                    )
                case .failed(let error):
                    resume.fail(DeliveryError.transport(error.localizedDescription))
                case .cancelled:
                    resume.fail(DeliveryError.cancelled)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
    }
}

/// Guarantees a continuation is resumed exactly once.
///
/// `NWConnection` can report failure after a send has already completed, and
/// resuming a continuation twice is undefined behaviour rather than a caught
/// error.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func succeed() {
        take()?.resume()
    }

    func fail(_ error: any Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Void, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        let held = continuation
        continuation = nil
        return held
    }
}

private extension Data {
    /// MQTT strings are a two-byte big-endian length followed by UTF-8.
    mutating func append(string: String) {
        let bytes = Array(string.utf8)
        append(UInt8(bytes.count >> 8))
        append(UInt8(bytes.count & 0xFF))
        append(contentsOf: bytes)
    }

    /// MQTT encodes lengths seven bits at a time, high bit as continuation.
    mutating func append(remainingLength: Int) {
        var value = remainingLength
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 {
                byte |= 0x80
            }
            append(byte)
        } while value > 0
    }
}
