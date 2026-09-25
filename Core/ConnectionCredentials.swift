import Foundation
import Security

/// Device-local user credentials. No API key is bundled, logged, or saved in UserDefaults.
enum ConnectionCredentials {
    private static let service = "com.gakonst.nanocad.nanocodex"

    // Keep concrete zero-argument overloads: existing callers also pass load as a closure.
    static func load() throws -> NanocodexCredentials? { try load(projectID: nil) }
    static func save(_ value: NanocodexCredentials) throws { try save(value, projectID: nil) }
    static func remove() throws { try remove(projectID: nil) }

    static func load(projectID: String?) throws -> NanocodexCredentials? {
        guard let value = try read(projectID: projectID) else { return nil }
        try validateScope(value, projectID: projectID)
        return try value.validated()
    }

    /// Only the non-secret conversation ID leaves Keychain during first-run migration.
    /// Expired grants still identify the same conversation when the user reconnects.
    static func legacyConversationID() throws -> String? {
        guard let conversation = try read(projectID: nil)?.connect?.conversationID else { return nil }
        guard UUID(uuidString: conversation) != nil else { throw NanocodexError.invalidReference }
        return conversation
    }

    static func save(_ value: NanocodexCredentials, projectID: String?) throws {
        try validateScope(value, projectID: projectID)
        let query = try baseQuery(projectID: projectID)
        let encoded = try JSONEncoder().encode(value)
        let changes: [String: Any] = [kSecValueData as String: encoded,
                                      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            changes.forEach { insert[$0.key] = $0.value }
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    static func remove(projectID: String?) throws {
        let status = SecItemDelete(try baseQuery(projectID: projectID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private static func read(projectID: String?) throws -> NanocodexCredentials? {
        var query = try baseQuery(projectID: projectID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(NanocodexCredentials.self, from: data)
    }

    private static func validateScope(_ value: NanocodexCredentials, projectID: String?) throws {
        guard let projectID, let grant = value.connect else { return }
        guard let project = UUID(uuidString: projectID),
              UUID(uuidString: grant.conversationID) == project else { throw NanocodexError.invalidReference }
    }

    private static func baseQuery(projectID: String?) throws -> [String: Any] {
        let account: String
        if let projectID {
            guard let id = UUID(uuidString: projectID) else { throw NanocodexError.invalidReference }
            account = "project-" + id.uuidString
        } else {
            account = "account-api"
        }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "The connection could not be saved in this device’s Keychain (\(status))." }
    }
}
