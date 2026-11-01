import Foundation
import Security
import DictidyKit

/// Provider keys use separate accounts; the existing Anthropic account is retained unchanged.
enum KeychainService {
    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Couldn't update credentials in Keychain: " + (SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")
        }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.opensource.dictidy",
         kSecAttrAccount as String: account]
    }

    static func save(_ key: String, provider: RewriteProvider) throws {
        try save(Data(key.utf8), account: provider.rawValue + "-api-key")
    }

    static func save(_ data: Data, account: String) throws {
        let base = query(account)
        let value = [kSecValueData as String: data]
        var status = SecItemUpdate(base as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var attrs = base
            attrs[kSecValueData as String] = data
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(attrs as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func load(provider: RewriteProvider) -> String? {
        load(account: provider.rawValue + "-api-key").flatMap { String(data: $0, encoding: .utf8) }
    }

    static func load(account: String) -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    /// Check presence without decrypting the key or asking for authorization at launch.
    static func exists(provider: RewriteProvider) -> Bool {
        exists(account: provider.rawValue + "-api-key")
    }

    static func exists(account: String) -> Bool {
        SecItemCopyMatching(query(account) as CFDictionary, nil) == errSecSuccess
    }

    static func delete(provider: RewriteProvider) throws {
        try delete(account: provider.rawValue + "-api-key")
    }

    static func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
