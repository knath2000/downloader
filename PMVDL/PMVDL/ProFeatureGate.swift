import Foundation

/// Enum-based feature gating. Pro features require a verified Stripe license.
@MainActor
struct ProFeatureGate {
    static var isPro: Bool { LicenseManager.shared.isPro }

    /// Batch operations > 5 items require Pro.
    static func canBatchDownload(count: Int) -> Bool {
        isPro || count <= 5
    }

    /// Upload to multiple cloud providers simultaneously requires Pro.
    static var canMultiUpload: Bool { isPro }

    /// More than 5 free downloads require Pro.
    static var trialNotExhausted: Bool { LicenseManager.shared.freeDownloadsRemaining > 0 }
}
