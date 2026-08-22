import Foundation
import Security

public enum CredentialError: Error, LocalizedError, Sendable {
    case storeFailed(OSStatus)
    case readFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .storeFailed(let status):
            "Hozz could not save the credential securely (\(status))."
        case .readFailed(let status):
            "Hozz could not read the saved credential (\(status))."
        }
    }
}

/// Stores destination secrets in the Keychain, device-only.
///
/// Two properties matter and are asserted by tests:
///
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` keeps the secret off
///   iCloud Keychain and off backups, while still allowing a background sync
///   to read it once the device has been unlocked since boot.
/// - Secrets never enter the SQLite store, an export, or a log.
public struct DestinationCredentials: Sendable {
    private let service: String
    private let synchronizable: Bool
    private let accessGroup: String?

    /// - Parameters:
    ///   - synchronizable: Whether the secret belongs to the *person* rather
    ///     than to this device, and should follow them via iCloud Keychain.
    ///     Destination secrets are device-only; the receiver token is not,
    ///     because the whole point is that the user's own Mac and phone already
    ///     share an identity and should not have to be introduced by hand.
    ///   - accessGroup: A shared keychain group, needed when two different
    ///     apps have to read the same item. Passing one the build is not
    ///     entitled to fails every call, so callers should supply it only when
    ///     the entitlement is present.
    public init(
        service: String = "com.thatcube.Hozz.destinations",
        synchronizable: Bool = false,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.synchronizable = synchronizable
        self.accessGroup = accessGroup
    }

    /// iCloud Keychain refuses to carry an item marked for this device only, so
    /// a synchronizable item must relax to `afterFirstUnlock`. The pairing is
    /// enforced here rather than left to each caller, because getting it wrong
    /// fails silently: the item saves, and simply never appears anywhere else.
    private var accessibility: CFString {
        synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }

    public func save(_ secret: String, for key: String) throws {
        let data = Data(secret.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]

        let status = withKeychain(for: key) { query in
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                update as CFDictionary
            )
            guard updateStatus == errSecItemNotFound else {
                return updateStatus
            }
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = accessibility
            return SecItemAdd(insert as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw CredentialError.storeFailed(status)
        }
    }

    public func secret(for key: String) throws -> String? {
        var found: Data?
        let status = withKeychain(for: key) { query in
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &item)
            found = item as? Data
            return status
        }

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let found else {
            throw CredentialError.readFailed(status)
        }
        return String(data: found, encoding: .utf8)
    }

    public func delete(for key: String) throws {
        let status = withKeychain(for: key) { query in
            SecItemDelete(query as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.storeFailed(status)
        }
    }

    /// Reports the accessibility class actually applied, so a test can prove
    /// the secret is device-only rather than trusting the write path.
    public func accessibility(for key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard
            status == errSecSuccess,
            let attributes = item as? [String: Any]
        else {
            throw CredentialError.readFailed(status)
        }
        return attributes[kSecAttrAccessible as String] as? String
    }

    private func baseQuery(
        for key: String,
        modernKeychain: Bool = true
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            // Must appear on every query — add, update, copy and delete alike —
            // or a synchronizable item simply will not match and the call
            // reports "not found" rather than anything explanatory.
            kSecAttrSynchronizable as String: synchronizable
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        #if os(macOS)
        // Prefer the modern, iOS-style keychain. The legacy file-based one
        // grants access per code signature, so every rebuild or update prompts
        // "allow access?" and blocks the call until someone clicks.
        if modernKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return query
    }

    /// Runs a Keychain operation, falling back to the legacy macOS keychain.
    ///
    /// The modern keychain needs a `keychain-access-groups` entitlement, which
    /// a locally-signed build does not have — it fails with
    /// `errSecMissingEntitlement`. Refusing to store the token at all in that
    /// case would stop the app working entirely, so the legacy keychain is used
    /// instead: it may prompt, but it is never silently skipped, and the secret
    /// still never touches a plain file.
    private func withKeychain(
        for key: String,
        _ operation: (_ query: [String: Any]) -> OSStatus
    ) -> OSStatus {
        let status = operation(baseQuery(for: key))
        #if os(macOS)
        if status == errSecMissingEntitlement {
            return operation(baseQuery(for: key, modernKeychain: false))
        }
        #endif
        return status
    }
}
