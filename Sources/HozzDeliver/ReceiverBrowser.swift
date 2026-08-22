import Foundation
import HozzCore
import Network
import os

/// A Hozz receiver found on the local network.
public struct DiscoveredReceiver: Identifiable, Hashable, Sendable {
    public let id: String
    /// What the user sees, e.g. "Hozz on Brandon's MacBook Pro".
    public let name: String
    /// The address to deliver to, once resolved.
    public let url: String

    public init(id: String, name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }
}

/// Finds Hozz receivers advertising on the local network.
///
/// This is the half that makes setup painless. Typing an IP address is where
/// most people abandon a self-hosted tool, and a home IP changes without
/// warning, so a hand-typed one silently stops working days later and looks
/// like the app broke. Browsing means the address is discovered, not
/// remembered.
///
/// The address is still resolved to a concrete host and port and stored, so a
/// destination keeps working if the receiver is later reached by a fixed
/// address instead.
public actor ReceiverBrowser {
    private static let log = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "browser"
    )

    private var browser: NWBrowser?
    private var found: [String: DiscoveredReceiver] = [:]
    private var observers: [@Sendable ([DiscoveredReceiver]) -> Void] = []

    public init() {}

    public func onChange(
        _ observer: @escaping @Sendable ([DiscoveredReceiver]) -> Void
    ) {
        observers.append(observer)
        observer(sorted())
    }

    public func start() {
        guard browser == nil else {
            return
        }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: HozzService.bonjourType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.apply(results) }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                // Almost always the local network permission being refused.
                // Typing an address by hand still works, so this is not fatal.
                Self.log.debug(
                    "Browsing unavailable: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        found.removeAll()
        notify()
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        let names = results.compactMap { result -> (String, NWEndpoint)? in
            guard case .service(let name, _, _, _) = result.endpoint else {
                return nil
            }
            return (name, result.endpoint)
        }

        // Drop anything that has gone away, so a receiver that was switched off
        // does not linger in the list looking available.
        let live = Set(names.map(\.0))
        found = found.filter { live.contains($0.key) }
        notify()

        for (name, endpoint) in names where found[name] == nil {
            Task { await self.resolve(name: name, endpoint: endpoint) }
        }
    }

    /// Turns an advertised service into a concrete address.
    ///
    /// A Bonjour service name is not a host name — "Hozz on Brandon's MacBook"
    /// resolves to something quite different — so the endpoint is resolved by
    /// actually connecting to it. Guessing the address from the name would
    /// produce a destination that silently never delivers.
    private func resolve(name: String, endpoint: NWEndpoint) async {
        let resolved: (host: String, port: UInt16)? = await withCheckedContinuation { continuation in
            let connection = NWConnection(to: endpoint, using: .tcp)
            let box = ResumeOnce(continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard
                        let remote = connection.currentPath?.remoteEndpoint,
                        case .hostPort(let host, let port) = remote
                    else {
                        box.resume(nil)
                        connection.cancel()
                        return
                    }
                    box.resume((Self.text(for: host), port.rawValue))
                    connection.cancel()
                case .failed, .cancelled:
                    box.resume(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))

            // A receiver that advertises but cannot be reached must not leave
            // the list waiting forever.
            Task {
                try? await Task.sleep(for: .seconds(5))
                box.resume(nil)
                connection.cancel()
            }
        }

        guard let resolved else {
            return
        }
        found[name] = DiscoveredReceiver(
            id: name,
            name: name,
            url: "http://\(resolved.host):\(resolved.port)"
        )
        notify()
    }

    private static func text(for host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _):
            name
        case .ipv4(let address):
            "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        case .ipv6(let address):
            // A bracketed literal, or the URL cannot be parsed.
            "[\("\(address)".split(separator: "%").first.map(String.init) ?? "\(address)")]"
        @unknown default:
            "\(host)"
        }
    }

    private func sorted() -> [DiscoveredReceiver] {
        found.values.sorted { $0.name < $1.name }
    }

    private func notify() {
        let current = sorted()
        for observer in observers {
            observer(current)
        }
    }
}

/// Guarantees a continuation is resumed exactly once.
///
/// Resolution races a ready state, a failure, and a timeout, and any of the
/// three can arrive first. Resuming a checked continuation twice is a crash,
/// and never resuming it hangs the caller forever.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
