import Foundation
import HozzDeliver
import HozzMCP
import HozzReceive
import HozzStore
import Observation
import os

/// Everything the Mac app needs, wired once.
///
/// The default path is deliberately zero-configuration: on first launch a token
/// is generated, the receiver starts, and the computer advertises itself on the
/// local network. The user never types an IP address, because that is the step
/// where setup usually fails — and a home IP changes without warning, so a
/// hand-typed one silently stops working days later.
@MainActor
@Observable
final class MacServices {
    nonisolated private static let log = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "mac"
    )

    enum Status: Equatable {
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    private(set) var status: Status = .starting
    private(set) var summaries: [TypeSummary] = []
    private(set) var totalRecords = 0
    private(set) var events: [ReceiverEvent] = []
    private(set) var devices: [PairedDevice] = []
    private(set) var lastReceivedAt: Date?

    private(set) var token = ""
    private(set) var computerName = ""

    private var store: IngestStore?
    private var receiver: HealthReceiver?

    /// Where the received database actually lives.
    ///
    /// Surfaced because the MCP tool runs outside this app's sandbox and cannot
    /// derive it: the container path has to be handed over explicitly.
    private(set) var dataDirectory = URL(fileURLWithPath: "/")

    /// The address to give the phone, once the receiver is listening.
    ///
    /// The numeric address, not the `.local` name. Showing a name that the
    /// phone may be unable to resolve produces a setup that looks correct and
    /// silently never connects — and it is the address that gets published, so
    /// showing something different is confusing on top of being fragile.
    var endpointURL: String? {
        guard case .ready(let port) = status else {
            return nil
        }
        let host = LocalAddress.candidates().first ?? Self.localHostName()
        return "http://\(host):\(port)"
    }

    /// Deliberately does nothing.
    ///
    /// Everything this needs — opening the database, reading the token from the
    /// Keychain — is file and Security I/O, and this type is `@MainActor`. Doing
    /// any of it here blocks the main thread before the window is even drawn: a
    /// Keychain read that waits on a prompt leaves the app running with no
    /// window and no way to tell what happened.
    init() {}

    /// One assembled set of services, built off the main thread.
    private struct Assembled: @unchecked Sendable {
        let store: IngestStore
        let receiver: HealthReceiver
        let token: String
        let computerName: String
        let directory: URL
    }

    nonisolated private static func assemble() throws -> Assembled {
        // Deliberately the app's own storage rather than the app-group-aware
        // path: see StoreLocation.privateSupportDirectory.
        let directory = try StoreLocation.privateSupportDirectory()
            .appending(path: "Received", directoryHint: .isDirectory)
        let store = try IngestStore(directory: directory)
        let name = Host.current().localizedName ?? "This Mac"
        let token = try resolveToken()

        // Publish to the user's own iCloud Keychain so their phone already
        // knows the token and never has to be introduced to this computer.
        // Best-effort: without the shared-group entitlement or iCloud this does
        // nothing, and the phone falls back to pairing over the network.
        let shared = SharedReceiverStore(
            accessGroup: SharedReceiverStore.resolvedAccessGroup()
        )
        do {
            // Published without an address here; the port is not known until
            // the listener is ready, and republishing then fills it in.
            try shared.publish(
                SharedReceiver(name: "Hozz on \(name)", token: token)
            )
        } catch {
            // Not fatal — the phone can still pair over the network — but it is
            // logged, because a silent failure here looks identical to the
            // feature working and is otherwise undiagnosable.
            Self.log.error(
                "Could not publish this Mac to iCloud Keychain: \(error.localizedDescription, privacy: .public)"
            )
        }

        return Assembled(
            store: store,
            receiver: HealthReceiver(
                store: store,
                token: token,
                serviceName: "Hozz on \(name)"
            ),
            token: token,
            computerName: name,
            directory: directory
        )
    }

    func start() async {
        let assembled: Assembled
        do {
            assembled = try await Task.detached(priority: .userInitiated) {
                try Self.assemble()
            }.value
        } catch {
            // Shown in the UI and logged: "it just doesn't work" is impossible
            // to diagnose from a screenshot of a failure message alone.
            Self.log.error(
                "Hozz could not start: \(error.localizedDescription, privacy: .public)"
            )
            status = .failed(error.localizedDescription)
            return
        }

        let receiver = assembled.receiver
        store = assembled.store
        self.receiver = receiver
        token = assembled.token
        computerName = assembled.computerName
        dataDirectory = assembled.directory

        await receiver.onStateChange { [weak self] state in
            Task { @MainActor in
                self?.apply(state)
            }
        }
        await receiver.onEvent { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                self.events.insert(event, at: 0)
                if self.events.count > 100 {
                    self.events.removeLast()
                }
                if case .stored = event.outcome {
                    self.lastReceivedAt = event.at
                }
                self.devices = await receiver.devices
                await self.refresh()
            }
        }
        await receiver.start()
        await refresh()
    }

    func stop() async {
        await receiver?.stop()
    }

    func refresh() async {
        guard let store else {
            return
        }
        do {
            summaries = try await store.summaries()
            totalRecords = try await store.totalRecordCount()
        } catch {
            // A read failure is not worth interrupting the user over; the
            // counts simply stay as they were.
        }
    }

    func aggregate(
        type: String,
        bucket: BucketSize
    ) async -> [AggregateBucket] {
        guard let store else { return [] }
        return (try? await store.aggregate(type: type, bucket: bucket)) ?? []
    }

    func samples(type: String, limit: Int = 200) async -> [HealthRecord] {
        guard let store else { return [] }
        return (try? await store.samples(type: type, limit: limit)) ?? []
    }

    /// Writes every stored sample of a type to a file the user chose.
    func exportCSV(type: String, to url: URL) async throws {
        guard let store else { return }
        let records = try await store.samples(type: type, limit: .max)
        var text = "id,type,startDate,endDate,value,unit,source\n"
        for record in records {
            text += [
                Self.csvField(record.id),
                Self.csvField(record.type),
                Timestamps.text(from: record.startDate),
                Timestamps.text(from: record.endDate),
                record.value.map { String($0) } ?? "",
                Self.csvField(record.unit ?? ""),
                Self.csvField(record.sourceName ?? "")
            ].joined(separator: ",") + "\n"
        }
        try Data(text.utf8).write(to: url)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// Records where this computer can actually be reached.
    ///
    /// Bonjour is not dependable — plenty of networks block mDNS, and a managed
    /// Mac may refuse to advertise on its real interface — so the address goes
    /// into the same private record as the token. The phone can then find this
    /// computer with no discovery at all.
    private func publishAddress(port: UInt16) {
        let hosts = LocalAddress.candidates()
        guard !token.isEmpty, !hosts.isEmpty else {
            return
        }
        let record = SharedReceiver(
            name: computerName.isEmpty ? "Mac" : "Hozz on \(computerName)",
            token: token,
            endpoints: hosts.map { "http://\($0):\(port)" }
        )
        Task.detached(priority: .utility) {
            do {
                let group = SharedReceiverStore.resolvedAccessGroup()
                try SharedReceiverStore(accessGroup: group).publish(record)
                // Addresses only — never the token.
                Self.log.info(
                    "Published \(record.endpoints.joined(separator: ", "), privacy: .public) to group \(group ?? "none", privacy: .public)"
                )
            } catch {
                Self.log.error(
                    "Could not publish this Mac's address: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func apply(_ state: ReceiverState) {
        switch state {
        case .listening(let port):
            status = .ready(port: port)
            publishAddress(port: port)
        case .failed(let reason):
            status = .failed(reason)
        case .starting, .stopped:
            status = .starting
        }
    }

    /// The token is generated once and kept in the Keychain.
    ///
    /// The listener is reachable by anything else on the network — a guest
    /// phone, a smart TV, a housemate — so an unauthenticated receiver is not
    /// offered even as an option.
    nonisolated private static func resolveToken() throws -> String {
        let credentials = DestinationCredentials(
            service: "com.thatcube.Hozz.receiver"
        )
        if let existing = try credentials.secret(for: "receiver-token"),
           !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        try credentials.save(token, for: "receiver-token")
        return token
    }

    private static func localHostName() -> String {
        // The .local name follows the computer around every network it joins,
        // where an IP address does not.
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}
