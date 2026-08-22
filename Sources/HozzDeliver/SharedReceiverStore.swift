import Foundation
import HozzCore

/// What a computer publishes about itself so the user's own phone can connect
/// without being introduced to it by hand.
public struct SharedReceiver: Codable, Hashable, Sendable {
    public let name: String
    public let token: String
    /// Every address the computer might be reachable at, best first.
    ///
    /// A list rather than one address, because there is no single answer that
    /// is right everywhere. Bonjour cannot be relied on — plenty of networks
    /// block mDNS, and a managed Mac may refuse to advertise on its real
    /// interface — so the addresses travel with the token. And the *correct*
    /// one depends on where the phone is: a home address works on the same
    /// Wi-Fi and nowhere else, while a Tailscale address works from anywhere
    /// but only while both devices are on the tailnet.
    ///
    /// The phone tries each and keeps the first that answers, so a computer
    /// that moves network, changes address, or joins a VPN keeps working
    /// instead of silently going quiet.
    public let endpoints: [String]
    public let updatedAt: Date

    public init(
        name: String,
        token: String,
        endpoints: [String] = [],
        updatedAt: Date = .now
    ) {
        self.name = name
        self.token = token
        self.endpoints = endpoints
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case name, token, endpoints, endpoint, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        token = try container.decode(String.self, forKey: .token)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        if let list = try container.decodeIfPresent([String].self, forKey: .endpoints) {
            endpoints = list
        } else if let single = try container.decodeIfPresent(String.self, forKey: .endpoint) {
            // A record written before addresses became a list.
            endpoints = [single]
        } else {
            endpoints = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(token, forKey: .token)
        try container.encode(endpoints, forKey: .endpoints)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

/// The receiver token, shared between the user's own devices via iCloud
/// Keychain.
///
/// This is what turns "connect your Mac" into nothing at all. Both devices are
/// already signed into the same Apple account, which is a far stronger proof
/// that they belong to the same person than anything Hozz could establish over
/// a home network — so when it is available, there is no pairing step, no
/// prompt and no token to copy. The phone simply finds the computer and already
/// knows the secret.
///
/// Two things make this safe rather than convenient-but-sloppy:
///
/// 1. It is the Keychain, not a preference. The token is never written to a
///    file, a backup, or a log, and iCloud Keychain is end-to-end encrypted.
/// 2. It is scoped to a shared access group both Hozz apps declare, so no other
///    application can read it.
///
/// When the entitlement or iCloud is unavailable this reports nothing rather
/// than pretending, and the caller falls back to pairing over the network. A
/// silent empty result here would look exactly like "no computer set up yet",
/// which is the honest description of that situation anyway.
public struct SharedReceiverStore: Sendable {
    /// The keychain group both Hozz apps declare.
    ///
    /// Two different applications cannot see one another's keychain items
    /// without this, and an app may only claim groups prefixed with its own
    /// team identifier — which is why one string is shared rather than each app
    /// naming itself.
    public static let accessGroupSuffix = "com.thatcube.Hozz.shared"

    private static let service = "com.thatcube.Hozz.shared"
    private static let account = "receiver"

    private let credentials: DestinationCredentials

    /// - Parameter accessGroup: The fully-qualified group, including the team
    ///   prefix. Passing `nil` uses the app's own group, which still syncs
    ///   between that one app's installs but cannot be read by the other app.
    public init(accessGroup: String?) {
        self.credentials = DestinationCredentials(
            service: Self.service,
            synchronizable: true,
            accessGroup: accessGroup
        )
    }

    /// Publishes this computer so the user's phone can find it.
    public func publish(_ receiver: SharedReceiver) throws {
        let encoded = try JSONEncoder().encode(receiver)
        try credentials.save(
            String(decoding: encoded, as: UTF8.self),
            for: Self.account
        )
    }

    /// The computer this person has already set up, if any.
    ///
    /// Returns `nil` rather than throwing when the keychain is unavailable or
    /// unentitled: not knowing is a normal state, and the caller has a working
    /// fallback.
    public func published() -> SharedReceiver? {
        guard
            let raw = try? credentials.secret(for: Self.account),
            let data = raw.data(using: .utf8)
        else {
            return nil
        }
        return try? JSONDecoder().decode(SharedReceiver.self, from: data)
    }

    /// Removes the shared record, so a rotated token cannot be resurrected.
    public func withdraw() {
        try? credentials.delete(for: Self.account)
    }
}

public extension SharedReceiverStore {
    /// The fully-qualified shared keychain group for this build, or `nil` when
    /// the app is not entitled to one.
    ///
    /// The team prefix is discovered rather than compiled in, so no team
    /// identifier has to be committed to the repository. The technique is to
    /// write a throwaway item without naming a group and read back the group
    /// the system assigned, which is always `<team>.<bundle id>`.
    static func resolvedAccessGroup() -> String? {
        guard let prefix = teamPrefix() else {
            return nil
        }
        return prefix + accessGroupSuffix
    }

    private static func teamPrefix() -> String? {
        let probeAccount = "com.thatcube.Hozz.group-probe"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: probeAccount,
            kSecAttrService as String: probeAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        #if os(macOS)
        // Essential. Without this the probe lands in the legacy macOS keychain,
        // which has no concept of access groups at all — so it reports no group,
        // the shared group is never resolved, and each app silently writes
        // somewhere the other cannot read.
        query[kSecUseDataProtectionKeychain as String] = true
        #endif

        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            var insert = query
            insert.removeValue(forKey: kSecReturnAttributes as String)
            insert.removeValue(forKey: kSecMatchLimit as String)
            insert[kSecValueData as String] = Data("probe".utf8)
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                return nil
            }
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }

        guard
            status == errSecSuccess,
            let attributes = item as? [String: Any],
            let group = attributes[kSecAttrAccessGroup as String] as? String,
            let dot = group.firstIndex(of: ".")
        else {
            return nil
        }
        // "<team>.<bundle id>" — everything up to and including the first dot.
        return String(group[...dot])
    }
}

/// This machine's address on the network it actually uses.
public enum LocalAddress {
    /// Every address this machine might usefully be reached at, best first.
    ///
    /// Ordinary network interfaces come first because they are the fast path on
    /// a shared network. Tailscale addresses follow: they work from anywhere on
    /// the tailnet, including over cellular, which is the only thing that keeps
    /// working when the phone leaves the house.
    ///
    /// Other tunnels are deliberately excluded. A corporate VPN address is not
    /// merely useless to the phone — the same private address very likely
    /// belongs to a *different* machine on that network, so offering it invites
    /// sending Health data somewhere it should never go.
    public static func candidates() -> [String] {
        var local: [String] = []
        var tailnet: [String] = []

        for (name, address) in interfaceAddresses() {
            if isTailscale(address) {
                tailnet.append(address)
            } else if name.hasPrefix("en") {
                // en0 is the usual Wi-Fi interface, so it leads.
                if name == "en0" {
                    local.insert(address, at: 0)
                } else {
                    local.append(address)
                }
            }
        }
        return local + tailnet
    }

