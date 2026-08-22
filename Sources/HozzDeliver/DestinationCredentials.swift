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
        var query = baseQuery(for: key)

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialError.storeFailed(addStatus)
            }
            return
        }
        guard status == errSecSuccess else {
            throw CredentialError.storeFailed(status)
        }
    }

    public func secret(for key: String) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CredentialError.readFailed(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
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

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            // Never synchronise a Health destination secret to another device.
            kSecAttrSynchronizable as String: false
        ]
    }
}
