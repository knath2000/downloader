import Foundation
import Security
import SwiftUI

enum NetworkConstants {
    static let chromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/125.0.0.0"

    static let webViewUserAgent = chromeUserAgent
}

enum SecureStore {
    private static let service = "com.pmvdl.app.secrets"

    static func data(forKey key: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func string(forKey key: String) -> String? {
        guard let data = data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ data: Data, forKey key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        let insert = query.merging(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func set(_ value: String, forKey key: String) -> Bool {
        set(Data(value.utf8), forKey: key)
    }

    static func remove(forKey key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func migrateLegacyString(_ legacyKey: String, to secureKey: String) {
        guard string(forKey: secureKey) == nil,
              let legacy = UserDefaults.standard.string(forKey: legacyKey),
              !legacy.isEmpty else { return }
        if set(legacy, forKey: secureKey) {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }
}

@propertyWrapper
struct SecureStringStorage: DynamicProperty {
    @State private var value: String
    private let key: String

    init(wrappedValue: String = "", _ key: String) {
        self.key = key
        SecureStore.migrateLegacyString(key, to: key)
        _value = State(initialValue: SecureStore.string(forKey: key) ?? wrappedValue)
    }

    var wrappedValue: String {
        get { value }
        nonmutating set {
            value = newValue
            if newValue.isEmpty {
                SecureStore.remove(forKey: key)
            } else {
                _ = SecureStore.set(newValue, forKey: key)
            }
        }
    }

    var projectedValue: Binding<String> { $value }
}

enum URLTrustPolicy {
    static func validated(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return isAllowed(url) ? url : nil
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), !host.isEmpty,
              !host.contains("%"), host != "localhost", !host.hasSuffix(".local") else {
            return false
        }

        if let address = IPv4Address(host) {
            return !address.isPrivate
        }
        if let address = IPv6Address(host) {
            return !address.isPrivate
        }
        return true
    }

    private struct IPv4Address {
        let octets: [UInt8]

        init?(_ host: String) {
            let parts = host.split(separator: ".")
            guard parts.count == 4,
                  parts.allSatisfy({ part in
                      guard let value = Int(part), (0...255).contains(value) else { return false }
                      return true
                  }) else { return nil }
            octets = parts.compactMap { UInt8($0) }
        }

        var isPrivate: Bool {
            guard octets.count == 4 else { return true }
            switch (octets[0], octets[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (172, 16...31), (192, 168): return true
            default: return false
            }
        }
    }

    private struct IPv6Address {
        let host: String

        init?(_ host: String) {
            guard host.contains(":"), host.count <= 45 else { return nil }
            self.host = host
        }

        var isPrivate: Bool {
            host == "::1" || host == "::" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
    }
}

enum MediaRequestHeaders {
    private static let allowed: Set<String> = [
        "accept", "accept-language", "range", "referer", "user-agent"
    ]

    static func sanitized(_ headers: [String: String]?) -> [String: String] {
        guard let headers else { return [:] }
        return headers.reduce(into: [String: String]()) { result, entry in
            if allowed.contains(entry.key.lowercased()) {
                result[entry.key] = entry.value
            }
        }
    }
}
