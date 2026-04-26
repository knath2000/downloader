import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppStateManager.shared
    @StateObject private var transferManager = TransferManager.shared
    @StateObject private var updateManager = UpdateManager.shared
    @StateObject private var paddleManager = PaddleManager.shared
    @AppStorage("megaRemotePath") var megaRemotePath = "/Cloud/PMVDL/"
    @AppStorage("gdriveRemoteName") var gdriveRemoteName = "gdrive"
    @AppStorage("gdriveRemotePath") var gdriveRemotePath = "PMVDL/"
    @State private var showUpgradeOverlay = false

    var body: some View {
        ZStack {
            NavigationSplitView {
                // SIDEBAR
                List(NavDestination.allCases, id: \.self, selection: $appState.selectedDestination) { dest in
                    HStack {
                        Label(dest.rawValue, systemImage: dest.icon)
                            .tag(dest)
                        if [.downloads, .transfers].contains(dest), let count = navBadge(for: dest) {
                            Text("\(count)").font(.system(size: 9)).bold()
                                .foregroundStyle(.red)
                                .frame(width: 18, height: 18)
                                .background(.red.opacity(0.15), in: .capsule)
                        }
                    }
                }
                .navigationSplitViewColumnWidth(min: 150, ideal: 170)
                if !ProFeatureGate.isPro {
                    Button(" Upgrade to Pro", systemImage: "crown.fill") {
                        appState.select(.settings)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 8)
                }
            } detail: {
                switch appState.selectedDestination {
                case .home:
                    HomeView(appState: appState,
                             megaRemotePath: megaRemotePath,
                             gdriveRemoteName: gdriveRemoteName,
                             gdriveRemotePath: gdriveRemotePath)
                        .modifier(HomeDropDestination(
                            onUrlPaste: { _ in },
                            onFileDrop: { _ in }
                        ))
                        .padding()
                case .library:
                    LibraryView()
                        .padding()
                case .downloads:
                    DownloadQueueViewNew()
                        .padding()
                case .scheduler:
                    SchedulerView()
                        .padding()
                case .transfers:
                    TransfersView(transferManager: transferManager)
                        .padding()
                case .processing:
                    ProcessingView()
                        .padding()
                case .settings:
                    SettingsView(gdriveRemoteName: $gdriveRemoteName,
                                 gdriveRemotePath: $gdriveRemotePath,
                                 megaRemotePath: $megaRemotePath)
                        .padding()
                }
            }
            .navigationTitle(appState.selectedDestination.rawValue)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 6) {
                        Button(action: { updateManager.checkForUpdates() }) {
                            Label(updateManager.currentVersion, systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Current version — click to check for updates")
                    }
                }
            }
            .onAppear {
                NotificationManager.shared.requestAuthorization()
            }

            // Upgrade overlay
            if showUpgradeOverlay {
                UpgradeOverlay { showUpgradeOverlay = false }
            }
        }
    }

    private func navBadge(for dest: NavDestination) -> Int? {
        switch dest {
        case .downloads:
            let q = DownloadQueue.shared.queue.filter { !$0.status.isTerminal }
            return q.isEmpty ? nil : q.count
        case .transfers:
            let c = TransferManager.shared.transfers.count
            return c == 0 ? nil : c
        default:
            return nil
        }
    }
}

// ===== TRANSFERS VIEW =====
struct TransfersView: View {
    @ObservedObject var transferManager: TransferManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue)
                Text("Mega Transfers").font(.headline)
                Spacer()
                Button(transferManager.isActive ? "Stop Polling" : "Start Polling") {
                    if transferManager.isActive { transferManager.stop() }
                    else { transferManager.start() }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if transferManager.transfers.isEmpty {
                VStack {
                    Image(systemName: "arrow.up.circle")
                        .resizable().scaledToFit()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.secondary)
                        .padding()
                    Text("No uploads in progress").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(transferManager.transfers) { t in
                            TransferRow(item: t, onCancel: {
                                Task { await transferManager.cancelTransfer(tag: t.tag) }
                            })
                            Divider().padding(.leading, 8)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
            Spacer()
        }
        .onAppear { transferManager.start() }
        .onDisappear { transferManager.stop() }
    }
}

