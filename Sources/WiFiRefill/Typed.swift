import Foundation
import Security

/// What the person typed into a taught page's fields, by step, kept in their login Keychain under the page it belongs
/// to, and only if they ticked Remember What I Type. Never in a recipe, the log, a report or a shared page.
enum Typed {
    static let service = "com.hweihwang.WiFiRefill.typed"

    /// Replaces what was kept for `page`; nothing typed removes it.
    static func save(_ values: [Int: String], page: String) {
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: page]
        SecItemDelete(item as CFDictionary)
        guard !values.isEmpty, let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: values.map { (String($0.key), $0.value) })) else { return }
        var added = item
        added[kSecValueData as String] = data
        added[kSecAttrLabel as String] = "Wi-Fi Refill: what you typed on a login page"
        added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(added as CFDictionary, nil)
        if status != errSecSuccess { Log.write("Could not keep what you typed in the Keychain (\(status)).") }
    }

    static func load(page: String) -> [Int: String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: page,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let values = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: values.compactMap { key, value in Int(key).map { ($0, value) } })
    }
}
