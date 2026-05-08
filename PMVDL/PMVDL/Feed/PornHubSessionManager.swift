import Foundation
import WebKit

@MainActor
final class PornHubSessionManager: ObservableObject {
    static let shared = PornHubSessionManager()
    private static let cookieKey = "pornhubCookies"

    @Published var isLoggedIn = false

    private init() {
        restorePersistedCookies()
        isLoggedIn = hasPornHubSessionCookie()
    }

    func syncFromWebView() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        let pornhubCookies = cookies.filter { $0.domain.contains("pornhub.com") }
        pornhubCookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
        persistCookies(pornhubCookies)
        isLoggedIn = hasPornHubSessionCookie()
    }

    func logout() {
        HTTPCookieStorage.shared.cookies?
            .filter { $0.domain.contains("pornhub.com") }
            .forEach { HTTPCookieStorage.shared.deleteCookie($0) }

        Task {
            let store = WKWebsiteDataStore.default().httpCookieStore
            for cookie in await store.allCookies() where cookie.domain.contains("pornhub.com") {
                await store.deleteCookie(cookie)
            }
        }

        UserDefaults.standard.removeObject(forKey: Self.cookieKey)
        isLoggedIn = false
    }

    private func hasPornHubSessionCookie() -> Bool {
        HTTPCookieStorage.shared.cookies?.contains {
            $0.domain.contains("pornhub.com") && $0.name == "il"
        } ?? false
    }

    private func persistCookies(_ cookies: [HTTPCookie]) {
        let properties = cookies.compactMap { cookie -> [String: Any]? in
            guard let cookieProperties = cookie.properties else { return nil }
            return cookieProperties.reduce(into: [String: Any]()) { output, element in
                output[element.key.rawValue] = element.value
            }
        }
        if let encoded = try? NSKeyedArchiver.archivedData(withRootObject: properties, requiringSecureCoding: false) {
            UserDefaults.standard.set(encoded, forKey: Self.cookieKey)
        }
    }

    private func restorePersistedCookies() {
        let classes: [AnyClass] = [NSArray.self, NSDictionary.self, NSString.self, NSNumber.self, NSDate.self, NSURL.self]
        guard let data = UserDefaults.standard.data(forKey: Self.cookieKey),
              let propertiesList = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? [[String: Any]] else {
            return
        }

        for storedProperties in propertiesList {
            let properties = storedProperties.reduce(into: [HTTPCookiePropertyKey: Any]()) { output, element in
                output[HTTPCookiePropertyKey(rawValue: element.key)] = element.value
            }
            if let cookie = HTTPCookie(properties: properties) {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }
}
