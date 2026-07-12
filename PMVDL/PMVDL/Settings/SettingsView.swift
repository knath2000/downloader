import AppKit
import SwiftUI

struct SettingsView: View {
    @Binding var gdriveRemoteName: String
    @Binding var gdriveRemotePath: String
    @Binding var seedboxTransferMode: String
    @Binding var seedboxRemoteName: String
    @Binding var seedboxRemotePath: String
    @Binding var seedboxWebdavURL: String
    @Binding var seedboxWebdavUser: String
    @Binding var seedboxWebdavPassword: String
    let onUpgradeRequired: () -> Void

    @AppStorage("downloadSubtitles") private var downloadSubtitles = false
    @AppStorage("embeddedSubsMode") private var embeddedSubsMode = false
    @AppStorage(AppPreferenceKeys.preventSleepWhileRunning) private var preventSleepWhileRunning = false
    @AppStorage(DownloadPaths.customDownloadDirectoryKey) private var customDownloadDirectory = ""
    @AppStorage("seedboxWebdavAllowSelfSigned") private var seedboxWebdavAllowSelfSigned = false

    @StateObject private var license = LicenseManager.shared
    @StateObject private var dependencyStore = SettingsDependencyStore.shared
    @StateObject private var gdriveSetup = RcloneRemoteSetupViewModel()
    @StateObject private var seedboxSetup = RcloneRemoteSetupViewModel()

    @State private var activationCode = ""
    @State private var activationResult = ""
    @State private var recoveryCode = ""
    @State private var isActivating = false
    @State private var showsGDriveManualFields = false
    @State private var seedboxAuthMode: RcloneSFTPAuthMode = .password
    @State private var seedboxSFTPHost = ""
    @State private var seedboxSFTPPort = "22"
    @State private var seedboxSFTPUser = ""
    @State private var seedboxSFTPPassword = ""
    @State private var seedboxSFTPKeyFile = ""
    @State private var seedboxConnectionMessage = ""
    @State private var seedboxIsTesting = false
    @State private var seedboxWebDAVVerified = false
    @State private var showsWebDAVFolderPicker = false
    @State private var activePanel: SettingsPanel?

