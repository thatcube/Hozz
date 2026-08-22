import Foundation
import HozzDeliver
import HozzMCP
import HozzReceive
import HozzStore
import Observation

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
    enum Status: Equatable {
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    private(set) var status: Status = .starting
    private(set) var summaries: [TypeSummary] = []
    private(set) var totalRecords = 0
    private(set) var events: [ReceiverEvent] = []

    let token: String
    let computerName: String

    /// Where the received database actually lives.
    ///
    /// Surfaced because the MCP tool runs outside this app's sandbox and cannot
    /// derive it: the container path has to be handed over explicitly.
    let dataDirectory: URL

    private let store: IngestStore
    private let receiver: HealthReceiver
    private var refreshTask: Task<Void, Never>?

    /// The address to give the phone, once the receiver is listening.
    var endpointURL: String? {
        guard case .ready(let port) = status else {
            return nil
        }
        return "http://\(Self.localHostName()):\(port)"
    }

    init() throws {
        let directory = try StoreLocation.supportDirectory()
            .appending(path: "Received", directoryHint: .isDirectory)
        let store = try IngestStore(directory: directory)
        self.store = store
        self.dataDirectory = directory

        let name = Host.current().localizedName ?? "This Mac"
        self.computerName = name
        self.token = try Self.resolveToken()
        self.receiver = HealthReceiver(
            store: store,
            token: token,
            serviceName: "Hozz on \(name)"
        )
    }

    func start() async {
        await receiver.onStateChange { [weak self] state in
            Task { @MainActor in
                self?.apply(state)
            }
        }
        await receiver.onEvent { [weak self] event in
            Task { @MainActor in
                self?.events.insert(event, at: 0)
                if self?.events.count ?? 0 > 100 {
                    self?.events.removeLast()
                }
                await self?.refresh()
            }
        }
        await receiver.start()
        await refresh()
    }

    func stop() async {
        refreshTask?.cancel()
        await receiver.stop()
    }

    func refresh() async {
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
        (try? await store.aggregate(type: type, bucket: bucket)) ?? []
    }

    func samples(type: String, limit: Int = 200) async -> [HealthRecord] {
        (try? await store.samples(type: type, limit: limit)) ?? []
    }

    /// Writes every stored sample of a type to a file the user chose.
    func exportCSV(type: String, to url: URL) async throws {
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

    private func apply(_ state: ReceiverState) {
        switch state {
        case .listening(let port):
            status = .ready(port: port)
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
    private static func resolveToken() throws -> String {
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