    /// Tailscale hands every device an address in the 100.64.0.0/10 range.
    static func isTailscale(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else {
            return false
        }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    private static func interfaceAddresses() -> [(String, String)] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return []
        }
        defer { freeifaddrs(addresses) }

        var found: [(String, String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard
                flags & IFF_UP == IFF_UP,
                flags & IFF_LOOPBACK == 0,
                let addr = pointer.pointee.ifa_addr,
                addr.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }
            let name = String(cString: pointer.pointee.ifa_name)
            guard !name.hasPrefix("awdl"),
                  !name.hasPrefix("llw"),
                  !name.hasPrefix("ap") else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }
            found.append((name, String(cString: host)))
        }
        return found
    }

    /// The IPv4 address of the interface carrying the default route.
    public static func primaryIPv4() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else {
            return nil
        }
        defer { freeifaddrs(addresses) }

        var candidate: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard
                flags & IFF_UP == IFF_UP,
                flags & IFF_LOOPBACK == 0,
                let addr = pointer.pointee.ifa_addr,
                addr.pointee.sa_family == UInt8(AF_INET)
            else {
                continue
            }
            let name = String(cString: pointer.pointee.ifa_name)
            // Skip the peer-to-peer and tunnel interfaces: they are reachable
            // from almost nothing, which is exactly the failure being fixed.
            guard !name.hasPrefix("utun"),
                  !name.hasPrefix("awdl"),
                  !name.hasPrefix("llw"),
                  !name.hasPrefix("ap") else {
                continue
            }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }
            let text = String(cString: host)
            // en0 is the usual Wi-Fi interface and is preferred outright;
            // anything else is kept only as a fallback.
            if name == "en0" {
                return text
            }
            if candidate == nil {
                candidate = text
            }
        }
        return candidate
    }
}
