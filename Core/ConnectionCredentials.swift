import Foundation
import Security

/// Device-local user credentials. No API key is bundled, logged, or saved in UserDefaults.
enum ConnectionCredentials {
    private static let service = "com.gakonst.nanocad.nanocodex"
    private static let account = "account-api"

    static func load() throws -> NanocodexCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        let stored = try JSONDecoder().decode(NanocodexCredentials.self, from: data)
        return try NanocodexCredentials(origin: stored.origin, apiKey: stored.apiKey)
    }

    static func save(_ value: NanocodexCredentials) throws {
        let encoded = try JSONEncoder().encode(value)
        let changes: [String: Any] = [kSecValueData as String: encoded,
                                      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(baseQuery as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            changes.forEach { query[$0.key] = $0.value }
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    static func remove() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "The connection could not be saved in this device’s Keychain (\(status))." }
    }
}
