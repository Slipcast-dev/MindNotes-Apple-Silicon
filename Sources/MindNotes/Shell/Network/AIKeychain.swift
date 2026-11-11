import Foundation
import Security

/// Ключ API ИИ — только в Keychain (FR-AI-1): не попадает в базу, настройки, резервные копии и журналы.
enum AIKeychain {
    private static let service = "MindNotes AI"

    /// Свой ключ у каждого провайдера; у Anthropic — прежнее имя записи, чтобы сохранённый ключ не пропал.
    private static func account(_ provider: String) -> String {
        provider == "anthropic" ? "anthropic-api-key" : "api-key-" + provider
    }

    private static func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account(provider)]
    }

    static func read(provider: String) -> String? {
        var q = query(provider)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasKey(provider: String) -> Bool { read(provider: provider)?.isEmpty == false }

    @discardableResult
    static func save(_ key: String, provider: String) -> Bool {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return delete(provider: provider) }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = query(provider)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(provider: String) -> Bool {
        let status = SecItemDelete(query(provider) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
