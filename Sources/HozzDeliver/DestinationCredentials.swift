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

    public init(service: String = "com.thatcube.Hozz.destinations") {
        self.service = service
    }

    public func save(_ secret: String, for key: String) throws {
        let data = Data(secret.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
            insert[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
            // Never synchronise a Health destination secret to another device.
            kSecAttrSynchronizable as String: false
        ]
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
