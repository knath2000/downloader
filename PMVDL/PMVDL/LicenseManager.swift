import AppKit
import CryptoKit
import Foundation

struct LicenseStatusResponse: Decodable {
    let active: Bool
    let email: String?
    let status: String?
}

struct CheckoutResponse: Decodable {
    let url: String
}

struct TrialSyncResponse: Decodable {
    let count: Int?
    let isPro: Bool
    let redeemedEmail: String?
}

struct TrialUseResponse: Decodable {
    let count: Int?
    let remaining: Int?
    let allowed: Bool
    let isPro: Bool
}

private struct EntitlementCache: Codable {
    let isPro: Bool
    let email: String
    let hardwareID: String
    let verifiedAt: Date
    let expiresAt: Date
}

enum PersonalLicenseConfig {
    static let bootstrapCode = "VIDDL-LOCAL-633D52B5-3F6C-4E42-8159-A9B627D55A6E"
    static let codeKey = "personal.license.codeHash"
    static let activeKey = "personal.license.active"
}

enum PersonalLicenseCode {
    static func hash(_ code: String) -> String {
        SHA256.hash(data: Data(code.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func generate() -> String {
        "VIDDL-LOCAL-" + UUID().uuidString
    }
}

@MainActor
class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    nonisolated static let freeDownloadLimit = 3
    private nonisolated static let entitlementCacheKey = "license.entitlement.cache"
    private static let userDefaultsFreeUsedKey = "licenseFreeUsed"
    private static let userDefaultsActivationEmailKey = "licenseActivationEmail"
    private static let legacyKeys = [
        "licenseIsPro", "licenseTrialSynced", "licenseRedeemedHwid", "licenseTrialHMACSecret", "licenseBackendBaseURL"
    ]

    @Published var isPro: Bool
    @Published var activationEmail: String
    @Published var freeDownloadsUsed: Int
    @Published var lastError: String = ""
    @Published var isChecking = false

    private let hwid: String
    private let offlineGrace: TimeInterval

    nonisolated static var storedIsPro: Bool {
        if SecureStore.string(forKey: PersonalLicenseConfig.activeKey) == "true" {
            return true
        }
        guard let data = SecureStore.data(forKey: entitlementCacheKey),
              let cache = try? JSONDecoder().decode(EntitlementCache.self, from: data) else { return false }
        return cache.isPro && cache.hardwareID == HardwareID.current && cache.expiresAt > Date()
    }

    private init() {
        self.hwid = HardwareID.current
        self.offlineGrace = 7 * 24 * 60 * 60
        self.isPro = false
        self.activationEmail = ""
        self.freeDownloadsUsed = 0
        migrateLegacyState()
        let cached = Self.loadCache()
        let localLicenseActive = SecureStore.string(forKey: PersonalLicenseConfig.activeKey) == "true"
        isPro = localLicenseActive || (cached.map { $0.isPro && $0.hardwareID == hwid && $0.expiresAt > Date() } ?? false)
        activationEmail = localLicenseActive ? "Personal license" : (cached?.email ?? UserDefaults.standard.string(forKey: Self.userDefaultsActivationEmailKey) ?? "")
        freeDownloadsUsed = UserDefaults.standard.integer(forKey: Self.userDefaultsFreeUsedKey)
    }

    var freeDownloadsRemaining: Int {
        max(0, Self.freeDownloadLimit - freeDownloadsUsed)
    }

    func canStartDownload(count: Int = 1) -> Bool {
        isPro || freeDownloadsRemaining >= count
    }

    func bootstrap() async {
        guard !isPro else { return }
    }

    func preflight(count: Int = 1) async -> Bool {
        if isPro { return true }
        guard freeDownloadsRemaining >= count else {
            lastError = "Free download limit reached."
            return false
        }
        return true
    }

    func startCheckout(email: String) async -> Bool {
        let normalized = normalize(email)
        guard !normalized.isEmpty, let endpoint = endpoint("checkout") else {
            lastError = "Enter a valid email for Pro."
            return false
        }

        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["email": normalized, "hwid": hwid])
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response)
            let checkout = try JSONDecoder().decode(CheckoutResponse.self, from: data)
            guard let url = URL(string: checkout.url), url.scheme == "https" else { throw LicenseError.invalidCheckoutURL }
            activationEmail = normalized
            UserDefaults.standard.set(normalized, forKey: Self.userDefaultsActivationEmailKey)
            NSWorkspace.shared.open(url)
            lastError = ""
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func activate(email: String) async -> Bool {
        let normalized = normalize(email)
        guard !normalized.isEmpty else {
            lastError = "Enter the email used at checkout."
            return false
        }
        activationEmail = normalized
        UserDefaults.standard.set(normalized, forKey: Self.userDefaultsActivationEmailKey)
        return await refreshLicense()
    }

    func refreshLicense() async -> Bool {
        let normalized = normalize(activationEmail)
        guard !normalized.isEmpty, let endpoint = endpoint("license/status") else {
            isPro = false
            clearCache()
            return false
        }

        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["email": normalized, "hwid": hwid])
            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response)
            let status = try JSONDecoder().decode(LicenseStatusResponse.self, from: data)
            if status.active {
                activationEmail = status.email ?? normalized
                isPro = true
                storeCache(email: activationEmail)
                lastError = ""
                return true
            }
            isPro = false
            clearCache()
            lastError = status.status ?? "No active Pro license found."
            return false
        } catch {
            let cache = Self.loadCache()
            isPro = cache.map { $0.isPro && $0.hardwareID == hwid && $0.expiresAt > Date() } ?? false
            lastError = isPro ? "License service unavailable; using offline verification." : error.localizedDescription
            return isPro
        }
    }

    @discardableResult
    func recordSuccessfulDownload() async -> Bool {
        guard !isPro else { return true }
        guard freeDownloadsRemaining > 0 else {
            lastError = "Free download limit reached."
            return false
        }
        setFreeDownloadsUsed(freeDownloadsUsed + 1)
        lastError = ""
        return true
    }

    func activatePersonal(code: String) -> String? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            lastError = "Enter your personal activation code."
            return nil
        }

        let enteredHash = PersonalLicenseCode.hash(normalized)
        let expectedHash = SecureStore.string(forKey: PersonalLicenseConfig.codeKey)
            ?? PersonalLicenseCode.hash(PersonalLicenseConfig.bootstrapCode)
        guard enteredHash == expectedHash else {
            lastError = "That activation code is not valid."
            return nil
        }

        let replacement = PersonalLicenseCode.generate()
        guard SecureStore.set(PersonalLicenseCode.hash(replacement), forKey: PersonalLicenseConfig.codeKey),
              SecureStore.set("true", forKey: PersonalLicenseConfig.activeKey) else {
            lastError = "Could not save the personal license on this Mac."
            return nil
        }

        isPro = true
        activationEmail = "Personal license"
        lastError = ""
        return replacement
    }

    func handleLicenseSuccess(email: String?) {
        if let email, !email.isEmpty {
            activationEmail = normalize(email)
            UserDefaults.standard.set(activationEmail, forKey: Self.userDefaultsActivationEmailKey)
        }
        Task { await refreshLicense() }
    }

    func deactivateLocalLicense() {
        isPro = false
        activationEmail = ""
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsActivationEmailKey)
        SecureStore.remove(forKey: PersonalLicenseConfig.activeKey)
        clearCache()
    }

    private func applyTrialState(count: Int?, isPro serverIsPro: Bool, redeemedEmail: String?) {
        if let count { setFreeDownloadsUsed(count) }
        if serverIsPro {
            isPro = true
            if let redeemedEmail, !redeemedEmail.isEmpty { activationEmail = normalize(redeemedEmail) }
            storeCache(email: activationEmail)
        }
    }

    private func setFreeDownloadsUsed(_ value: Int) {
        freeDownloadsUsed = min(Self.freeDownloadLimit, max(0, value))
        UserDefaults.standard.set(freeDownloadsUsed, forKey: Self.userDefaultsFreeUsedKey)
    }

    private func postTrial<T: Decodable>(_ action: String) async throws -> T {
        guard let endpoint = endpoint("trial/\(action)") else { throw LicenseError.serverRejected }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["hwid": hwid])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func endpoint(_ path: String) -> URL? {
        URL(string: "https://pmvdl-license.knath2000.workers.dev")?.appendingPathComponent(path)
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LicenseError.serverRejected
        }
    }

    private func storeCache(email: String) {
        let now = Date()
        let cache = EntitlementCache(isPro: true, email: email, hardwareID: hwid, verifiedAt: now, expiresAt: now.addingTimeInterval(offlineGrace))
        if let data = try? JSONEncoder().encode(cache) { _ = SecureStore.set(data, forKey: Self.entitlementCacheKey) }
    }

    private func clearCache() {
        SecureStore.remove(forKey: Self.entitlementCacheKey)
    }

    private static func loadCache() -> EntitlementCache? {
        guard let data = SecureStore.data(forKey: entitlementCacheKey) else { return nil }
        return try? JSONDecoder().decode(EntitlementCache.self, from: data)
    }

    private func migrateLegacyState() {
        SecureStore.migrateLegacyString("seedboxWebdavPassword", to: "seedboxWebdavPassword")
        for key in Self.legacyKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum LicenseError: LocalizedError {
    case serverRejected
    case invalidCheckoutURL

    var errorDescription: String? {
        switch self {
        case .serverRejected: return "License server rejected the request."
        case .invalidCheckoutURL: return "Checkout URL was invalid."
        }
    }
}
