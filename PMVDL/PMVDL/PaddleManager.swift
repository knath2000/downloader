import Foundation
import SwiftUI

/// Placeholder for Paddle SDK integration.
/// Replace stubs with actual Paddle v7 calls once the SDK is obtained from your Paddle dashboard.
/// Download: https://vendor.paddle.com/settings/sdk
@MainActor
class PaddleManager: ObservableObject {
    static let shared = PaddleManager()

    @Published var isActivated: Bool = UserDefaults.standard.bool(forKey: "paddle_activated")
    @Published var activationEmail: String = UserDefaults.standard.string(forKey: "paddle_email") ?? ""
    @Published var licenseKey: String = UserDefaults.standard.string(forKey: "paddle_license") ?? ""
    var trialDownloadsRemaining: Int {
        max(0, 10 - UserDefaults.standard.integer(forKey: "trial_downloads_used"))
    }

    private init() {}

    /// Activate a license key. Replace with: `Paddle.sharedInstance().activateProduct(...)`
    func activate(email: String, licenseKey: String) async -> Bool {
        // TODO: Paddle SDK v7 integration:
        // let result = await Paddle.shared.activateLicense(
        //     email: email, licenseKey: licenseKey,
        //     productID: Self.productId, vendorID: Self.vendorId
        // )
        // isActivated = result.success
        // self.activationEmail = email
        // self.licenseKey = licenseKey
        // UserDefaults.standard.set(email, forKey: "paddle_email")
        // UserDefaults.standard.set(licenseKey, forKey: "paddle_license")
        // UserDefaults.standard.set(result.success, forKey: "paddle_activated")

        // Stub: accept any non-empty key
        guard !email.isEmpty, !licenseKey.isEmpty else { return false }
        guard licenseKey.count >= 10 else { return false }
        self.activationEmail = email
        self.licenseKey = licenseKey
        isActivated = true
        UserDefaults.standard.set(email, forKey: "paddle_email")
        UserDefaults.standard.set(licenseKey, forKey: "paddle_license")
        UserDefaults.standard.set(true, forKey: "paddle_activated")
        return true
    }

    /// Deactivate the current license.
    func deactivate() {
        // TODO: Paddle.sharedInstance().deactivateLicense()
        isActivated = false
        activationEmail = ""
        licenseKey = ""
        UserDefaults.standard.removeObject(forKey: "paddle_email")
        UserDefaults.standard.removeObject(forKey: "paddle_license")
        UserDefaults.standard.removeObject(forKey: "paddle_activated")
    }

    /// Consume one trial download.
    func consumeTrialDownload() {
        let used = UserDefaults.standard.integer(forKey: "trial_downloads_used") + 1
        UserDefaults.standard.set(used, forKey: "trial_downloads_used")
    }

    /// Whether the user has exhausted their trial.
    var trialExhausted: Bool { trialDownloadsRemaining <= 0 }

    // Paddle vendor/product IDs — update these from your dashboard.
    static let vendorId = "12345"
    static let productId = "67890"
    static let publicKey = """
    -----BEGIN PUBLIC KEY-----
    REPLACE_WITH_YOUR_PADDLE_PUBLIC_KEY
    -----END PUBLIC KEY-----
    """
}
