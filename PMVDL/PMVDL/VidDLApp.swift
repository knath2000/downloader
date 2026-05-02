import SwiftUI

@main
struct VidDLApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppStateManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 650)
                .tint(Theme.coral)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Navigate") {
                Button("Home") { appState.select(.home) }.keyboardShortcut("1", modifiers: .command)
                Button("Library") { appState.select(.library) }.keyboardShortcut("2", modifiers: .command)
                Button("Downloads") { appState.select(.downloads) }.keyboardShortcut("3", modifiers: .command)
                Button("Transfers") { appState.select(.transfers) }.keyboardShortcut("4", modifiers: .command)
                Button("Settings") { appState.select(.settings) }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Downloads") {
                Button("Extract New") { appState.select(.home) }.keyboardShortcut("N", modifiers: .command)
            }
            CommandGroup(replacing: .appInfo) {
                Button("About VidDL") { showAboutWindow() }
            }
        }

        MenuBarExtra("VidDL", image: "menubarIcon") {
            MenuBarQuickView()
        }

    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    // Custom URL scheme handler: pmvdl://extract?url=...
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "pmvdl", url.host == "extract" {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                if let queryItem = components?.queryItems?.first(where: { $0.name == "url" }),
                   let extractURL = queryItem.value {
                    Task { @MainActor in
                        AppStateManager.shared.pendingExtractURL = extractURL
                        AppStateManager.shared.select(.home)
                        AppStateManager.shared.showMainWindow()
                    }
                }
            } else if url.scheme == "pmvdl", url.host == "license-success" {
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let email = components?.queryItems?.first(where: { $0.name == "email" })?.value
                Task { @MainActor in
                    LicenseManager.shared.handleLicenseSuccess(email: email)
                    AppStateManager.shared.select(.settings)
                    AppStateManager.shared.showMainWindow()
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        MegaManager.cleanupTempFiles()
        NotificationManager.shared.requestAuthorization()

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
           let extractURL = queryItem.value {
            Task { @MainActor in
                AppStateManager.shared.pendingExtractURL = extractURL
                AppStateManager.shared.select(.home)
                AppStateManager.shared.showMainWindow()
            }
        } else if url.host == "license-success" {
            let email = components?.queryItems?.first(where: { $0.name == "email" })?.value
            Task { @MainActor in
                LicenseManager.shared.handleLicenseSuccess(email: email)
                AppStateManager.shared.select(.settings)
                AppStateManager.shared.showMainWindow()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MegaManager.cancelAllOperations()
        MegaManager.cleanupTempFiles()
        DownloadQueue.shared.save()
        VideoLibrary.shared.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// ===== MENU BAR QUICK VIEW =====
struct MenuBarQuickView: View {
    @StateObject private var appState = AppStateManager.shared

    var body: some View {
        Button("Open VidDL") { appState.showMainWindow() }

        Divider()

        if let clip = ClipboardManager.currentURL,
           ClipboardManager.isLikelyVideoURL(clip) {
            Button("Extract: " + (clip as NSString).lastPathComponent) {
                appState.showMainWindow()
            }
            Divider()
        }

        if TransferManager.shared.isActive {
            Text("\(TransferManager.shared.transfers.count) uploading...")
                .foregroundStyle(.secondary)
            Divider()
        }

        Button("Settings...") { appState.showMainWindow(); appState.select(.settings) }
        Button("About") { showAboutWindow() }
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
