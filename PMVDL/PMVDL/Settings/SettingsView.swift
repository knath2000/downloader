import AppKit
import SwiftUI

struct SettingsView: View {
    @Binding var gdriveRemoteName: String
    @Binding var gdriveRemotePath: String
    @Binding var megaRemotePath: String
    @Binding var seedboxTransferMode: String
    @Binding var seedboxRemoteName: String
    @Binding var seedboxRemotePath: String
    @Binding var seedboxWebdavURL: String
    @Binding var seedboxWebdavUser: String
    @Binding var seedboxWebdavPassword: String
    let onUpgradeRequired: () -> Void

    @AppStorage("downloadSubtitles") private var downloadSubtitles = false
    @AppStorage("embeddedSubsMode") private var embeddedSubsMode = false
    @AppStorage("xaiAPIKey") private var xaiAPIKey = ""
    @AppStorage(AppPreferenceKeys.preventSleepWhileRunning) private var preventSleepWhileRunning = false

    @StateObject private var license = LicenseManager.shared
    @StateObject private var dependencyStore = SettingsDependencyStore.shared

    @State private var activeSection: SettingsSection = .cloud
    @State private var selectedCloudDestination: CloudSettingsDestination = .mega
    @State private var activateEmail = ""
    @State private var activationResult = ""
    @State private var isActivating = false
    @State private var seedboxTestResult = ""
    @State private var seedboxTestSucceeded: Bool?
    @State private var isTestingSeedboxConnection = false

