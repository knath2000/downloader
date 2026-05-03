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

@MainActor
class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    static let freeDownloadLimit = 5
    private static let baseURLKey = "licenseBackendBaseURL"
    private static let activationEmailKey = "licenseActivationEmail"
    private static let proActiveKey = "licenseProActive"
    private static let freeDownloadsUsedKey = "licenseFreeDownloadsUsed"
    private static let trialHMACSecretKey = "licenseTrialHMACSecret"
    private static let keychainFreeUsedAccount = "freeUsed"
    private static let keychainIsProAccount = "isPro"
    private static let keychainActivationEmailAccount = "activationEmail"
    private static let keychainRedeemedHwidAccount = "redeemedHwid"
    private static let keychainTrialSyncedAccount = "trialSynced"

    @Published var isPro: Bool
    @Published var activationEmail: String
    @Published var freeDownloadsUsed: Int
    @Published var lastError: String = ""
    @Published var isChecking = false
    @Published private(set) var trialSynced: Bool

    private let hwid = HardwareID.current

    private init() {
        if KeychainStore.getInt(Self.keychainFreeUsedAccount) == nil {
            let legacyEmail = UserDefaults.standard.string(forKey: Self.activationEmailKey) ?? ""
            KeychainStore.setInt(0, account: Self.keychainFreeUsedAccount)
            KeychainStore.setBool(false, account: Self.keychainIsProAccount)
            KeychainStore.setBool(false, account: Self.keychainTrialSyncedAccount)
            KeychainStore.setString(hwid, account: Self.keychainRedeemedHwidAccount)
            if !legacyEmail.isEmpty {
                KeychainStore.setString(
                    legacyEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                    account: Self.keychainActivationEmailAccount
                )
            }
            UserDefaults.standard.removeObject(forKey: Self.freeDownloadsUsedKey)
            UserDefaults.standard.removeObject(forKey: Self.proActiveKey)
            UserDefaults.standard.removeObject(forKey: Self.activationEmailKey)
        }

        isPro = KeychainStore.getBool(Self.keychainIsProAccount) ?? false
        activationEmail = KeychainStore.getString(Self.keychainActivationEmailAccount) ?? ""
        freeDownloadsUsed = KeychainStore.getInt(Self.keychainFreeUsedAccount) ?? 0
        trialSynced = KeychainStore.getBool(Self.keychainTrialSyncedAccount) ?? false
    }

    var freeDownloadsRemaining: Int {
        max(0, Self.freeDownloadLimit - freeDownloadsUsed)
    }

    var backendBaseURL: URL? {
        let configured = UserDefaults.standard.string(forKey: Self.baseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "https://pmvdl-license.knath2000.workers.dev"
        return URL(string: configured?.isEmpty == false ? configured! : fallback)
    }

    func canStartDownload(count: Int = 1) -> Bool {
        isPro || freeDownloadsRemaining >= count
    }

    func bootstrap() async {
        do {
            let status: TrialSyncResponse = try await postTrial("sync")
            applyTrialState(count: status.count, isPro: status.isPro, redeemedEmail: status.redeemedEmail, markSynced: true)
            if !activationEmail.isEmpty {
                _ = await refreshLicense()
            }
        } catch {
            if !activationEmail.isEmpty {
                _ = await refreshLicense()
            }
        }
    }

    func preflight(count: Int = 1) async -> Bool {
        if isPro { return true }
        do {
            let status: TrialSyncResponse = try await postTrial("sync")
            applyTrialState(count: status.count, isPro: status.isPro, redeemedEmail: status.redeemedEmail, markSynced: true)
            if isPro || status.isPro { return true }
            let used = status.count ?? freeDownloadsUsed
            return max(0, Self.freeDownloadLimit - used) >= count
        } catch {
            guard trialSynced else {
                lastError = "Connect to the internet once before using free downloads."
                return false
            }
            return canStartDownload(count: count)
        }
    }

    func startCheckout(email: String) async -> Bool {
        let normalized = normalize(email)
        guard !normalized.isEmpty else {
            lastError = "Enter the email you want to use for Pro."
            return false
        }
        guard let endpoint = backendBaseURL?.appendingPathComponent("checkout") else {
            lastError = "License server is not configured."
            return false
        }

        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body = signedTrialBody()
            body["email"] = normalized
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw LicenseError.serverRejected
            }

            let checkout = try JSONDecoder().decode(CheckoutResponse.self, from: data)
            guard let url = URL(string: checkout.url) else { throw LicenseError.invalidCheckoutURL }
            activationEmail = normalized
            KeychainStore.setString(normalized, account: Self.keychainActivationEmailAccount)
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
        KeychainStore.setString(normalized, account: Self.keychainActivationEmailAccount)
        return await refreshLicense()
    }

    func refreshLicense() async -> Bool {
        let normalized = normalize(activationEmail)
        guard !normalized.isEmpty else {
            isPro = false
            KeychainStore.setBool(false, account: Self.keychainIsProAccount)
            return false
        }
        guard var components = URLComponents(url: backendBaseURL?.appendingPathComponent("license") ?? URL(fileURLWithPath: ""), resolvingAgainstBaseURL: false) else {
            lastError = "License server is not configured."
            return false
        }
        components.queryItems = [
            URLQueryItem(name: "email", value: normalized),
            URLQueryItem(name: "hwid", value: hwid)
        ]
        guard let url = components.url else {
            lastError = "License server is not configured."
            return false
        }

        isChecking = true
        defer { isChecking = false }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw LicenseError.serverRejected
            }
            let status = try JSONDecoder().decode(LicenseStatusResponse.self, from: data)
            isPro = status.active
            activationEmail = status.email ?? normalized
            KeychainStore.setBool(isPro, account: Self.keychainIsProAccount)
            KeychainStore.setString(activationEmail, account: Self.keychainActivationEmailAccount)
            lastError = status.active ? "" : (status.status ?? "No active Pro license found.")
            return status.active
        } catch {
            lastError = error.localizedDescription
            return isPro
        }
    }

    @discardableResult
    func recordSuccessfulDownload() async -> Bool {
        guard !isPro else { return true }
        do {
            let status: TrialUseResponse = try await postTrial("use")
            applyTrialState(count: status.count, isPro: status.isPro, redeemedEmail: nil, markSynced: true)
            if status.allowed || status.isPro {
                lastError = ""
                return true
            }
            setFreeDownloadsUsed(Self.freeDownloadLimit)
            lastError = "Free download limit reached."
            return false
        } catch {
            if isPro || KeychainStore.getBool(Self.keychainIsProAccount) == true {
                return true
            }
            guard trialSynced else {
                lastError = "Connect to the internet once before using free downloads."
                return false
            }
            guard freeDownloadsUsed < Self.freeDownloadLimit else {
                lastError = "Free download limit reached."
                return false
            }
            setFreeDownloadsUsed(freeDownloadsUsed + 1)
            return true
        }
    }

    func handleLicenseSuccess(email: String?) {
        if let email {
            activationEmail = normalize(email)
            KeychainStore.setString(activationEmail, account: Self.keychainActivationEmailAccount)
        }
        Task { await refreshLicense() }
    }

    func deactivateLocalLicense() {
        isPro = false
        activationEmail = ""
        KeychainStore.delete(Self.keychainActivationEmailAccount)
        KeychainStore.setBool(false, account: Self.keychainIsProAccount)
    }

    private func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func applyTrialState(count: Int?, isPro serverIsPro: Bool, redeemedEmail: String?, markSynced: Bool) {
        if let count {
            setFreeDownloadsUsed(min(Self.freeDownloadLimit, max(0, count)))
        }
        if serverIsPro {
            isPro = true
            KeychainStore.setBool(true, account: Self.keychainIsProAccount)
        }
        if let redeemedEmail, !redeemedEmail.isEmpty {
            activationEmail = normalize(redeemedEmail)
            KeychainStore.setString(activationEmail, account: Self.keychainActivationEmailAccount)
        }
        if markSynced {
            trialSynced = true
            KeychainStore.setBool(true, account: Self.keychainTrialSyncedAccount)
        }
    }

    private func setFreeDownloadsUsed(_ value: Int) {
        freeDownloadsUsed = min(Self.freeDownloadLimit, max(0, value))
        KeychainStore.setInt(freeDownloadsUsed, account: Self.keychainFreeUsedAccount)
    }

    private func postTrial<T: Decodable>(_ action: String) async throws -> T {
        guard let endpoint = backendBaseURL?
            .appendingPathComponent("trial")
            .appendingPathComponent(action) else {
            throw LicenseError.serverRejected
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: signedTrialBody())

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LicenseError.serverRejected
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func signedTrialBody() -> [String: Any] {
        let timestamp = Int(Date().timeIntervalSince1970)
        return [
            "hwid": hwid,
            "ts": timestamp,
            "sig": trialSignature(timestamp: timestamp)
        ]
    }

    private func trialSignature(timestamp: Int) -> String {
        let payload = "\(hwid).\(timestamp)"
        let key = SymmetricKey(data: Data(trialHMACSecret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    private var trialHMACSecret: String {
        if let value = UserDefaults.standard.string(forKey: Self.trialHMACSecretKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "VIDDL_TRIAL_HMAC_SECRET") as? String,
           !value.isEmpty,
           !value.hasPrefix("$(") {
            return value
        }
        return "viddl-trial-development-secret"
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
