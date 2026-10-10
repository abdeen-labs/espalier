import Foundation
import Security
import Synchronization

/// Stores secrets (tokens, API keys, passwords) by service and account.
///
/// The app uses `KeychainSecretStore`; tests use `InMemorySecretStore` so
/// they never touch, or prompt for, the real keychain.
public protocol SecretStore: Sendable {
    /// The secret for `account` in `service`, or `nil` if none is stored.
    func secret(service: String, account: String) throws -> String?

    /// Stores `secret`, replacing any existing one.
    func setSecret(_ secret: String, service: String, account: String) throws

    /// Removes the secret. Returns whether one existed.
    @discardableResult
    func deleteSecret(service: String, account: String) throws -> Bool
}

/// A keychain operation failed.
public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain \(operation) failed: \(message)"
    }
}

/// Generic-password items in the user's keychain.
public struct KeychainSecretStore: SecretStore {
    public init() {}

    public func secret(service: String, account: String) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status, operation: "read")
        }
    }

    public func setSecret(_ secret: String, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let data = Data(secret.utf8)

        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = service
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus, operation: "add")
            }
        default:
            throw KeychainError(status: status, operation: "update")
        }
    }

    @discardableResult
    public func deleteSecret(service: String, account: String) throws -> Bool {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw KeychainError(status: status, operation: "delete")
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Secrets held in memory, for tests and previews.
public final class InMemorySecretStore: SecretStore {
    private struct Key: Hashable {
        let service: String
        let account: String
    }

    private let secrets = Mutex<[Key: String]>([:])

    public init() {}

    public func secret(service: String, account: String) throws -> String? {
        secrets.withLock { $0[Key(service: service, account: account)] }
    }

    public func setSecret(_ secret: String, service: String, account: String) throws {
        secrets.withLock { $0[Key(service: service, account: account)] = secret }
    }

    @discardableResult
    public func deleteSecret(service: String, account: String) throws -> Bool {
        secrets.withLock { $0.removeValue(forKey: Key(service: service, account: account)) != nil }
    }
}