// ===== SETTINGS VIEW =====
struct SettingsView: View {
    @Binding var gdriveRemoteName: String
    @Binding var gdriveRemotePath: String
    @Binding var megaRemotePath: String
    @StateObject private var paddle = PaddleManager.shared
    @StateObject private var updater = UpdateManager.shared
    @State private var activateEmail = ""
    @State private var activateKey = ""
    @State private var activationResult = ""
    @State private var isActivating = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "gearshape.fill").foregroundStyle(.blue)
                    Text("Settings").font(.headline)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Form {
                    Section("Mega Upload") {
                        TextField("Remote path", text: $megaRemotePath)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            if MegaManager.isAvailable {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("Mega CLI installed").foregroundStyle(.secondary).font(.caption)
                            } else {
                                Text("brew install --cask megacmd-app")
                                    .foregroundStyle(.orange).font(.caption)
                            }
                        }
                        HStack {
                            if MegaManager.isLoggedIn {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("Logged in").foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                    Section("Google Drive Upload") {
                        TextField("Remote name", text: $gdriveRemoteName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Remote path", text: $gdriveRemotePath)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            if GDriveManager.isAvailable {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("rclone installed").foregroundStyle(.secondary).font(.caption)
                            } else {
                                Text("brew install rclone").foregroundStyle(.orange).font(.caption)
                            }
                        }
                        HStack {
                            if GDriveManager.isConfigured(remoteName: gdriveRemoteName) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("GDrive configured").foregroundStyle(.secondary).font(.caption)
                            } else {
                                Text("rclone config").foregroundStyle(.orange).font(.caption)
                            }
                        }
                    }
                    Section("Notifications") {
                        Toggle("Upload complete", isOn: Binding(
                            get: { NotificationManager.shared.isEnabled(.uploadComplete) },
                            set: { NotificationManager.shared.setEnabled(.uploadComplete, enabled: $0) }
                        ))
                        Toggle("Upload failed", isOn: Binding(
                            get: { NotificationManager.shared.isEnabled(.uploadFailed) },
                            set: { NotificationManager.shared.setEnabled(.uploadFailed, enabled: $0) }
                        ))
                        Toggle("Extraction complete", isOn: Binding(
                            get: { NotificationManager.shared.isEnabled(.scrapeComplete) },
                            set: { NotificationManager.shared.setEnabled(.scrapeComplete, enabled: $0) }
                        ))
                    }
                    Section("Updates") {
                        HStack {
                            Text("Current: \(updater.currentVersion)")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Check for Updates") {
                                updater.checkForUpdates()
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    Section("Extensions") {
                        LabeledContent("Safari Extension", value: "Install via Safari → Extensions")
                        LabeledContent("Share Extension", value: "Available in Share menu")
                    }
                    Section("Download Options") {
                        Toggle("Auto-download subtitles", isOn: Binding(
                            get: { DownloadManager.shared.subtitlesEnabled },
                            set: { DownloadManager.shared.subtitlesEnabled = $0 }
                        ))
                        if DownloadManager.shared.subtitlesEnabled {
                            Picker("Subtitle mode",
                                   selection: Binding(get: { DownloadManager.shared.embeddedSubsMode ? 1 : 0 },
                                                      set: { DownloadManager.shared.embeddedSubsMode = $0 == 1 })) {
                                Text("Sidecar files").tag(0)
                                Text("Embedded").tag(1)
                            }
                        }
                        HStack {
                            if ScraperEngine.isYTDLPAvailable {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("yt-dlp installed (audio + subs)").foregroundStyle(.secondary).font(.caption)
                            } else {
                                Text("brew install yt-dlp for audio/subs").foregroundStyle(.orange).font(.caption)
                            }
                        }
                        HStack {
                            if ScraperEngine.isFFmpegAvailable {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("ffmpeg installed (HLS)").foregroundStyle(.secondary).font(.caption)
                            } else {
                                Text("brew install ffmpeg for HLS streams").foregroundStyle(.orange).font(.caption)
                            }
                        }
                        Button("Open Downloads Folder") {
                            NSWorkspace.shared.open(DownloadManager.shared.downloadDir)
                        }.buttonStyle(.plain).font(.caption)
                    }

                    // ===== PRO LICENSING =====
                    if !ProFeatureGate.isPro {
                        Section("Upgrade to Pro") {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "crown.fill").foregroundStyle(.yellow)
                                    Text("PMVDL Pro — $5 one-time").font(.subheadline.bold())
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("• Unlimited batch downloads")
                                    Text("• Schedule downloads")
                                    Text("• Multi-cloud simultaneous upload")
                                    Text("• Priority support")
                                }
                                .font(.caption).foregroundStyle(.secondary)

                                TextField("Email", text: $activateEmail)
                                    .textFieldStyle(.roundedBorder).font(.caption)
                                SecureField("License key", text: $activateKey)
                                    .textFieldStyle(.roundedBorder).font(.caption)

                                if !activationResult.isEmpty {
                                    Text(activationResult)
                                        .font(.caption)
                                        .foregroundStyle(activationResult.hasPrefix("OK") ? .green : .red)
                                }
                                Text("Trial downloads remaining: \(paddle.trialDownloadsRemaining)")
                                    .font(.caption2).foregroundStyle(.secondary)

                                Button("Activate License") {
                                    Task {
                                        isActivating = true
                                        let ok = await paddle.activate(email: activateEmail, licenseKey: activateKey)
                                        activationResult = ok ? "OK — Pro activated!" : "Activation failed. Check your key."
                                        isActivating = false
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(isActivating || activateEmail.isEmpty || activateKey.isEmpty)
                            }
                            .padding(4)
                        }
                    } else {
                        Section("Pro License") {
                            HStack {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                Text("Pro activated for \(paddle.activationEmail)")
                                    .font(.caption)
                                Spacer()
                                Button("Deactivate") {
                                    paddle.deactivate()
                                    activationResult = "License deactivated."
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    Section("About") {
                        Button("About PMVDL") { showAboutWindow() }
                            .buttonStyle(.plain).font(.caption)
                    }
                }
                .padding(.horizontal)
                .frame(maxHeight: .infinity)
            }
        }
    }
}

// ===== TRANSFER ROW =====
struct TransferRow: View {
    let item: TransferItem
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                if item.state == "ACTIVE" {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue)
                } else if item.state == "QUEUED" {
                    Image(systemName: "clock.fill").foregroundStyle(.orange)
                } else if item.state == "FAILED" {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Text(item.filename)
                    .font(.caption.bold())
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(item.state == "QUEUED" ? "Queued" : String(format: "%.0f%%", item.progress))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if item.state == "ACTIVE" || item.state == "QUEUED" {
                ProgressView(value: item.progress, total: 100.0)
                    .tint(item.state == "QUEUED" ? .orange : .blue)
                    .progressViewStyle(.linear)
                HStack {
                    Text(item.size).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
            } else {
                HStack {
                    if item.state == "COMPLETED" {
                        Text("Upload complete").font(.caption).foregroundStyle(.green)
                    } else if item.state == "FAILED" {
                        Text("Upload failed").font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
    }
}
