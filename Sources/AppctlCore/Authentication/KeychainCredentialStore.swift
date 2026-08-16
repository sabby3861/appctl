import Foundation
import Security

/// Stores App Store Connect credentials as generic-password items in the user's
/// login keychain under a single service name, one item per credential.
///
/// Items are deliberately created without `kSecUseDataProtectionKeychain`: the
/// data-protection keychain requires a keychain-access-group entitlement that an
/// unsigned, locally built CLI does not have, so setting it breaks local
/// development with errSecMissingEntitlement. Do not re-add it in a
/// modernization pass.
public struct KeychainCredentialStore: Sendable {
    public static let defaultService = "com.appctl.credentials"

    /// Account names within the service; visible to users in Keychain Access.
    public enum Account: String, CaseIterable, Sendable {
        case keyID = "key-id"
        case issuerID = "issuer-id"
        case privateKey = "private-key"
    }

    public let service: String

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    /// Stores or overwrites the credential. Re-running `auth setup --keychain`
    /// is the normal case, so `errSecDuplicateItem` routes to an update.
    public func store(_ value: String, account: Account) throws {
        let data = Data(value.utf8)
        var query = baseQuery(for: account)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery(for: account) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw error("update", updateStatus) }
        default:
            throw error("store", status)
        }
    }

    /// Returns the stored credential, or nil when no item exists.
    public func read(_ account: Account) throws -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                throw error("read", errSecDecode)
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw error("read", status)
        }
    }

    /// Removes the credential; returns whether an item existed.
    @discardableResult
    public func delete(_ account: Account) throws -> Bool {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw error("delete", status)
        }
    }

    private func baseQuery(for account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    private func error(_ operation: String, _ status: OSStatus) -> AppctlError {
        let reason = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
        return .keychainError(operation: operation, service: service, status: status, reason: reason)
    }
}
