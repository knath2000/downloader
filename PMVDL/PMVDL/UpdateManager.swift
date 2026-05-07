import Combine
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateManager()

    @Published var isChecking = false
    @Published var latestVersion: String?
    @Published var lastError: String?
    @Published var statusMessage: String?

    private var controller: SPUStandardUpdaterController!
    private var queueCancellable: AnyCancellable?
    private var pendingInstallHandler: (() -> Void)?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        queueCancellable = DownloadQueue.shared.$queue.sink { [weak self] _ in
            self?.resumePendingInstallIfPossible()
        }
    }

    func checkForUpdates() {
        guard !hasActiveQueueWork else {
            statusMessage = "Finish or pause active downloads before updating."
            lastError = statusMessage
            return
        }

        isChecking = true
        latestVersion = nil
        lastError = nil
        statusMessage = "Checking..."
        controller.checkForUpdates(nil)
    }

    var isAvailable: Bool {
        controller.updater.canCheckForUpdates && !hasActiveQueueWork
    }

    var currentVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?.?.?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !hasActiveQueueWork else { throw activeWorkError }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard !hasActiveQueueWork else { throw activeWorkError }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        latestVersion = item.displayVersionString
        statusMessage = "Version \(item.displayVersionString) available."
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        latestVersion = nil
        statusMessage = "Up to date."
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        lastError = error.localizedDescription
        statusMessage = nil
        isChecking = false
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error {
            lastError = error.localizedDescription
        }
        isChecking = false
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard hasActiveQueueWork else { return false }
        pendingInstallHandler = installHandler
        statusMessage = "Update will install after active downloads finish."
        return true
    }

    private var hasActiveQueueWork: Bool {
        DownloadQueue.shared.queue.contains { item in
            switch item.status {
            case .downloading, .verifying, .uploading, .processing:
                return true
            case .pending, .completed, .paused, .failed:
                return false
            }
        }
    }

    private var activeWorkError: NSError {
        NSError(
            domain: "com.pmvdl.app.updater",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Finish or pause active downloads before checking for updates."]
        )
    }

    private func resumePendingInstallIfPossible() {
        guard let pendingInstallHandler, !hasActiveQueueWork else { return }
        self.pendingInstallHandler = nil
        pendingInstallHandler()
    }
}
