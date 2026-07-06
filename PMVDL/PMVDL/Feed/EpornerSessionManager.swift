import Foundation
import WebKit

@MainActor
final class EpornerSessionManager: ObservableObject {
    static let shared = EpornerSessionManager()
    private static let cookieKey = "epornerCookies"
    private static let sessionCookieNames: Set<String> = [
        "epuser",
        "epuserid",
        "userhash",
        "auth",
        "wsid",
        "auth_token",
        "eptoken"
    ]

    @Published var isLoggedIn = false

    private init() {
        restorePersistedCookies()
        isLoggedIn = hasSessionCookie()
    }

    func syncFromWebView() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        let epornerCookies = cookies.filter { $0.domain.contains("eporner.com") }
        epornerCookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
        persistCookies(epornerCookies)
        let cookieLogin = hasSessionCookie()
        let probeLogin = await probeLoggedIn()
#if DEBUG
        print("[eporner] cookies after sync:", epornerCookies.map { "\($0.name)=\($0.domain)" })
        print("[eporner] cookieLogin=", cookieLogin, "probeLogin=", probeLogin)
#endif
        isLoggedIn = cookieLogin || probeLogin
    }

    func logout() {
        HTTPCookieStorage.shared.cookies?
            .filter { $0.domain.contains("eporner.com") }
            .forEach { HTTPCookieStorage.shared.deleteCookie($0) }

        Task {
            let store = WKWebsiteDataStore.default().httpCookieStore
            for cookie in await store.allCookies() where cookie.domain.contains("eporner.com") {
                await store.deleteCookie(cookie)
            }
        }

        UserDefaults.standard.removeObject(forKey: Self.cookieKey)
        isLoggedIn = false
    }

    private func hasSessionCookie() -> Bool {
        HTTPCookieStorage.shared.cookies?.contains {
            $0.domain.contains("eporner.com") && Self.sessionCookieNames
                .contains($0.name.lowercased())
        } ?? false
    }

    private func probeLoggedIn() async -> Bool {
        let probeURLs = [
            "https://www.eporner.com/my-subscriptions/",
            "https://www.eporner.com/my-subscriptions/?type=channels",
            "https://www.eporner.com/my-likes/",
            "https://www.eporner.com/my-favourites/",
            "https://www.eporner.com/watch-later/",
            "https://www.eporner.com/history/"
        ]

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        let session = URLSession(configuration: configuration)

        for probeURLString in probeURLs {
            guard let probeURL = URL(string: probeURLString) else { continue }
            var request = URLRequest(url: probeURL)
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.httpShouldHandleCookies = true

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                guard (200...299).contains(http.statusCode) else { continue }
                let html = String(data: data, encoding: .utf8) ?? ""
                if html.contains("EP.user.login=true") || html.contains("EP.user.logged=true") {
                    return true
                }
                if html.contains("EP.user.login=false") || html.contains("EP.user.logged=false") {
                    return false
                }
            } catch {
                continue
            }
        }

        return false
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