    private var trimmedActivationEmail: String {
        activateEmail.trimmingCharacters(in: .whitespacesAndNewlines)
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
        ScrollViewReader { proxy in
            VStack(spacing: 12) {
                SettingsJumpToolbar(
                    activeSection: activeSection,
                    isRefreshing: dependencyStore.isRefreshing,
                    refreshAction: refreshDependencyChecks,
                    jumpAction: { section in
                        activeSection = section
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            proxy.scrollTo(section.id, anchor: .top)
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        settingsSection(.cloud) {
                            cloudSection
                        }

                        settingsSection(.preferences) {
                            preferencesSection
                        }

                        settingsSection(.ai) {
                            aiSection
                        }

                        settingsSection(.pro) {
                            proSection
                        }

                        settingsSection(.info) {
                            infoSection
                        }
                    }
                    .frame(maxWidth: SettingsLayoutMetrics.contentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 28)
                }
            }
            .background(keyboardShortcuts(proxy: proxy))
        }
        .task(id: dependencyInput) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { return }
            await dependencyStore.refresh(input: dependencyInput)
        }
        .onChange(of: seedboxTransferMode) { _, _ in
            seedboxTestResult = ""
            seedboxTestSucceeded = nil
        }
    }

    private func refreshDependencyChecks() {
        Task { await dependencyStore.refresh(input: dependencyInput, force: true) }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ section: SettingsSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(section: section)
            content()
        }
        .id(section.id)
        .onAppear { activeSection = section }
    }

    private func keyboardShortcuts(proxy: ScrollViewProxy) -> some View {
        Group {
            Button("") {
                jump(to: .cloud, proxy: proxy)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("") {
                jump(to: .preferences, proxy: proxy)
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("") {
                jump(to: .ai, proxy: proxy)
            }
            .keyboardShortcut("3", modifiers: .command)

            Button("") {
                jump(to: .pro, proxy: proxy)
            }
            .keyboardShortcut("4", modifiers: .command)

            Button("") {
                jump(to: .info, proxy: proxy)
            }
            .keyboardShortcut("5", modifiers: .command)

            Button("") {
                refreshDependencyChecks()
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func jump(to section: SettingsSection, proxy: ScrollViewProxy) {
        activeSection = section
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            proxy.scrollTo(section.id, anchor: .top)
        }
    }

    private var cloudSection: some View {
        let model = selectedCloudModel
        let tint = color(for: model.tone)

        return SettingsCard(tint: tint) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                SettingsCardTitle(
                    title: selectedCloudDestination.fullTitle,
                    subtitle: selectedCloudDestination.subtitle,
                    systemImage: selectedCloudDestination.systemImage,
                    tint: tint,
                    status: model.status
                )

                SettingsFieldRow("Destination") {
                    Picker("Cloud destination", selection: $selectedCloudDestination) {
                        ForEach(CloudSettingsDestination.allCases) { destination in
                            Label(destination.title, systemImage: destination.systemImage)
                                .tag(destination)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 460)
                }

                SettingsDependencySummary(model: model, color: tint)
                selectedCloudDestinationFields
            }
        }
    }

    private var selectedCloudModel: SettingsDependencyCardModel {
        switch selectedCloudDestination {
        case .mega:
            return dependencyModel.mega
        case .gdrive:
            return dependencyModel.gdrive
        case .seedbox:
            return dependencyModel.seedbox
        }
    }

    @ViewBuilder
    private var selectedCloudDestinationFields: some View {
        switch selectedCloudDestination {
        case .mega:
            GlassTextField(
                label: "Remote path",
                placeholder: "/Cloud/VidDL/",
                text: $megaRemotePath,
                help: "VidDL uploads completed Mega transfers into this folder after MEGAcmd is installed and signed in."
            )
        case .gdrive:
            GlassTextField(
                label: "Remote name",
                placeholder: "gdrive",
                text: $gdriveRemoteName,
                help: "The remote name must match the Google Drive remote created in rclone."
            )
            GlassTextField(
                label: "Remote path",
                placeholder: "VidDL/",
                text: $gdriveRemotePath
            )
        case .seedbox:
            SettingsFieldRow("Transfer mode") {
                Picker("Transfer Mode", selection: $seedboxTransferMode) {
                    Text("rclone rcat").tag("rclone")
                    Text("WebDAV PUT").tag("webdav")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
            }

            seedboxModeFields
            seedboxTestConnectionRow
        }
    }

    @ViewBuilder
    private var seedboxModeFields: some View {
        if seedboxTransferMode == "webdav" {
            GlassTextField(label: "WebDAV URL", placeholder: "https://example.com/webdav", text: $seedboxWebdavURL)
            GlassTextField(label: "Username", placeholder: "Username", text: $seedboxWebdavUser)
            GlassSecureField(label: "Password", placeholder: "Password", text: $seedboxWebdavPassword)
            GlassTextField(
                label: "Remote path",
                placeholder: "/",
                text: $seedboxRemotePath,
                help: "Direct video URLs upload with native WebDAV PUT. HLS, yt-dlp, and audio fall back to local assembly and need the rclone remote below."
            )
            GlassTextField(label: "Fallback remote", placeholder: "seedbox", text: $seedboxRemoteName)
        } else {
            GlassTextField(label: "Remote name", placeholder: "seedbox", text: $seedboxRemoteName)
            GlassTextField(
                label: "Remote path",
                placeholder: "/",
                text: $seedboxRemotePath,
                help: "The remote name must match any rclone remote for your seedbox, such as SFTP, FTP, WebDAV, or S3."
            )
        }
    }

    private var seedboxTestConnectionRow: some View {
        SettingsFieldRow("Connection") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Button {
                        Task { await testSeedboxConnection() }
                    } label: {
                        Label("Test Connection", systemImage: "network")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isTestingSeedboxConnection)

                    if isTestingSeedboxConnection {
                        ProgressView()
                            .scaleEffect(0.65)
                            .controlSize(.small)
                    }
                }

                if !seedboxTestResult.isEmpty {
                    SettingsInlineAlert(
                        text: seedboxTestResult,
                        tint: seedboxTestSucceeded == true ? Theme.success : Theme.error
                    )
                }
            }
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

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            notificationsCard
            downloadBehaviorCard
        }
    }

    private var aiSection: some View {
        SettingsCard(tint: Theme.gold) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                SettingsCardTitle(
                    title: "AI Profile",
                    subtitle: "xAI API key for Grok-powered taste profiles.",
                    systemImage: "brain.head.profile",
                    tint: Theme.gold,
                    status: XAIClient.model
                )

                GlassSecureField(
                    label: "xAI API Key",
                    placeholder: "xai-...",
                    text: $xaiAPIKey,
                    help: "Get a key at x.ai/api."
                )

                SettingsFieldRow("Model") {
                    Text(XAIClient.model)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Theme.surface2.opacity(0.16), in: RoundedRectangle(cornerRadius: SettingsLayoutMetrics.controlCornerRadius))
                }

                HStack {
                    Spacer()
                    Button {
                        AppStateManager.shared.select(.profile)
                        Task { await ProfileViewModel.shared.generate() }
                    } label: {
                        Label("Generate Profile", systemImage: "person.crop.circle.badge.sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.gold)
                    .controlSize(.small)
                }
            }
        }
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
                        subtitle: "Keep this Mac awake while downloads, uploads, or processing jobs are active.",
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

                    Button {
                        DownloadPaths.ensureDownloadDir()
                        NSWorkspace.shared.open(DownloadPaths.downloadDir)
                    } label: {
                        Label("Open Downloads Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
                    subtitle: "Activated for \(license.activationEmail.isEmpty ? "this Mac" : license.activationEmail)",
                    systemImage: "crown.fill",
                    tint: Theme.success,
                    status: "Active"
                )

                VStack(alignment: .leading, spacing: 7) {
                    SettingsFeatureLine("Unlimited total downloads", tint: Theme.success)
                    SettingsFeatureLine("\(ProFeatureGate.proConcurrentDownloadLimit) concurrent downloads", tint: Theme.success)
                    SettingsFeatureLine("Batch download more than \(ProFeatureGate.freeBatchLimit) items", tint: Theme.success)
                    SettingsFeatureLine("Multi-cloud simultaneous upload", tint: Theme.success)
                    SettingsFeatureLine("Video processing tools", tint: Theme.success)
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
                    title: "Upgrade to Pro",
                    subtitle: "Unlock VidDL Pro features with a one-time purchase.",
                    systemImage: "crown.fill",
                    tint: Theme.coral
                )

                HStack(spacing: 9) {
                    Text("VidDL Pro")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(Theme.textPrimary)
                    Text("$0.99 one-time")
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
                    SettingsFeatureLine("Multi-cloud simultaneous upload", tint: Theme.skyBlue)
                    SettingsFeatureLine("Video processing tools", tint: Theme.coral)
                    SettingsFeatureLine("Audio downloads and subtitles", tint: Theme.lavender)
                }

                freeDownloadsMeter

                GlassTextField(
                    label: "Email",
                    placeholder: "you@example.com",
                    text: $activateEmail,
                    help: "Enter the email to use for your Pro license."
                )

                if !activationResult.isEmpty {
                    SettingsInlineAlert(
                        text: activationResult,
                        tint: activationResult.hasPrefix("OK") || activationResult.localizedCaseInsensitiveContains("checkout opened") ? Theme.success : Theme.error
                    )
                }

                if !license.lastError.isEmpty {
                    SettingsInlineAlert(text: license.lastError, tint: Theme.error)
                }

                HStack(spacing: 8) {
                    MarketplaceButton(title: "Buy Pro", icon: "crown.fill") {
                        Task {
                            isActivating = true
                            let ok = await license.startCheckout(email: trimmedActivationEmail)
                            activationResult = ok ? "Checkout opened. After payment, return here or click Open VidDL on the success page." : "Checkout failed."
                            isActivating = false
                        }
                    }
                    .frame(width: 180)
                    .disabled(isActivating || trimmedActivationEmail.isEmpty)

                    Button("Activate Pro") {
                        Task {
                            isActivating = true
                            let ok = await license.activate(email: trimmedActivationEmail)
                            activationResult = ok ? "OK - Pro activated." : "No active Pro license found."
                            isActivating = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isActivating || trimmedActivationEmail.isEmpty)

                    if isActivating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .controlSize(.small)
                    }
                }
            }
            .onAppear {
                if activateEmail.isEmpty {
                    activateEmail = license.activationEmail
                }
            }
            .onChange(of: activateEmail) { _, _ in
                activationResult = ""
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

    private func testSeedboxConnection() async {
        isTestingSeedboxConnection = true
        seedboxTestResult = ""
        seedboxTestSucceeded = nil
        do {
            let manager = SeedboxManager(mode: try seedboxModeForTesting())
            try await manager.testConnection()
            seedboxTestSucceeded = true
            seedboxTestResult = "OK - seedbox connection succeeded."
        } catch {
            seedboxTestSucceeded = false
            seedboxTestResult = error.localizedDescription
        }
        isTestingSeedboxConnection = false
        await dependencyStore.refresh(input: dependencyInput, force: true)
    }

    private func seedboxModeForTesting() throws -> SeedboxTransferMode {
        if seedboxTransferMode == "webdav" {
            let trimmed = seedboxWebdavURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let base = URL(string: trimmed) else { throw SeedboxError.notConfigured }
            return .webdav(baseURL: base, user: seedboxWebdavUser, password: seedboxWebdavPassword, remotePath: seedboxRemotePath)
        }
        return .rclone(remoteName: dependencyInput.resolvedSeedboxRemoteName, remotePath: seedboxRemotePath)
    }
}

private enum SettingsLayoutMetrics {
    static let contentMaxWidth: CGFloat = 720
    static let rowSpacing: CGFloat = 12
    static let innerPadding: CGFloat = 16
    static let labelWidth: CGFloat = 118
    static let cardCornerRadius: CGFloat = 14
    static let controlCornerRadius: CGFloat = 9
    static let iconBoxSize: CGFloat = 34
}

private enum CloudSettingsDestination: String, CaseIterable, Identifiable {
    case mega
    case gdrive
    case seedbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mega: return "Mega"
        case .gdrive: return "Drive"
        case .seedbox: return "Seedbox"
        }
    }

    var fullTitle: String {
        switch self {
        case .mega: return "Mega Upload"
        case .gdrive: return "Google Drive Upload"
        case .seedbox: return "Seedbox Transfer"
        }
    }

    var subtitle: String {
        switch self {
        case .mega: return "Upload completed downloads into a MEGAcmd folder."
        case .gdrive: return "Use rclone to upload completed files to a Google Drive remote."
        case .seedbox: return "Stream direct downloads to a seedbox via rclone or WebDAV."
        }
    }

    var systemImage: String {
        switch self {
        case .mega: return "cloud.fill"
        case .gdrive: return "externaldrive.fill.badge.checkmark"
        case .seedbox: return "server.rack"
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case cloud
    case preferences
    case ai
    case pro
    case info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloud: return "Cloud"
        case .preferences: return "Preferences"
        case .ai: return "AI"
        case .pro: return "Pro"
        case .info: return "Info"
        }
    }

    var fullTitle: String {
        switch self {
        case .cloud: return "Cloud Destinations"
        case .preferences: return "Preferences"
        case .ai: return "AI Profile"
        case .pro: return "Pro"
        case .info: return "Info"
        }
    }

    var subtitle: String {
        switch self {
        case .cloud: return "Choose and configure one upload destination at a time."
        case .preferences: return "Notifications, download behavior, and helper tools."
        case .ai: return "xAI API key for Grok-powered taste profiles."
        case .pro: return "Your VidDL Pro license."
        case .info: return "Version and about VidDL."
        }
    }

    var icon: String {
        switch self {
        case .cloud: return "cloud.fill"
        case .preferences: return "slider.horizontal.3"
        case .ai: return "brain.head.profile"
        case .pro: return "crown.fill"
        case .info: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .cloud: return Theme.electricLime
        case .preferences: return Theme.gold
        case .ai: return Theme.gold
        case .pro: return Theme.coral
        case .info: return Theme.skyBlue
        }
    }
}

