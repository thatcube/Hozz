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
/// What the browser is currently doing, so a caller never has to render
/// nothing and leave the user guessing.
public enum BrowsingState: Hashable, Sendable {
    case idle
    case searching
    case denied
    case failed(String)
}

public actor ReceiverBrowser {
    private static let log = Logger(
        subsystem: "com.thatcube.Hozz",
        category: "browser"
    )

    private var browser: NWBrowser?
    private var found: [String: DiscoveredReceiver] = [:]
    private var observers: [@Sendable ([DiscoveredReceiver]) -> Void] = []
    private var stateObservers: [@Sendable (BrowsingState) -> Void] = []
    private(set) public var state: BrowsingState = .idle
    /// Guards against restarting forever if mDNSResponder is truly unwell.
    private var restarts = 0
    private static let maximumRestarts = 5

    public init() {}

    public func onChange(
        _ observer: @escaping @Sendable ([DiscoveredReceiver]) -> Void
    ) {
        observers.append(observer)
        observer(sorted())
    }

    public func onStateChange(
        _ observer: @escaping @Sendable (BrowsingState) -> Void
    ) {
        stateObservers.append(observer)
        observer(state)
    }

    private func update(_ newState: BrowsingState) {
        state = newState
        for observer in stateObservers {
            observer(newState)
        }
    }

    public func start() {
        guard browser == nil else {
            return
        }
        let parameters = NWParameters()
        // Peer-to-peer is deliberately off. It steers discovery onto the
        // AirPlay/AWDL interface instead of the network both devices are
        // actually on, which is precisely how the Mac ended up advertising
        // somewhere the phone could never see it.
        parameters.includePeerToPeer = false
        // A receiver is on the local network by definition; browsing over
        // cellular can only waste time and battery.
        parameters.prohibitedInterfaceTypes = [.cellular]

        let browser = NWBrowser(
            for: .bonjour(type: HozzService.bonjourType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.apply(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(state) }
        }
        browser.start(queue: .main)
        self.browser = browser
        update(.searching)
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            restarts = 0
            update(.searching)
        case .waiting(let error), .failed(let error):
            // mDNSResponder is restarted by the system from time to time, and
            // every browser attached to the old instance is left permanently
            // defunct rather than being reconnected. The only remedy is to
            // build a new one; without it, discovery works until the first
            // network change and then silently never finds anything again.
            if Self.isDefunct(error), restarts < Self.maximumRestarts {
                restarts += 1
                Self.log.info("mDNS connection went defunct; restarting the browser.")
                browser?.cancel()
                browser = nil
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    await self?.start()
                }
                return
            }
            // Refusing local network access is by far the most common cause,
            // and it is silent: browsing simply never returns anything. Saying
            // so is the difference between "this feature is broken" and "tap
            // Allow". Logged at error level because a debug-level message here
            // is invisible exactly when it is needed.
            Self.log.error(
                "Browsing unavailable: \(error.localizedDescription, privacy: .public)"
            )
            update(Self.isPermissionProblem(error) ? .denied : .failed(error.localizedDescription))
        case .cancelled:
            update(.idle)
        default:
            break
        }
    }

    /// The system restarted mDNSResponder and abandoned this browser.
    static func isDefunct(_ error: NWError) -> Bool {
        if case .dns(let code) = error {
            return code == kDNSServiceErr_DefunctConnection
        }
        return false
    }

    private static func isPermissionProblem(_ error: NWError) -> Bool {
        switch error {
        case .dns(let code):
            // The documented signal that local network access was refused.
            // Easy to miss, because the browser otherwise looks healthy and
            // simply never returns a result.
            return code == kDNSServiceErr_PolicyDenied
        case .posix(let code):
            return code == .EPERM || code == .EACCES || code == .ENETDOWN
        default:
            return false
        }
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        found.removeAll()
        notify()
        update(.idle)
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
    ///
    /// IPv4 is asked for by name. The address discovered here is not used by
    /// this connection: it is written down and handed to `URLSession` later, as
    /// a string, with none of the interface scope that made it work. Left to
    /// itself Network.framework prefers IPv6 and hands back a link-local
    /// address, which is meaningless without the interface it arrived on — so
    /// the computer resolved, appeared in the list, and then never answered
    /// anything again. What the receiver publishes about itself is IPv4 for the
    /// same reason.
    private func resolve(name: String, endpoint: NWEndpoint) async {
        let resolved: (host: String, port: UInt16)? = await withCheckedContinuation { continuation in
            let parameters = NWParameters.tcp
            if let ip = parameters.defaultProtocolStack.internetProtocol
                as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: endpoint, using: parameters)
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
                    guard let text = Self.text(for: host) else {
                        box.resume(nil)
                        connection.cancel()
                        return
                    }
                    box.resume((text, port.rawValue))
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

    /// The address as a URL host, or `nil` when it cannot honestly be written
    /// as one.
    ///
    /// A link-local address only means anything alongside the interface it was
    /// seen on, and that scope cannot survive the trip through a stored string
    /// and a fresh `URLSession` request. Stripping the `%en0` and keeping the
    /// rest produced an address that parses, connects to nothing, and reports
    /// the computer as not answering — which is a worse outcome than not
    /// offering it, because the computer is plainly switched on and the message
    /// says otherwise. Nothing is returned instead, so the browser waits for an
    /// address it can actually use.
    private static func text(for host: NWEndpoint.Host) -> String? {
        switch host {
        case .name(let name, _):
            name
        case .ipv4(let address):
            address.isLinkLocal
                ? nil
                : "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        case .ipv6(let address):
            // A bracketed literal, or the URL cannot be parsed.
            address.isLinkLocal
                ? nil
                : "[\("\(address)".split(separator: "%").first.map(String.init) ?? "\(address)")]"
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
