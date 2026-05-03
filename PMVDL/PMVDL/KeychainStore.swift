import Foundation
import Security

enum KeychainStore {
    private static let service = "com.pmvdl.viddl.license"

    static func getInt(_ account: String) -> Int? {
        guard let value = getString(account) else { return nil }
        return Int(value)
    }

    static func setInt(_ value: Int, account: String) {
        setString(String(value), account: account)
    }

    static func getString(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func setString(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query = baseQuery(account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func getBool(_ account: String) -> Bool? {
        guard let value = getString(account) else { return nil }
        return value == "true" ? true : (value == "false" ? false : nil)
    }

    static func setBool(_ value: Bool, account: String) {
        setString(value ? "true" : "false", account: account)
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