private struct SettingsJumpToolbar: View {
    let activeSection: SettingsSection
    let isRefreshing: Bool
    let refreshAction: () -> Void
    let jumpAction: (SettingsSection) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontal
            vertical
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(tint: Theme.lavender.opacity(0.15), cornerRadius: SettingsLayoutMetrics.cardCornerRadius)
    }

    private var horizontal: some View {
        HStack(spacing: 8) {
            sectionButtons
            Spacer(minLength: 10)
            refreshControl
        }
    }

    private var vertical: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionButtons
                Spacer(minLength: 0)
            }
            refreshControl
        }
    }

    private var sectionButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        jumpAction(section)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: section.icon)
                                .font(.system(size: 10, weight: .bold))
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(activeSection == section ? .white : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(activeSection == section ? section.color.opacity(0.85) : Theme.accentDim.opacity(0.30), in: Capsule())
                        .overlay(Capsule().strokeBorder(section.color.opacity(activeSection == section ? 0.25 : 0.16), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: 470)
    }

    private var refreshControl: some View {
        HStack(spacing: 8) {
            if isRefreshing {
                ProgressView()
                    .scaleEffect(0.65)
                    .controlSize(.small)
            }

            Button(action: refreshAction) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh dependency and cloud status checks")
            .disabled(isRefreshing)
        }
    }
}

