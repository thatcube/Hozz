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
        case paired(device: String)
        case pairingRefused(device: String)
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

    /// The port the receiver listens on by default.
    ///
    /// Defined in HozzCore because both halves need to agree on it.
    public static let defaultPort = HozzService.defaultPort

    /// The Bonjour service type both ends agree on.
    ///
    /// Defined in HozzCore because the phone browses for exactly what this
    /// advertises, and a duplicated literal would drift silently: the Mac would
    /// advertise and the phone would simply never find it.
    public static let serviceType = HozzService.bonjourType

    private let store: IngestStore
    private var token: String
    private let serviceName: String
    private var pairedDevices: [PairedDevice] = []
    private var hasRetriedOnAnyPort = false
    private var requestedPort = HealthReceiver.defaultPort
    private var serviceRestarts = 0
    private static let maximumServiceRestarts = 5
    private var shouldRun = false
    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []

    private(set) public var state: ReceiverState = .stopped
    private(set) public var events: [ReceiverEvent] = []

    private var stateObservers: [(ReceiverState) -> Void] = []
    private var eventObservers: [(ReceiverEvent) -> Void] = []

    public init(
        store: IngestStore,
        token: String,
        serviceName: String,
        pairedDevices: [PairedDevice] = []
    ) {
        self.store = store
        self.token = token
        self.serviceName = serviceName
        self.pairedDevices = pairedDevices
    }

    public var devices: [PairedDevice] {
        pairedDevices
    }

    /// Records that a device has been heard from.
    private func noteDeviceSeen(named rawName: String?) {
        let name = PairingPolicy.safeDeviceName(rawName ?? "An iPhone")
        guard !pairedDevices.contains(where: { $0.name == name }) else {
            return
        }
        pairedDevices.append(PairedDevice(name: name))
        record(ReceiverEvent(outcome: .paired(device: name)))
    }

    /// Replaces the token, which immediately invalidates every paired device.
    public func rotateToken(to newToken: String) {
        token = newToken
        pairedDevices.removeAll()
    }

    /// Handles a phone asking to be allowed to send to this computer.
    ///
    /// The first device is admitted without a prompt, because the receiver
    /// exposes no way to read Health data and demanding a ceremony from every
    /// user to protect against injection alone is a bad trade. Once something
    /// has paired, further requests are refused rather than silently granted.
    private func pair(with rawName: String?) -> PairingOutcome {
        let name = PairingPolicy.safeDeviceName(rawName)
        guard pairedDevices.isEmpty else {
            record(ReceiverEvent(outcome: .pairingRefused(device: name)))
            return .needsApproval
        }
        pairedDevices.append(PairedDevice(name: name))
        record(ReceiverEvent(outcome: .paired(device: name)))
        return .allowed(token: token)
    }

    public func onStateChange(_ observer: @escaping @Sendable (ReceiverState) -> Void) {
        stateObservers.append(observer)
        observer(state)
    }

    public func onEvent(_ observer: @escaping @Sendable (ReceiverEvent) -> Void) {
        eventObservers.append(observer)
    }

    public func start(port: UInt16 = HealthReceiver.defaultPort) async {
        guard listener == nil else {
            return
        }
        shouldRun = true
        requestedPort = port
        update(.starting)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Deliberately *not* peer-to-peer. Asking for it made the listener
        // advertise over the AirPlay/AWDL interface and loopback instead of the
        // actual Wi-Fi network, so the phone — sitting on the same Wi-Fi —
        // never saw the service and the socket was unreachable at the Mac's
        // real address. Hozz only ever needs the network both devices are
        // already on.
        parameters.includePeerToPeer = false
        // Accept IPv4 as well as IPv6. Left to itself the listener came up
        // IPv6-only, which silently refuses a phone connecting to a v4 address.
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            tcp.version = .any
        }

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
        shouldRun = false
        listener?.cancel()
        listener = nil
        update(.stopped)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            serviceRestarts = 0
            if let port = listener?.port?.rawValue {
                update(.listening(port: port))
                Self.log.info("Receiver listening on port \(port, privacy: .public).")
            }
        case .waiting(let error), .failed(let error):
            // The error seen on the affected Mac was -65563:
            // kDNSServiceErr_ServiceNotRunning. Rebuilding the listener is the
            // only recovery after mDNSResponder restarts; changing ports cannot
            // repair a dead service connection.
            if Self.isTransientServiceFailure(error),
               serviceRestarts < Self.maximumServiceRestarts {
                serviceRestarts += 1
                Self.log.info(
                    "Bonjour service unavailable; restarting receiver."
                )
                restart(after: .seconds(1), port: requestedPort)
                return
            }
            // Only EADDRINUSE means another process claimed the port.
            if Self.isPortInUse(error), !hasRetriedOnAnyPort {
                hasRetriedOnAnyPort = true
                Self.log.error(
                    "Port \(Self.defaultPort, privacy: .public) unavailable, using any free port."
                )
                restart(after: .zero, port: 0)
                return
            }
            update(.failed(error.localizedDescription))
        case .cancelled:
            update(.stopped)
        default:
            break
        }
    }

    static func isTransientServiceFailure(_ error: NWError) -> Bool {
        guard case .dns(let code) = error else {
            return false
        }
        return code == kDNSServiceErr_ServiceNotRunning
            || code == kDNSServiceErr_DefunctConnection
    }

    static func isPortInUse(_ error: NWError) -> Bool {
        if case .posix(let code) = error {
            return code == .EADDRINUSE
        }
        return false
    }

    private func restart(after delay: Duration, port: UInt16) {
        listener?.cancel()
        listener = nil
        Task { [weak self] in
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }
            await self?.resumeAfterRestart(port: port)
        }
    }

    private func resumeAfterRestart(port: UInt16) async {
        guard shouldRun else {
            return
        }
        await start(port: port)
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
            await self.serve(connection)
            connection.cancel()
            await self.forget(connection)
        }
    }

    private func forget(_ connection: NWConnection) {
        connections.remove(ObjectIdentifier(connection))
    }

    /// Serves one connection, deliberately *not* on the actor.
    ///
    /// Reading a request means waiting on the network, and waiting on the actor
    /// serialises every connection behind whichever arrived first. Browsers and
    /// URLSession both open speculative connections and then send nothing on
    /// them, so the first such connection held the actor for the full request
    /// timeout and every real request queued behind it — the socket accepted,
    /// then nothing, which looks exactly like the computer being unreachable.
    ///
    /// Only `respond` touches actor state, and only briefly.
    nonisolated private func serve(_ connection: NWConnection) async {
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
        // Pairing is the one route that is reachable without the token, because
        // handing the token over is its entire purpose.
        if request.method == "POST", request.path.hasPrefix("/pair") {
            let body = (try? JSONSerialization.jsonObject(with: request.body))
                as? [String: Any]
            switch pair(with: body?["device"] as? String) {
            case .allowed(let token):
                return HTTPResponse(
                    status: 200,
                    json: ["token": token, "name": serviceName]
                )
            case .needsApproval:
                return HTTPResponse(
                    status: 403,
                    json: [
                        "error": "already paired",
                        "detail": """
                            This Mac is already paired with another device. Open \
                            Hozz on the Mac and forget it first, or copy the \
                            token by hand.
                            """
                    ]
                )
            }
        }

        guard request.method == "POST" else {
            // A browser pointed at the port should get something human, so the
            // user can tell "wrong address" from "not running".
            if request.method == "GET" {
                // The name is included so a phone that found this computer by
                // sweeping the network — with no Bonjour and no shared record
                // to consult — can still show which computer it is.
                return HTTPResponse(
                    status: 200,
                    json: [
                        "service": "hozz-receiver",
                        "ready": true,
                        "name": serviceName
                    ]
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
        } catch BatchParseError.connectionTest {
            record(ReceiverEvent(outcome: .connectionTest))
            return HTTPResponse(status: 200, json: ["ok": true, "test": true])
        } catch {
            record(ReceiverEvent(outcome: .rejected("Unreadable payload")))
            return HTTPResponse(status: 400, json: ["error": "unreadable payload"])
        }

        // A phone that authenticated is connected, however it came by the
        // token. Counting only devices that went through /pair meant one that
        // already had the token — shared through the user's own iCloud
        // Keychain, which is the ordinary path — was delivering data while the
        // Mac still said it was waiting for a phone.
        let deviceName = PairingPolicy.safeDeviceName(
            request.header("x-hozz-device") ?? "An iPhone"
        )
        noteDeviceSeen(named: deviceName)

        do {
            let result = try await store.ingest(
                batch,
                idempotencyKey: request.header("idempotency-key")
            )
            try? await store.noteDelivery(
                from: deviceName,
                records: result.storedAnything
            )
            record(
                ReceiverEvent(
                    outcome: result.duplicate
                        ? .duplicate
                        // Everything this batch put on disk, not only the rows
                        // that are samples in their own right. During a series
                        // backfill a batch is often nothing but reading pages,
                        // and reporting that as "0 records" is as wrong as
                        // counting each page as a reading was.
                        : .stored(
                            records: result.storedAnything,
                            deleted: result.deleted
                        )
                )
            )
            return HTTPResponse(
                status: 200,
                json: [
                    "stored": result.stored,
                    "deleted": result.deleted,
                    "duplicate": result.duplicate,
                    // Reported so the phone's answer describes what actually
                    // happened. Characteristics and unhandled records are both
                    // genuinely on disk, so 200 is honest; `unreadable` counts
                    // lines that were not JSON and could not be stored at all.
                    "characteristics": result.characteristics,
                    "unhandled": result.unhandled,
                    "seriesPages": result.seriesPages,
                    "unreadable": result.unreadable
                ]
            )
        } catch let error as UnresolvedLegacyAliasError {
            record(ReceiverEvent(outcome: .rejected("Legacy record needs reconciliation")))
            return HTTPResponse(
                status: 409,
                json: [
                    "error": "legacy record needs reconciliation",
                    "detail": error.errorDescription ?? "Retry with the original record date."
                ]
            )
        } catch let error as IngestStorageError {
            // A full disk is not a server fault and not the phone's fault, and
            // it is the one failure a person can actually do something about.
            // 507 keeps the batch on the phone exactly as 500 would — anything
            // outside 2xx does — but it says which problem this is, and the
            // event says so in the receiver's own status.
            record(ReceiverEvent(outcome: .rejected("Not enough disk space")))
            return HTTPResponse(
                status: 507,
                json: [
                    "error": "not enough disk space",
                    "detail": error.errorDescription ?? "The disk is nearly full."
                ]
            )
        } catch {
            // Answering 500 keeps the batch on the phone, which will retry.
            record(ReceiverEvent(outcome: .rejected("Could not be stored")))
            return HTTPResponse(status: 500, json: ["error": "could not store batch"])
        }
    }
}
