import SwiftUI

@main
struct LustreStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppStateManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 650)
                .tint(Theme.coral)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1200, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Navigate") {
                Button("Home") { appState.select(.home) }.keyboardShortcut("1", modifiers: .command)
                Button("Feed") { appState.select(.feed) }.keyboardShortcut("2", modifiers: .command)
                Button("Watchlist") { appState.select(.watchlist) }.keyboardShortcut("3", modifiers: .command)
                Button("Library") { appState.select(.library) }.keyboardShortcut("4", modifiers: .command)
                Button("Settings") { appState.select(.settings) }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Downloads") {
                Button("Extract New") { appState.select(.home) }.keyboardShortcut("N", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About LustreStudio") { showAboutWindow() }
            }
        }

        MenuBarExtra {
            DownloadMenuBarView()
        } label: {
            DownloadMenuBarIcon()
        }
        .menuBarExtraStyle(.menu)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // Custom URL scheme handler: pmvdl://extract?url=...
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "pmvdl", url.host == "extract" {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                if let queryItem = components?.queryItems?.first(where: { $0.name == "url" }),
                   let extractURL = queryItem.value,
                   URLTrustPolicy.validated(extractURL) != nil {
                    Task { @MainActor in
                        AppStateManager.shared.pendingExtractURL = extractURL
                        AppStateManager.shared.select(.home)
                        AppStateManager.shared.showMainWindow()
                    }
                }
            } else if url.scheme == "pmvdl", url.host == "license-success" {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                Task { @MainActor in
                    LicenseManager.shared.handleLicenseSuccess(email: nil)
                    AppStateManager.shared.select(.settings)
                    AppStateManager.shared.showMainWindow()
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        Task.detached(priority: .utility) {
            MegaManager.cleanupTempFiles()
        }
        NotificationManager.shared.requestAuthorization()
        Task { @MainActor in
            await MainActor.run {
                _ = LicenseManager.shared
            }
            await LicenseManager.shared.bootstrap()
            await SeedboxManager.reconnectConfiguredWebDAV()
        }
        Task {
            async let queueRestore: Void = DownloadQueue.shared.restorePersistedQueue()
            async let libraryRestore: Void = VideoLibrary.shared.restorePersistedLibrary()
            async let historyRestore: Void = HistoryManager.shared.restorePersistedHistory()
            async let pipelineRestore: Void = LibraryPipelineStore.shared.restorePersistedSnapshot()
            _ = await (queueRestore, libraryRestore, historyRestore, pipelineRestore)

            await LibraryPipelineStore.shared.hydrateFromStores(
                libraryItems: VideoLibrary.shared.items,
                completedUploads: HistoryManager.shared.completedUploads,
                queueItems: DownloadQueue.shared.queue
            )
            let seedboxWebdavPassword = SecureStore.string(forKey: "seedboxWebdavPassword") ?? ""
            DownloadQueue.shared.resumeInterruptedOnLaunch(seedboxWebdavPassword: seedboxWebdavPassword)
        }
        SleepPreventionManager.shared.start()
        Task { @MainActor in
            LustreAgentController.shared.start()
        }
        // Register app for NSAppleEventsDescriptor-based URL scheme
        NSAppleEventManager.shared().setEventHandler(self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent _: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "pmvdl" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let queryItem = components?.queryItems?.first(where: { $0.name == "url" }),
           let extractURL = queryItem.value,
           URLTrustPolicy.validated(extractURL) != nil {
            Task { @MainActor in
                AppStateManager.shared.pendingExtractURL = extractURL
                AppStateManager.shared.select(.home)
                AppStateManager.shared.showMainWindow()
            }
        } else if url.host == "license-success" {
            Task { @MainActor in
                LicenseManager.shared.handleLicenseSuccess(email: nil)
                AppStateManager.shared.select(.settings)
                AppStateManager.shared.showMainWindow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MegaManager.cancelAllOperations()
        MegaManager.cleanupTempFiles()
        SleepPreventionManager.shared.stop()
        DownloadQueue.shared.save()
        VideoLibrary.shared.save()
        FeedFavoritesStore.shared.save()
        Task { @MainActor in
            LustreAgentController.shared.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

struct DownloadMenuBarIcon: View {
    @ObservedObject private var queue = DownloadQueue.shared

    private var isActive: Bool {
        queue.activeDownloadCount > 0
    }

    var body: some View {
        Image(systemName: isActive ? "arrow.down.circle.fill" : "arrow.down.circle")
            .accessibilityLabel(isActive ? "LustreStudio downloads active" : "LustreStudio")
    }
}

struct DownloadMenuBarView: View {
    @ObservedObject private var queue = DownloadQueue.shared

    private var activeItems: [DownloadQueueItem] {
        queue.queue.filter { item in
            switch item.status {
            case .downloading, .verifying, .uploading, .processing:
                return true
            default:
                return false
            }
        }
    }

    private var pendingCount: Int {
            queue.queue.filter { $0.status == .pending || $0.status == .waiting }.count
    }

    private var pausedCount: Int {
        queue.queue.filter { $0.status == .paused }.count
    }

    private var failedCount: Int {
        queue.queue.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
    }

    private var overallProgress: Int {
        guard !activeItems.isEmpty else { return 0 }
        return Int((activeItems.map(\.progress).reduce(0, +) / Double(activeItems.count)).rounded())
    }

    var body: some View {
        Button(action: openDownloads) {
            Label(summaryTitle, systemImage: activeItems.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill")
        }

        if !activeItems.isEmpty {
            Text("Overall progress: \(overallProgress)%")
            ForEach(activeItems.prefix(3)) { item in
                Button(action: openDownloads) {
                    Text(itemSummary(item))
                }
            }

            if activeItems.count > 3 {
                Text("+ \(activeItems.count - 3) more active transfers")
            }

            Divider()

            Button("Pause All Transfers") {
                queue.pauseAll()
            }
        } else if pausedCount > 0 {
            Button("Resume \(pausedCount) Paused Transfer\(pausedCount == 1 ? "" : "s")") {
                queue.resumeAll()
            }
        } else {
            Text("No active transfers")
        }

        if pendingCount > 0 || failedCount > 0 {
            Text(queueSummary)
        }

        Divider()

        Button("Open LustreStudio", action: openApp)
        Button("Open Downloads", action: openDownloads)

        Divider()

        Button("Quit LustreStudio") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var summaryTitle: String {
        guard !activeItems.isEmpty else { return "LustreStudio" }
        return "\(activeItems.count) Active Transfer\(activeItems.count == 1 ? "" : "s")"
    }

    private var queueSummary: String {
        var parts: [String] = []
        if pendingCount > 0 { parts.append("\(pendingCount) queued") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        return parts.joined(separator: " • ")
    }

    private func itemSummary(_ item: DownloadQueueItem) -> String {
        let title = item.displayTitle ?? item.filename
        return "\(title) — \(statusText(for: item))"
    }

    private func statusText(for item: DownloadQueueItem) -> String {
        switch item.status {
        case .downloading:
            return "Downloading \(Int(item.progress.rounded()))%"
        case .verifying:
            return "Verifying"
        case .uploading:
            return "Uploading \(Int(item.progress.rounded()))%"
        case .processing:
            return "Processing \(Int(item.progress.rounded()))%"
        default:
            return item.statusMessage ?? "Working"
        }
    }

    private func openApp() {
        AppStateManager.shared.showMainWindow()
    }

    private func openDownloads() {
        AppStateManager.shared.select(.home)
        AppStateManager.shared.showMainWindow()
    }
}
