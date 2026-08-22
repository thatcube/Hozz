import Foundation
import HozzCore

/// What a computer publishes about itself so the user's own phone can connect
/// without being introduced to it by hand.
public struct SharedReceiver: Codable, Hashable, Sendable {
    public let name: String
    public let token: String
    public let updatedAt: Date

    public init(name: String, token: String, updatedAt: Date = .now) {
        self.name = name
        self.token = token
        self.updatedAt = updatedAt
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: probeAccount,
            kSecAttrService as String: probeAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

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
