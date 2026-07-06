import Foundation

/// Enum-based feature gating. Pro features require a verified Stripe license.
@MainActor
struct ProFeatureGate {
    static let freeBatchLimit = 5
    static let freeConcurrentDownloadLimit = 2
    static let proConcurrentDownloadLimit = 5

    static var isPro: Bool { LicenseManager.shared.isPro }
    nonisolated static var storedIsPro: Bool { LicenseManager.storedIsPro }

    /// Batch operations above the free batch limit require Pro.
    static func canBatchDownload(count: Int) -> Bool {
        isPro || count <= freeBatchLimit
    }

    /// Upload to multiple cloud providers simultaneously requires Pro.
    static var canMultiUpload: Bool { isPro }

    /// Higher concurrent download limits require Pro.
    static var canDownloadConcurrent: Bool { isPro }

    static var canDownloadAudio: Bool { isPro }
    static var canDownloadSubtitles: Bool { isPro }
    static var canUseFeed: Bool { isPro }
    static var canUseFavorites: Bool { isPro }

    nonisolated static var canDownloadAudioInBackground: Bool { storedIsPro }
    nonisolated static var canDownloadSubtitlesInBackground: Bool { storedIsPro }

    static var concurrentDownloadLimit: Int {
        canDownloadConcurrent ? proConcurrentDownloadLimit : freeConcurrentDownloadLimit
    }

    static func canAccess(_ destination: NavDestination) -> Bool {
        switch destination {
        case .feed:
            return canUseFeed
        case .home, .library, .settings:
            return true
        }
    }

    /// Free downloads after the trial allotment require Pro.
    static var trialNotExhausted: Bool { LicenseManager.shared.freeDownloadsRemaining > 0 }
}
