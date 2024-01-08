import Foundation
import Security

/// Stores the Miro token in the login keychain instead of UserDefaults.
enum Keychain {
    private static func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ocrsearch", kSecAttrAccount as String: key]
    }
    static func get(_ key: String) -> String? {
        var q = base(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ key: String, _ value: String) {
        SecItemDelete(base(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = base(key); q[kSecValueData as String] = value.data(using: .utf8)!
        SecItemAdd(q as CFDictionary, nil)
    }
}