    private var trimmedActivationCode: String {
        activationCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var dependencyInput: SettingsDependencyInput {
        SettingsDependencyInput(
            gdriveRemoteName: gdriveRemoteName,
            seedboxTransferMode: seedboxTransferMode,
            seedboxRemoteName: seedboxRemoteName,
            seedboxWebdavURL: seedboxWebdavURL
        )
    }

    private var dependencyModel: SettingsDependencyViewModel {
        SettingsDependencyPresenter.model(snapshot: dependencyStore.snapshot, input: dependencyInput)
    }

    private var currentVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?.?.?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func color(for tone: SettingsDependencyTone) -> Color {
        switch tone {
        case .checking: return Theme.textSecondary
        case .success:  return Theme.success
        case .warning:  return Theme.warning
        case .error:    return Theme.error
        }
    }

    var body: some View {
        ZStack {
            settingsLandingPage

            if let activePanel {
                AppModalOverlay(dismiss: { self.activePanel = nil }) {
                    settingsModal(for: activePanel)
                }
                .transition(.opacity)
                .zIndex(5)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: activePanel)
        .task(id: dependencyInput) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            await dependencyStore.refresh(input: dependencyInput)
        }
        .sheet(isPresented: $showsWebDAVFolderPicker) {
            if let url = URLTrustPolicy.validated(seedboxWebdavURL), url.scheme?.lowercased() == "https" {
                WebDAVFolderPickerView(
                    baseURL: url,
                    user: seedboxWebdavUser,
                    password: seedboxWebdavPassword,
                    allowSelfSigned: seedboxWebdavAllowSelfSigned,
                    selectedPath: $seedboxRemotePath
                )
            }
        }
    }

    private var settingsLandingPage: some View {
        ScrollView {
            LazyVStack(alignment: .center, spacing: 12) {
                ForEach(SettingsPanel.allCases) { panel in
                    Button {
                        activePanel = panel
                    } label: {
                        SettingsTile(
                            panel: panel,
                            detail: tileDetail(for: panel),
                            status: tileStatus(for: panel),
                            isEmphasized: panel == .cloud && (!dependencyModel.gdrive.isReady || !dependencyModel.seedbox.isReady)
                        )
                    }
                    .buttonStyle(.plain)
                    .mobilePressFeedback()
                }
            }
            .frame(maxWidth: 760, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
    }

    private func tileDetail(for panel: SettingsPanel) -> String {
        switch panel {
        case .cloud:
            return "GDrive: \(dependencyModel.gdrive.status) · Seedbox: \(dependencyModel.seedbox.status)"
        case .notifications:
            let enabled = [
                NotificationManager.shared.isEnabled(.uploadComplete),
                NotificationManager.shared.isEnabled(.uploadFailed),
                NotificationManager.shared.isEnabled(.scrapeComplete)
            ].filter { $0 }.count
            return "\(enabled) of 3 alerts enabled"
        case .downloads:
            return DownloadPaths.hasCustomDownloadDir ? "Custom folder selected" : "Default download folder"
        case .pro:
            return ProFeatureGate.isPro ? "Activated for \(license.activationEmail.isEmpty ? "this Mac" : license.activationEmail)" : "\(license.freeDownloadsRemaining) free downloads remaining"
        case .about:
            return "VidDL \(currentVersion)"
        }
    }

    private func tileStatus(for panel: SettingsPanel) -> String? {
        switch panel {
        case .cloud:
            return dependencyModel.seedbox.isReady && dependencyModel.gdrive.isReady ? "2 destinations ready" : "Configure destinations"
        case .notifications:
            return nil
        case .downloads:
            let readyCount = [dependencyModel.ytDlp.isReady, dependencyModel.ffmpeg.isReady].filter { $0 }.count
            return "\(readyCount)/2 tools"
        case .pro:
            return ProFeatureGate.isPro ? "Active" : "Free"
        case .about:
            return nil
        }
    }

    private func panelTint(for panel: SettingsPanel) -> Color {
        switch panel {
        case .cloud:
            return color(for: dependencyModel.gdrive.tone)
        default:
            return panel.color
        }
    }

    private func settingsModal(for panel: SettingsPanel) -> some View {
        SettingsModalSurface(panel: panel, tint: panelTint(for: panel)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch panel {
                    case .cloud:
                        cloudSection
                    case .notifications:
                        notificationsCard
                    case .downloads:
                        downloadBehaviorCard
                    case .pro:
                        proSection
                    case .about:
                        infoSection
                    }
                }
                .padding(18)
            }
        }
    }

    private func refreshDependencyChecks() {
        Task { await dependencyStore.refresh(input: dependencyInput, force: true) }
    }

    private func browseForDownloadLocation() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Location"
        panel.message = "Choose where VidDL should save local downloads."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = DownloadPaths.downloadDir

        guard panel.runModal() == .OK,
              let url = panel.url else { return }
        customDownloadDirectory = url.path
        DownloadPaths.setCustomDownloadDir(url)
    }

