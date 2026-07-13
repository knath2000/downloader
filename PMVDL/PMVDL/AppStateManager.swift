import AppKit
import SwiftUI

@MainActor
class AppStateManager: ObservableObject {
    static let shared = AppStateManager()

    @Published var selectedDestination: NavDestination = .home
    @Published var isMainWindowVisible: Bool = true
    @Published var windowSize: CGSize = CGSize(width: 900, height: 650)
    @Published var pendingExtractURL: String?
    @Published var pendingExtractShouldStart = false
    @Published var pendingExtractThumbnailURL: String?
    @Published var pendingLibraryItemID: UUID?
    @Published var pendingFeedNavigation: FeedNavigationRequest?
    @Published var transientMessage: AppTransientMessage?

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        NSApp.setActivationPolicy(policy)
    }

    func showMainWindow() {
        isMainWindowVisible = true
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
    }

    func select(_ destination: NavDestination) {
        selectedDestination = destination
    }

    func openFeedSource(for item: DownloadQueueItem) {
        do {
            pendingFeedNavigation = try FeedSourceNavigation.request(for: item)
            select(.feed)
        } catch {
            transientMessage = AppTransientMessage(text: error.localizedDescription)
        }
    }
}

struct AppTransientMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

struct FeedNavigationRequest: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let site: FeedBrowserSite
}

enum FeedSourceNavigationError: LocalizedError {
    case originalPageUnavailable
    case unsupportedSource

    var errorDescription: String? {
        switch self {
        case .originalPageUnavailable:
            return "The original video page is unavailable for this download."
        case .unsupportedSource:
            return "This video page is not supported by the Feed browser."
        }
    }
}

enum FeedSourceNavigation {
    static func request(for item: DownloadQueueItem) throws -> FeedNavigationRequest {
        let rawURL = item.sourcePageURL
        guard let rawURL,
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw FeedSourceNavigationError.originalPageUnavailable
        }

        guard let site = FeedBrowserSite.allCases.first(where: { $0.allows(url) }) else {
            throw FeedSourceNavigationError.unsupportedSource
        }

        return FeedNavigationRequest(url: url, site: site)
    }
}