private struct SettingsSectionHeader: View {
    let section: SettingsSection

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(section.color.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: section.icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(section.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(section.fullTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(section.subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let tint: Color
    let content: Content

    init(tint: Color, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(SettingsLayoutMetrics.innerPadding)
            .glassCard(tint: tint.opacity(0.12), cornerRadius: SettingsLayoutMetrics.cardCornerRadius)
    }
}

private struct SettingsCardTitle: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var status: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let status {
                Text(status.uppercased())
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.16), in: Capsule())
            }
        }
    }
}

private struct SettingsFieldRow<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: SettingsLayoutMetrics.labelWidth, alignment: .trailing)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct GlassTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var help: String?

    var body: some View {
        SettingsFieldRow(label) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.accentDim.opacity(0.25), in: RoundedRectangle(cornerRadius: SettingsLayoutMetrics.controlCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsLayoutMetrics.controlCornerRadius)
                            .strokeBorder(Theme.border, lineWidth: 0.5)
                    )
                    .frame(maxWidth: .infinity)

                if let help {
                    SettingsHelpText(help)
                }
            }
        }
    }
}

private struct GlassSecureField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var help: String?

    var body: some View {
        SettingsFieldRow(label) {
            VStack(alignment: .leading, spacing: 4) {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.accentDim.opacity(0.25), in: RoundedRectangle(cornerRadius: SettingsLayoutMetrics.controlCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsLayoutMetrics.controlCornerRadius)
                            .strokeBorder(Theme.border, lineWidth: 0.5)
                    )
                    .frame(maxWidth: .infinity)

                if let help {
                    SettingsHelpText(help)
                }
            }
        }
    }
}

