import Foundation

/// Enum-based feature gating. Pro features require a valid Paddle license.
@MainActor
struct ProFeatureGate {
    static var isPro: Bool { PaddleManager.shared.isActivated }

    /// Batch operations > 5 items require Pro.
    static func canBatchDownload(count: Int) -> Bool {
        isPro || count <= 5
    }

    /// Scheduling downloads requires Pro.
    static var canUseScheduler: Bool { isPro }

    /// Upload to multiple cloud providers simultaneously requires Pro.
    static var canMultiUpload: Bool { isPro }

    /// More than 10 trial downloads require Pro.
    static var trialNotExhausted: Bool { !PaddleManager.shared.trialExhausted }
}
