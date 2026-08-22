import Foundation
import HozzCore
import Network
import os

/// What the receiver did with one delivery, for the UI and the log.
public struct ReceiverEvent: Identifiable, Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case stored(records: Int, deleted: Int)
        case duplicate
        case connectionTest
        case rejected(String)
    }

    public let id = UUID()
    public let at: Date
    public let outcome: Outcome

    public init(at: Date = .now, outcome: Outcome) {
        self.at = at
        self.outcome = outcome
    }
}

public enum ReceiverState: Hashable, Sendable {
    case stopped
    case starting
    case listening(port: UInt16)
    case failed(String)
}

/// Receives Health batches from a phone on the local network.
///
/// Two decisions here matter more than the code:
///
/// **It advertises over Bonjour.** Typing an IP address is the step where
/// most people give up, and a home IP changes without warning, so a setup that
/// worked yesterday silently stops. Advertising means the phone can offer the
/// computer by name and the address is never typed or stored.
///
/// **It requires a token.** The listener is reachable by anything on the same
/// network — a guest, a smart TV, a housemate. Health data is the most
/// sensitive data most people have, so an unauthenticated listener is not
/// offered even as an option.
public actor HealthReceiver {
    private static let log = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "receiver"
    )

    /// The Bonjour service type both ends agree on.
    ///
    /// Defined in HozzCore because the phone browses for exactly what this
    /// advertises, and a duplicated literal would drift silently: the Mac would
    /// advertise and the phone would simply never find it.
    public static let serviceType = HozzService.bonjourType

    private let store: IngestStore
    private let token: String
    private let serviceName: String
    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []

    private(set) public var state: ReceiverState = .stopped
    private(set) public var events: [ReceiverEvent] = []

    private var stateObservers: [(ReceiverState) -> Void] = []
    private var eventObservers: [(ReceiverEvent) -> Void] = []

    public init(store: IngestStore, token: String, serviceName: String) {
        self.store = store
        self.token = token
        self.serviceName = serviceName
    }

    public func onStateChange(_ observer: @escaping @Sendable (ReceiverState) -> Void) {
        stateObservers.append(observer)
        observer(state)
    }

    public func onEvent(_ observer: @escaping @Sendable (ReceiverEvent) -> Void) {
        eventObservers.append(observer)
    }

    public func start(port: UInt16 = 0) async {
        guard listener == nil else {
            return
        }
        update(.starting)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Health data never leaves the local network by accident: the listener
        // is not exposed beyond the link it is bound to.
        parameters.includePeerToPeer = true

        do {
            let listener: NWListener
            if port == 0 {
                listener = try NWListener(using: parameters)
            } else {
                guard let resolved = NWEndpoint.Port(rawValue: port) else {
                    update(.failed("That port number is not valid."))
                    return
                }
                listener = try NWListener(using: parameters, on: resolved)
            }

            // Advertising by name is what removes the IP address from setup.
            listener.service = NWListener.Service(
                name: serviceName,
                type: Self.serviceType
            )

            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleListenerState(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.accept(connection) }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            update(.failed(error.localizedDescription))
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        update(.stopped)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue {
                update(.listening(port: port))
                Self.log.info("Receiver listening on port \(port, privacy: .public).")
            }
        case .failed(let error):
            update(.failed(error.localizedDescription))
        case .cancelled:
            update(.stopped)
        default:
            break
        }
    }

    private func update(_ newState: ReceiverState) {
        state = newState
        for observer in stateObservers {
            observer(newState)
        }
    }

    private func record(_ event: ReceiverEvent) {
        events.insert(event, at: 0)
        // The log is for reassurance, not forensics, and it must never become a
        // second copy of the user's health history.
        if events.count > 200 {
            events.removeLast(events.count - 200)
        }
        for observer in eventObservers {
            observer(event)
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.insert(ObjectIdentifier(connection))
        connection.start(queue: .global(qos: .userInitiated))
        Task {
            await self.handle(connection)
            connection.cancel()
            await self.forget(connection)
        }
    }

    private func forget(_ connection: NWConnection) {
        connections.remove(ObjectIdentifier(connection))
    }

    private func handle(_ connection: NWConnection) async {
        do {
            let request = try await HTTPRequestReader.read(from: connection)
            let response = await respond(to: request)
            try await HTTPResponder.send(response, on: connection)
        } catch {
            // A dropped connection is normal — a phone moving between networks
            // does it constantly — and is not worth surfacing to the user.
            Self.log.debug("A delivery connection ended early.")
        }
    }

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard request.method == "POST" else {
            // A browser pointed at the port should get something human, so the
            // user can tell "wrong address" from "not running".
            if request.method == "GET" {
                return HTTPResponse(
                    status: 200,
                    json: ["service": "hozz-receiver", "ready": true]
                )
            }
            return HTTPResponse(status: 405, json: ["error": "method not allowed"])
        }

        guard request.header("authorization") == token else {
            record(ReceiverEvent(outcome: .rejected("Wrong or missing token")))
            return HTTPResponse(status: 401, json: ["error": "unauthorized"])
        }

        // A connection dropped mid-post yields a short body. Storing part of it
        // and answering 200 would tell the phone the batch was delivered, and
        // the rest would never be sent again.
        if let declared = request.contentLength, declared != request.body.count {
            record(ReceiverEvent(outcome: .rejected("Incomplete delivery")))
            return HTTPResponse(status: 400, json: ["error": "incomplete body"])
        }

        let batch: ParsedBatch
        do {
            batch = try BatchParser.parse(request.body)
        } catch is BatchParseError {
            record(ReceiverEvent(outcome: .connectionTest))
            return HTTPResponse(status: 200, json: ["ok": true, "test": true])
        } catch {
            record(ReceiverEvent(outcome: .rejected("Unreadable payload")))
            return HTTPResponse(status: 400, json: ["error": "unreadable payload"])
        }

        do {
            let result = try await store.ingest(
                batch,
                idempotencyKey: request.header("idempotency-key")
            )
            record(
                ReceiverEvent(
                    outcome: result.duplicate
                        ? .duplicate
                        : .stored(records: result.stored, deleted: result.deleted)
                )
            )
            return HTTPResponse(
                status: 200,
                json: [
                    "stored": result.stored,
                    "deleted": result.deleted,
                    "duplicate": result.duplicate
                ]
            )
        } catch {
            // Answering 500 keeps the batch on the phone, which will retry.
            record(ReceiverEvent(outcome: .rejected("Could not be stored")))
            return HTTPResponse(status: 500, json: ["error": "could not store batch"])
        }
    }
}
