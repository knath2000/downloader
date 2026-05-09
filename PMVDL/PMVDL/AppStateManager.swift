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

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        NSApp.setActivationPolicy(policy)
    }

    func showMainWindow() {
        isMainWindowVisible = true
        NSApp.activate(ignoringOtherApps: true)
    }

    func select(_ destination: NavDestination) {
        selectedDestination = destination
    }
}
