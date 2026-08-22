import Foundation
import HozzCore

/// Finds a receiver by trying every address on this device's own network.
///
/// The last resort, and the one that keeps working when the clever routes fail.
/// Bonjour depends on mDNS, which plenty of networks and managed devices refuse
/// to carry. The published-address route depends on iCloud having synced, which
/// is not instant and is not guaranteed. Neither is dependable enough to be the
/// only answer, and when both come up empty the user is left with a computer
/// they can see is running and an app insisting it cannot be found.
///
/// A sweep has none of those dependencies: the receiver listens on a known
/// port, so every address on the local network is asked directly. On a home
/// network that is 254 short connections, done concurrently, and it finishes in
/// about a second.
public struct LocalNetworkScan: Sendable {
    /// How many addresses are probed at once.
    ///
    /// High enough to finish quickly, low enough not to exhaust the socket
    /// limit or make a router think it is being scanned maliciously.
    private static let concurrency = 32

    private let port: UInt16
    private let probe: ReceiverProbe

    public init(port: UInt16, timeout: TimeInterval = 1) {
        self.port = port
        self.probe = ReceiverProbe(timeout: timeout)
    }

    /// Every receiver found on this device's networks.
    public func scan() async -> [String] {
        var results: [String] = []
        for prefix in Self.localPrefixes() {
            results.append(contentsOf: await sweep(prefix: prefix))
        }
        return results
    }

    /// The first receiver found, or `nil`.
    public func firstFound() async -> String? {
        for prefix in Self.localPrefixes() {
            if let found = await sweep(prefix: prefix, stopAtFirst: true).first {
                return found
            }
        }
        return nil
    }

    private func sweep(
        prefix: String,
        stopAtFirst: Bool = false
    ) async -> [String] {
        var found: [String] = []
        var host = 1

        while host <= 254 {
            let batch = (host..<min(host + Self.concurrency, 255)).map {
                "http://\(prefix).\($0):\(port)"
            }
            host += Self.concurrency

            let hits = await withTaskGroup(of: String?.self) { group in
                for endpoint in batch {
                    group.addTask {
                        await probe.isReceiver(endpoint) ? endpoint : nil
                    }
                }
                var hits: [String] = []
                for await result in group {
                    if let result {
                        hits.append(result)
                    }
                }
                return hits
            }

            found.append(contentsOf: hits)
            if stopAtFirst, !found.isEmpty {
                return found
            }
        }
        return found
    }

    /// The `a.b.c` part of every IPv4 network this device is on.
    ///
    /// Only ordinary interfaces, and only /24-sized private networks. Sweeping
    /// a larger or public range would be slow, pointless, and would look to a
    /// network operator exactly like a port scan.
    static func localPrefixes() -> [String] {
        var prefixes: [String] = []
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return []
        }
        defer { freeifaddrs(addresses) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard
                flags & IFF_UP == IFF_UP,
                flags & IFF_LOOPBACK == 0,
                let addr = pointer.pointee.ifa_addr,
                addr.pointee.sa_family == UInt8(AF_INET),
                let netmask = pointer.pointee.ifa_netmask
            else {
                continue
            }
            let name = String(cString: pointer.pointee.ifa_name)
            guard name.hasPrefix("en") else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else {
                continue
            }
            var mask = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                netmask, socklen_t(netmask.pointee.sa_len),
                &mask, socklen_t(mask.count), nil, 0, NI_NUMERICHOST
            ) == 0 else {
                continue
            }

            let address = String(cString: host)
            // Anything wider than a /24 is too many addresses to be worth
            // sweeping, and anything narrower is covered by it anyway.
            guard String(cString: mask) == "255.255.255.0",
                  isPrivate(address) else {
                continue
            }
            let parts = address.split(separator: ".")
            guard parts.count == 4 else {
                continue
            }
            let prefix = parts.prefix(3).joined(separator: ".")
            if !prefixes.contains(prefix) {
                prefixes.append(prefix)
            }
        }
        return prefixes
    }

    static func isPrivate(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else {
            return false
        }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        return false
    }
}