    private var cloudSection: some View {
        let model = dependencyModel.gdrive
        let tint = color(for: model.tone)

        return VStack(alignment: .leading, spacing: 14) {
            SettingsCard(tint: tint) {
                VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                    SettingsCardTitle(
                        title: "Google Drive Upload",
                        subtitle: "Use rclone to upload completed files to a Google Drive remote.",
                        systemImage: "externaldrive.fill.badge.checkmark",
                        tint: tint,
                        status: model.status
                    )

                    SettingsDependencySummary(model: model, color: tint)
                    gdriveGuidedSetupFields
                }
            }

            seedboxSection
        }
    }

    private var seedboxSection: some View {
        let model = dependencyModel.seedbox
        let tint = color(for: model.tone)

        return SettingsCard(tint: tint) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                SettingsCardTitle(
                    title: "Seedbox Upload",
                    subtitle: "Choose the connection that best fits your server and transfer needs.",
                    systemImage: "server.rack",
                    tint: tint,
                    status: model.status
                )

                SettingsDependencySummary(model: model, color: tint)

                Picker("Connection", selection: $seedboxTransferMode) {
                    Text("WebDAV HTTPS").tag("webdav")
                    Text("SFTP via rclone").tag("rclone")
                }
                .pickerStyle(.segmented)

                Text(seedboxTransferMode == "webdav"
                     ? "WebDAV HTTPS is usually the quickest to configure and works well when your provider exposes a direct upload URL."
                     : "SFTP is the safest general-purpose option: encrypted SSH transport and reliable remote-folder access through rclone.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if seedboxTransferMode == "webdav" {
                    webDAVSetupFields
                } else {
                    sftpSetupFields
                }
            }
        }
    }

    private var webDAVSetupFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassTextField(label: "WebDAV HTTPS URL", placeholder: "https://seedbox.example.com/remote.php/dav/files/user/", text: $seedboxWebdavURL, help: "Use HTTPS whenever your provider supports it. The URL should be the WebDAV base path.")
            GlassTextField(label: "Username", placeholder: "seedbox user", text: $seedboxWebdavUser, help: "Your WebDAV account username.")
            SecureField("WebDAV password", text: $seedboxWebdavPassword)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.accentDim.opacity(0.25), in: RoundedRectangle(cornerRadius: SettingsLayoutMetrics.controlCornerRadius))
            GlassTextField(label: "Remote path", placeholder: "/", text: $seedboxRemotePath, help: "Folder where completed files will be uploaded.")
            Toggle("Allow this server's self-signed certificate", isOn: $seedboxWebdavAllowSelfSigned)
                .toggleStyle(.switch)
                .font(.caption.weight(.semibold))
            if seedboxWebdavAllowSelfSigned {
                SettingsInlineAlert(text: "Only enable this for a server you control. VidDL will trust an unverified certificate only for this WebDAV host.", tint: Theme.warning)
            }

            HStack(spacing: 8) {
                Button {
                    testWebDAVConnection()
                } label: {
                    Label(seedboxIsTesting ? "Testing…" : "Test WebDAV", systemImage: "checkmark.seal")
                }
                .buttonStyle(.borderedProminent)
                .tint(tintForSeedbox)
                .disabled(seedboxIsTesting)

                if seedboxWebDAVVerified {
                    Button {
                        showsWebDAVFolderPicker = true
                    } label: {
                        Label("Browse folders", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .tint(tintForSeedbox)
                }

                if !seedboxConnectionMessage.isEmpty {
                    Text(seedboxConnectionMessage)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var sftpSetupFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassTextField(label: "rclone remote name", placeholder: "seedbox", text: $seedboxRemoteName, help: "The local rclone name used by VidDL.")
            HStack(spacing: 8) {
                GlassTextField(label: "Host", placeholder: "sftp.example.com", text: $seedboxSFTPHost, help: "Seedbox hostname or IP.")
                GlassTextField(label: "Port", placeholder: "22", text: $seedboxSFTPPort, help: "SSH/SFTP port, usually 22.")
            }
            GlassTextField(label: "Username", placeholder: "seedbox user", text: $seedboxSFTPUser, help: "SFTP account username.")

            Picker("Authentication", selection: $seedboxAuthMode) {
                Text("Password").tag(RcloneSFTPAuthMode.password)
                Text("SSH key").tag(RcloneSFTPAuthMode.key)
            }
            .pickerStyle(.segmented)

            if seedboxAuthMode == .password {
                SecureField("SFTP password", text: $seedboxSFTPPassword)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.accentDim.opacity(0.25), in: RoundedRectangle(cornerRadius: SettingsLayoutMetrics.controlCornerRadius))
            } else {
                GlassTextField(label: "SSH key file", placeholder: "~/.ssh/id_ed25519", text: $seedboxSFTPKeyFile, help: "Path to the private key used by rclone.")
            }

            GlassTextField(label: "Remote path", placeholder: "/", text: $seedboxRemotePath, help: "Folder where completed files will be uploaded.")

            RcloneSeedboxSetupCard(
                phase: seedboxSetup.phase,
                message: seedboxSetup.progressMessage,
                tint: tintForSeedbox,
                remoteName: resolvedSeedboxRemoteName,
                isRunning: seedboxSetup.isRunning,
                start: startSFTPSetup,
                useExisting: {
                    seedboxSetup.useExistingSFTP(remoteName: resolvedSeedboxRemoteName, path: seedboxRemotePath) { name, path in
                        seedboxRemoteName = name
                        seedboxRemotePath = path
                        seedboxTransferMode = "rclone"
                        refreshDependencyChecks()
                    }
                },
                cancel: seedboxSetup.cancel,
                retry: startSFTPSetup,
                refresh: {
                    seedboxSetup.refresh(remoteName: resolvedSeedboxRemoteName)
                    refreshDependencyChecks()
                }
            )
        }
    }

    private var resolvedSeedboxRemoteName: String {
        let trimmed = seedboxRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "seedbox" : trimmed
    }

    private var tintForSeedbox: Color {
        color(for: dependencyModel.seedbox.tone)
    }

    private var sftpInput: RcloneSFTPSetupInput {
        RcloneSFTPSetupInput(
            remoteName: resolvedSeedboxRemoteName,
            host: seedboxSFTPHost,
            port: seedboxSFTPPort,
            username: seedboxSFTPUser,
            authMode: seedboxAuthMode,
            keyFile: seedboxSFTPKeyFile,
            password: seedboxSFTPPassword,
            rootPath: seedboxRemotePath
        )
    }

    private func startSFTPSetup() {
        seedboxSetup.startSFTPSetup(input: sftpInput) { name, path in
            seedboxRemoteName = name
            seedboxRemotePath = path
            seedboxTransferMode = "rclone"
            refreshDependencyChecks()
        }
    }

    private func testWebDAVConnection() {
        guard let url = URLTrustPolicy.validated(seedboxWebdavURL), url.scheme?.lowercased() == "https" else {
            seedboxConnectionMessage = "Enter a valid HTTPS WebDAV URL."
            return
        }
        seedboxIsTesting = true
        seedboxConnectionMessage = "Connecting…"
        Task {
            do {
                try await SeedboxManager(mode: .webdav(baseURL: url, user: seedboxWebdavUser, password: seedboxWebdavPassword, remotePath: seedboxRemotePath, allowSelfSigned: seedboxWebdavAllowSelfSigned)).testConnection()
                await MainActor.run {
                    seedboxTransferMode = "webdav"
                    seedboxConnectionMessage = "WebDAV is ready for uploads."
                    seedboxIsTesting = false
                    seedboxWebDAVVerified = true
                    refreshDependencyChecks()
                }
            } catch {
                await MainActor.run {
                    seedboxConnectionMessage = webDAVConnectionErrorMessage(error)
                    seedboxIsTesting = false
                    seedboxWebDAVVerified = false
                }
            }
        }
    }

    private func webDAVConnectionErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch nsError.code {
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
            return "TLS certificate validation failed. Enable the self-signed certificate option only for this server, or use a certificate trusted by macOS."
        case NSURLErrorUserAuthenticationRequired:
            return "WebDAV reached the server, but the username or password was rejected."
        case NSURLErrorTimedOut:
            return "WebDAV timed out. Check the URL, network, and server availability."
        default:
            return error.localizedDescription
        }
    }

    private var gdriveGuidedSetupFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsFieldRow("Remote name") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("gdrive", text: $gdriveRemoteName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Theme.accentDim.opacity(0.25), in: RoundedRectangle(cornerRadius: SettingsLayoutMetrics.controlCornerRadius))
                        .overlay(
                            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.controlCornerRadius)
                                .strokeBorder(Theme.border, lineWidth: 0.5)
                        )
                        .disabled(gdriveSetup.isRunning)

                    SettingsHelpText("Use a short rclone remote name. Existing uploads use this value.")
                }
            }

            GDriveSetupStatusCard(
                phase: gdriveSetup.phase,
                message: gdriveSetup.progressMessage,
                tint: color(for: gdriveSetupTone),
                remoteName: resolvedGDriveRemoteName,
                isRunning: gdriveSetup.isRunning,
                start: {
                    gdriveSetup.startGoogleDriveSetup(remoteName: gdriveRemoteName) { configuredName in
                        gdriveRemoteName = configuredName
                        refreshDependencyChecks()
                    }
                },
                useExisting: {
                    gdriveSetup.useExisting(remoteName: gdriveRemoteName) { configuredName in
                        gdriveRemoteName = configuredName
                        refreshDependencyChecks()
                    }
                },
                reconnect: {
                    gdriveSetup.reconnectGoogleDrive(remoteName: gdriveRemoteName) { configuredName in
                        gdriveRemoteName = configuredName
                        refreshDependencyChecks()
                    }
                },
                cancel: gdriveSetup.cancel,
                retry: {
                    gdriveSetup.startGoogleDriveSetup(remoteName: gdriveRemoteName) { configuredName in
                        gdriveRemoteName = configuredName
                        refreshDependencyChecks()
                    }
                },
                refresh: {
                    gdriveSetup.refresh(remoteName: gdriveRemoteName)
                    refreshDependencyChecks()
                }
            )

            DisclosureGroup(isExpanded: $showsGDriveManualFields) {
                VStack(alignment: .leading, spacing: 10) {
                    GlassTextField(
                        label: "Remote path",
                        placeholder: "VidDL/",
                        text: $gdriveRemotePath,
                        help: "Uploads will be placed under this path inside the selected Google Drive remote."
                    )
                    SettingsCommandRow(command: "brew install rclone")
                    SettingsCommandRow(command: "rclone config")
                    SettingsCommandRow(command: "rclone config reconnect \(resolvedGDriveRemoteName):")
                }
                .padding(.top, 8)
            } label: {
                Label("Advanced manual setup", systemImage: "terminal")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .onAppear {
            gdriveSetup.refresh(remoteName: gdriveRemoteName)
        }
        .onChange(of: gdriveRemoteName) { _, _ in
            gdriveSetup.refresh(remoteName: gdriveRemoteName)
        }
    }

    private var resolvedGDriveRemoteName: String {
        let trimmed = gdriveRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "gdrive" : trimmed
    }

    private var gdriveSetupTone: SettingsDependencyTone {
        switch gdriveSetup.phase {
        case .configured:
            return .success
        case .missingRclone, .failed:
            return .error
        case .existingRemote:
            return .warning
        case .idle, .ready, .authorizing, .verifying:
            return .checking
        }
    }


    private var subtitleBinding: Binding<Bool> {
        Binding(
            get: { downloadSubtitles && ProFeatureGate.canDownloadSubtitles },
            set: { newValue in
                if newValue {
                    guard ProFeatureGate.canDownloadSubtitles else {
                        downloadSubtitles = false
                        onUpgradeRequired()
                        return
                    }
                    downloadSubtitles = true
                } else {
                    downloadSubtitles = false
                }
            }
        )
    }

    private var preventSleepBinding: Binding<Bool> {
        Binding(
            get: { preventSleepWhileRunning },
            set: { newValue in
                preventSleepWhileRunning = newValue
                SleepPreventionManager.shared.update()
            }
        )
    }

    private var downloadLocationDisplay: String {
        DownloadPaths.downloadDir.path
    }

    private var notificationsCard: some View {
        SettingsCard(tint: Theme.amber) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                SettingsCardTitle(
                    title: "Notifications",
                    subtitle: "Choose which VidDL events should notify you.",
                    systemImage: "bell.badge.fill",
                    tint: Theme.amber
                )

                VStack(spacing: 0) {
                    SettingsToggleRow(
                        title: "Upload complete",
                        subtitle: "Notify when a cloud upload finishes.",
                        systemImage: "checkmark.icloud.fill",
                        tint: Theme.success,
                        isOn: Binding(
                            get: { NotificationManager.shared.isEnabled(.uploadComplete) },
                            set: { NotificationManager.shared.setEnabled(.uploadComplete, enabled: $0) }
                        )
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: "Upload failed",
                        subtitle: "Notify when an upload or transfer fails.",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: Theme.error,
                        isOn: Binding(
                            get: { NotificationManager.shared.isEnabled(.uploadFailed) },
                            set: { NotificationManager.shared.setEnabled(.uploadFailed, enabled: $0) }
                        )
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: "Extraction complete",
                        subtitle: "Notify when link extraction completes.",
                        systemImage: "link.badge.plus",
                        tint: Theme.skyBlue,
                        isOn: Binding(
                            get: { NotificationManager.shared.isEnabled(.scrapeComplete) },
                            set: { NotificationManager.shared.setEnabled(.scrapeComplete, enabled: $0) }
                        )
                    )
                }
                .background(Theme.surface2.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var downloadBehaviorCard: some View {
        SettingsCard(tint: Theme.gold) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                SettingsCardTitle(
                    title: "Download Options",
                    subtitle: "Download behavior and required helper tools.",
                    systemImage: "arrow.down.circle.fill",
                    tint: Theme.gold
                )

                VStack(alignment: .leading, spacing: 10) {
                    SettingsToggleRow(
                        title: "Auto-download subtitles",
                        subtitle: ProFeatureGate.canDownloadSubtitles ? "Ask yt-dlp to fetch subtitles when they are available." : "Pro unlocks automatic subtitle sidecars or embedding.",
                        systemImage: "captions.bubble.fill",
                        tint: Theme.skyBlue,
                        isOn: subtitleBinding
                    )

                    SettingsDivider()

                    SettingsToggleRow(
                        title: "Prevent sleep while running",
                        subtitle: "Keep this Mac awake while downloads or uploads are active.",
                        systemImage: "moon.zzz.fill",
                        tint: Theme.lavender,
                        isOn: preventSleepBinding
                    )

                    if downloadSubtitles && ProFeatureGate.canDownloadSubtitles {
                        SettingsDivider()

                        SettingsFieldRow("Subtitle mode") {
                            Picker("Subtitle mode", selection: Binding(
                                get: { embeddedSubsMode ? 1 : 0 },
                                set: { embeddedSubsMode = $0 == 1 }
                            )) {
                                Text("Sidecar files").tag(0)
                                Text("Embedded").tag(1)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 320)
                        }
                    }

                    SettingsDivider()

                    SettingsFieldRow("Download location") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text(downloadLocationDisplay)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 10)
                                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                    .background(Theme.surface1.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.gold.opacity(0.18), lineWidth: 0.5))

                                Button {
                                    browseForDownloadLocation()
                                } label: {
                                    Label("Browse", systemImage: "folder.badge.gearshape")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.gold)
                                .controlSize(.small)

                                Button {
                                    DownloadPaths.ensureDownloadDir()
                                    NSWorkspace.shared.open(DownloadPaths.downloadDir)
                                } label: {
                                    Label("Open", systemImage: "folder")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            HStack(spacing: 8) {
                                Text(DownloadPaths.hasCustomDownloadDir ? "Custom folder selected." : "Using the default VidDL folder.")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)

                                if DownloadPaths.hasCustomDownloadDir {
                                    Button("Reset to Default") {
                                        customDownloadDirectory = ""
                                        DownloadPaths.resetCustomDownloadDir()
                                    }
                                    .buttonStyle(.plain)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Theme.gold)
                                }
                            }
                        }
                    }
                }

                SettingsDivider()

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Required CLI Tools")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("VidDL uses these helpers for broad extraction, HLS, audio, and verification.")
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button {
                            refreshDependencyChecks()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(dependencyStore.isRefreshing)
                    }

                    SettingsDependencyInlineRow(
                        model: dependencyModel.ytDlp,
                        color: color(for: dependencyModel.ytDlp.tone)
                    )

                    SettingsDependencyInlineRow(
                        model: dependencyModel.ffmpeg,
                        color: color(for: dependencyModel.ffmpeg.tone)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var proSection: some View {
        if ProFeatureGate.isPro {
            proActiveCard
        } else {
            proUpgradeCard
        }
    }

    private var proActiveCard: some View {
        SettingsCard(tint: Theme.success) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                SettingsCardTitle(
                    title: "VidDL Pro",
                    subtitle: "Activated for this Mac with a personal license",
                    systemImage: "crown.fill",
                    tint: Theme.success,
                    status: "Active"
                )

                VStack(alignment: .leading, spacing: 7) {
                    SettingsFeatureLine("Unlimited total downloads", tint: Theme.success)
                    SettingsFeatureLine("\(ProFeatureGate.proConcurrentDownloadLimit) concurrent downloads", tint: Theme.success)
                    SettingsFeatureLine("Batch download more than \(ProFeatureGate.freeBatchLimit) items", tint: Theme.success)
                    SettingsFeatureLine("Feed discovery and saved favorites", tint: Theme.success)
                    SettingsFeatureLine("Multi-cloud simultaneous upload", tint: Theme.success)
                    SettingsFeatureLine("Audio downloads and subtitles", tint: Theme.success)
                }

                HStack {
                    Spacer()
                    Button("Deactivate") {
                        license.deactivateLocalLicense()
                        activationResult = "License deactivated."
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var proUpgradeCard: some View {
        SettingsCard(tint: Theme.coral) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                SettingsCardTitle(
                    title: "Activate VidDL Pro",
                    subtitle: "Use your personal recovery code for offline activation.",
                    systemImage: "crown.fill",
                    tint: Theme.coral
                )

                HStack(spacing: 9) {
                    Text("Personal VidDL Pro")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Offline activation")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.gold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.gold.opacity(0.14), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 7) {
                    SettingsFeatureLine("\(LicenseManager.freeDownloadLimit) → unlimited total downloads", tint: Theme.gold)
                    SettingsFeatureLine("\(ProFeatureGate.freeConcurrentDownloadLimit) → \(ProFeatureGate.proConcurrentDownloadLimit) concurrent downloads", tint: Theme.electricLime)
                    SettingsFeatureLine("Batch download more than \(ProFeatureGate.freeBatchLimit) items", tint: Theme.gold)
                    SettingsFeatureLine("Feed discovery and saved favorites", tint: Theme.lavender)
                    SettingsFeatureLine("Multi-cloud simultaneous upload", tint: Theme.skyBlue)
                    SettingsFeatureLine("Audio downloads and subtitles", tint: Theme.lavender)
                }

                freeDownloadsMeter

                GlassTextField(
                    label: "Activation code",
                    placeholder: "VIDDL-LOCAL-…",
                    text: $activationCode,
                    help: "Enter your current personal recovery code."
                )

                Text("Activating rotates the code. Save the new recovery code shown after activation.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)

                if !activationResult.isEmpty {
                    SettingsInlineAlert(
                        text: activationResult,
                        tint: activationResult.hasPrefix("OK") || activationResult.localizedCaseInsensitiveContains("checkout opened") ? Theme.success : Theme.error
                    )
                }

                if !license.lastError.isEmpty {
                    SettingsInlineAlert(text: license.lastError, tint: Theme.error)
                }

                if !recoveryCode.isEmpty {
                    HStack(spacing: 8) {
                        Text(recoveryCode)
                            .font(.system(.caption, design: .monospaced).weight(.bold))
                            .foregroundStyle(Theme.success)
                            .textSelection(.enabled)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("Copy") {
                            ClipboardManager.copy(recoveryCode)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.success.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                HStack(spacing: 8) {
                    Button("Activate Pro") {
                        Task {
                            isActivating = true
                            recoveryCode = license.activatePersonal(code: trimmedActivationCode) ?? ""
                            activationResult = recoveryCode.isEmpty ? "Activation failed." : "OK - Pro activated. Save your new recovery code."
                            isActivating = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isActivating || trimmedActivationCode.isEmpty)

                    if isActivating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .controlSize(.small)
                    }
                }
            }
            .onAppear {
                recoveryCode = ""
            }
            .onChange(of: activationCode) { _, _ in
                activationResult = ""
                recoveryCode = ""
                license.lastError = ""
            }
        }
    }

    private var freeDownloadsMeter: some View {
        let limit = LicenseManager.freeDownloadLimit
        let remaining = max(0, min(limit, license.freeDownloadsRemaining))
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Free downloads remaining")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(remaining) / \(limit)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.gold)
            }

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 5)
                    .fill(Theme.accentDim.opacity(0.55))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(LinearGradient(colors: [Theme.gold, Theme.coral], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * CGFloat(remaining) / CGFloat(limit))
                    }
            }
            .frame(height: 8)
        }
    }

    private var infoSection: some View {
        SettingsCard(tint: Theme.skyBlue) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                SettingsCardTitle(
                    title: "Info",
                    subtitle: "Version and about VidDL.",
                    systemImage: "info.circle.fill",
                    tint: Theme.skyBlue
                )

                SettingsInfoRow(
                    title: "Version",
                    detail: currentVersion,
                    systemImage: "tag.fill",
                    tint: Theme.skyBlue
                )

                SettingsDivider()

                HStack {
                    Spacer()
                    Button("About VidDL") {
                        showAboutWindow()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

}