private struct SettingsHelpText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(Theme.textSecondary.opacity(0.78))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsDependencySummary: View {
    let icon: String
    let title: String
    let detail: String
    let command: String?
    let footnote: String
    let color: Color

    init(model: SettingsDependencyCardModel, color: Color) {
        self.icon = model.icon
        self.title = model.title
        self.detail = model.detail
        self.command = model.command
        self.footnote = model.footnote
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let command {
                SettingsCommandRow(command: command)
            }

            SettingsHelpText(footnote)
        }
        .padding(10)
        .background(Theme.surface2.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SettingsDependencyInlineRow: View {
    let title: String
    let status: String
    let detail: String
    let command: String?
    let isReady: Bool
    let isChecking: Bool
    let color: Color

    init(model: SettingsDependencyInlineModel, color: Color) {
        self.title = model.title
        self.status = model.status
        self.detail = model.detail
        self.command = model.command
        self.isReady = model.isReady
        self.isChecking = model.isChecking
        self.color = color
    }

    private var statusColor: Color {
        isChecking ? Theme.textSecondary : (isReady ? Theme.success : Theme.warning)
    }

    private var statusIcon: String {
        if isChecking { return "hourglass" }
        return isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .frame(width: 16)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(status.uppercased())
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(statusColor)
                Spacer(minLength: 8)
            }

            Text(detail)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let command {
                SettingsCommandRow(command: command)
            }
        }
        .padding(10)
        .background(Theme.surface2.opacity(0.14), in: RoundedRectangle(cornerRadius: SettingsLayoutMetrics.controlCornerRadius))
    }
}

private struct SettingsCommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 11, design: .monospaced).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            Button {
                ClipboardManager.copy(command)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}


private struct SettingsInfoRow<Action: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let action: Action

    init(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder action: () -> Action
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.action = action()
    }

    init(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color
    ) where Action == EmptyView {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.action = EmptyView()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 10)
            action
        }
        .padding(.vertical, 3)
    }
}

private struct SettingsFeatureLine: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct SettingsInlineAlert: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border.opacity(0.55))
            .frame(height: 0.5)
    }
}
