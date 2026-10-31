import Foundation
import Security

/// The Anthropic API key, kept in the login keychain rather than in settings.json.
public enum APIKeyStore {
    static let SERVICE = "io.github.pieralukasz.echopad"
    static let ACCOUNT = "anthropic-api-key"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: SERVICE,
         kSecAttrAccount as String: ACCOUNT]
    }

    public static func load() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = Data(trimmed.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
