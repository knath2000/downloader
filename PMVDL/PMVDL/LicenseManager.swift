import AppKit
import Foundation

struct LicenseStatusResponse: Decodable {
    let active: Bool
    let email: String?
    let status: String?
}

struct CheckoutResponse: Decodable {
    let url: String
}

@MainActor
class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    static let freeDownloadLimit = 5
    private static let baseURLKey = "licenseBackendBaseURL"
    private static let activationEmailKey = "licenseActivationEmail"
    private static let proActiveKey = "licenseProActive"
    private static let freeDownloadsUsedKey = "licenseFreeDownloadsUsed"

    @Published var isPro: Bool
    @Published var activationEmail: String
    @Published var freeDownloadsUsed: Int
    @Published var lastError: String = ""
    @Published var isChecking = false

    private init() {
        isPro = UserDefaults.standard.bool(forKey: Self.proActiveKey)
        activationEmail = UserDefaults.standard.string(forKey: Self.activationEmailKey) ?? ""
        freeDownloadsUsed = UserDefaults.standard.integer(forKey: Self.freeDownloadsUsedKey)
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
            request.httpBody = try JSONSerialization.data(withJSONObject: ["email": normalized])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw LicenseError.serverRejected
            }

            let checkout = try JSONDecoder().decode(CheckoutResponse.self, from: data)
            guard let url = URL(string: checkout.url) else { throw LicenseError.invalidCheckoutURL }
            activationEmail = normalized
            UserDefaults.standard.set(normalized, forKey: Self.activationEmailKey)
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
        UserDefaults.standard.set(normalized, forKey: Self.activationEmailKey)
        return await refreshLicense()
    }

    func refreshLicense() async -> Bool {
        let normalized = normalize(activationEmail)
        guard !normalized.isEmpty else {
            isPro = false
            UserDefaults.standard.set(false, forKey: Self.proActiveKey)
            return false
        }
        guard var components = URLComponents(url: backendBaseURL?.appendingPathComponent("license") ?? URL(fileURLWithPath: ""), resolvingAgainstBaseURL: false) else {
            lastError = "License server is not configured."
            return false
        }
        components.queryItems = [URLQueryItem(name: "email", value: normalized)]
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
            UserDefaults.standard.set(isPro, forKey: Self.proActiveKey)
            UserDefaults.standard.set(activationEmail, forKey: Self.activationEmailKey)
            lastError = status.active ? "" : (status.status ?? "No active Pro license found.")
            return status.active
        } catch {
            isPro = false
            UserDefaults.standard.set(false, forKey: Self.proActiveKey)
            lastError = error.localizedDescription
            return false
        }
    }

    func recordSuccessfulDownload() {
        guard !isPro else { return }
        freeDownloadsUsed = min(Self.freeDownloadLimit, freeDownloadsUsed + 1)
        UserDefaults.standard.set(freeDownloadsUsed, forKey: Self.freeDownloadsUsedKey)
    }

    func handleLicenseSuccess(email: String?) {
        if let email {
            activationEmail = normalize(email)
            UserDefaults.standard.set(activationEmail, forKey: Self.activationEmailKey)
        }
        Task { await refreshLicense() }
    }

    func deactivateLocalLicense() {
        isPro = false
        activationEmail = ""
        UserDefaults.standard.removeObject(forKey: Self.activationEmailKey)
        UserDefaults.standard.set(false, forKey: Self.proActiveKey)
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
