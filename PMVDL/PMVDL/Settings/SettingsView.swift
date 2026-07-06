import AppKit
import SwiftUI

struct SettingsView: View {
    @Binding var gdriveRemoteName: String
    @Binding var gdriveRemotePath: String
    let onUpgradeRequired: () -> Void

    @AppStorage("downloadSubtitles") private var downloadSubtitles = false
    @AppStorage("embeddedSubsMode") private var embeddedSubsMode = false
    @AppStorage(AppPreferenceKeys.preventSleepWhileRunning) private var preventSleepWhileRunning = false
    @AppStorage(DownloadPaths.customDownloadDirectoryKey) private var customDownloadDirectory = ""

    @StateObject private var license = LicenseManager.shared
    @StateObject private var dependencyStore = SettingsDependencyStore.shared
    @StateObject private var gdriveSetup = RcloneRemoteSetupViewModel()

    @State private var activateEmail = ""
    @State private var activationResult = ""
    @State private var isActivating = false
    @State private var showsGDriveManualFields = false
    @State private var activePanel: SettingsPanel?

    private var trimmedActivationEmail: String {
        activateEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var dependencyInput: SettingsDependencyInput {
        SettingsDependencyInput(
            gdriveRemoteName: gdriveRemoteName,
            seedboxTransferMode: "rclone",
            seedboxRemoteName: "",
            seedboxWebdavURL: ""
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
    }

    private var settingsLandingPage: some View {
        ScrollView {
            LazyVGrid(columns: SettingsLayoutMetrics.tileColumns, alignment: .leading, spacing: 12) {
                ForEach(SettingsPanel.allCases) { panel in
                    Button {
                        activePanel = panel
                    } label: {
                        SettingsTile(
                            panel: panel,
                            detail: tileDetail(for: panel),
                            status: tileStatus(for: panel),
                            isEmphasized: panel == .cloud && dependencyModel.gdrive.tone != .success
                        )
                    }
                    .buttonStyle(.plain)
                    .pressEffect(scale: 0.985)
                }
            }
            .frame(maxWidth: SettingsLayoutMetrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
    }

    private func tileDetail(for panel: SettingsPanel) -> String {
        switch panel {
        case .cloud:
            return dependencyModel.gdrive.detail
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
            return dependencyModel.gdrive.status
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
        SettingsModalSurface(panel: panel, tint: panelTint(for: panel), dismiss: { activePanel = nil }) {
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

        return SettingsCard(tint: tint) {
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
                    subtitle: "Activated for \(license.activationEmail.isEmpty ? "this Mac" : license.activationEmail)",
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
                    SettingsFeatureLine("Feed discovery and saved favorites", tint: Theme.lavender)
                    SettingsFeatureLine("Multi-cloud simultaneous upload", tint: Theme.skyBlue)
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

}

private enum SettingsLayoutMetrics {
    static let contentMaxWidth: CGFloat = 720
    static let rowSpacing: CGFloat = 12
    static let innerPadding: CGFloat = 16
    static let labelWidth: CGFloat = 118
    static let cardCornerRadius: CGFloat = 14
    static let controlCornerRadius: CGFloat = 9
    static let iconBoxSize: CGFloat = 34
    static let tileColumns = [
        GridItem(.adaptive(minimum: 240, maximum: 352), spacing: 12, alignment: .top)
    ]
}

private enum SettingsPanel: String, CaseIterable, Identifiable {
    case cloud
    case notifications
    case downloads
    case pro
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloud: return "Cloud Destination"
        case .notifications: return "Notifications"
        case .downloads: return "Downloads & Helpers"
        case .pro: return "VidDL Pro"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .cloud: return "Google Drive upload remote."
        case .notifications: return "Event alerts."
        case .downloads: return "Saving, subtitles, and tools."
        case .pro: return "License and unlocks."
        case .about: return "Version and app info."
        }
    }

    var modalSubtitle: String {
        switch self {
        case .cloud: return "Configure the Google Drive remote used after downloads finish."
        case .notifications: return "Choose which VidDL events can notify you."
        case .downloads: return "Fine-tune downloads, subtitles, sleep prevention, and helper tools."
        case .pro: return "Manage your VidDL Pro purchase and activation."
        case .about: return "Check the installed version and open the system About panel."
        }
    }

    var icon: String {
        switch self {
        case .cloud: return "cloud.fill"
        case .notifications: return "bell.badge.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .pro: return "crown.fill"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .cloud: return Theme.electricLime
        case .notifications: return Theme.amber
        case .downloads: return Theme.gold
        case .pro: return Theme.coral
        case .about: return Theme.skyBlue
        }
    }
}

private struct SettingsTile: View {
    let panel: SettingsPanel
    let detail: String
    let status: String?
    let isEmphasized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(panel.color.opacity(0.16))
                        .frame(width: 32, height: 32)
                    Image(systemName: panel.icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(panel.color)
                }

                Spacer(minLength: 8)

                if let status {
                    Text(status.uppercased())
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(panel.color)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(panel.color.opacity(0.13), in: Capsule())
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(panel.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(detail.isEmpty ? panel.subtitle : detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(Theme.obsidian.opacity(0.58), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isEmphasized ? panel.color.opacity(0.28) : Theme.borderSubtle, lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SettingsModalSurface<Content: View>: View {
    let panel: SettingsPanel
    let tint: Color
    let dismiss: () -> Void
    let content: Content

    init(
        panel: SettingsPanel,
        tint: Color,
        dismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.panel = panel
        self.tint = tint
        self.dismiss = dismiss
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .frame(width: 36, height: 36)
                    Image(systemName: panel.icon)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(panel.title)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(panel.modalSubtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 10)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .background(Theme.surfaceGlass.opacity(0.58), in: Circle())
                .overlay(Circle().strokeBorder(Theme.borderSubtle, lineWidth: 0.6))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .background(Theme.obsidian.opacity(0.68))

            SettingsDivider()

            content
        }
        .background(Theme.obsidian.opacity(0.94), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.8)
        )
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

private struct GDriveSetupStatusCard: View {
    let phase: RcloneRemoteSetupPhase
    let message: String
    let tint: Color
    let remoteName: String
    let isRunning: Bool
    let start: () -> Void
    let useExisting: () -> Void
    let reconnect: () -> Void
    let cancel: () -> Void
    let retry: () -> Void
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }

            actionRow
        }
        .padding(10)
        .background(Theme.surface2.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.18), lineWidth: 0.5))
    }

    private var title: String {
        switch phase {
        case .idle, .ready:
            return "Connect Google Drive"
        case .missingRclone:
            return "rclone is required"
        case .existingRemote:
            return "Remote already exists"
        case .authorizing:
            return "Google sign-in in progress"
        case .verifying:
            return "Verifying remote"
        case .configured:
            return "Google Drive is ready"
        case .failed:
            return "Setup failed"
        }
    }

    private var icon: String {
        switch phase {
        case .configured:
            return "checkmark.circle.fill"
        case .missingRclone, .failed:
            return "exclamationmark.triangle.fill"
        case .existingRemote:
            return "externaldrive.badge.questionmark"
        case .authorizing, .verifying:
            return "arrow.triangle.2.circlepath"
        case .idle, .ready:
            return "g.circle.fill"
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch phase {
        case .missingRclone:
            VStack(alignment: .leading, spacing: 8) {
                SettingsCommandRow(command: "brew install rclone")
                Button {
                    refresh()
                } label: {
                    Label("Refresh Checks", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .existingRemote:
            HStack(spacing: 8) {
                Button {
                    useExisting()
                } label: {
                    Label("Use Existing", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .controlSize(.small)

                Button {
                    reconnect()
                } label: {
                    Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .authorizing, .verifying:
            Button {
                cancel()
            } label: {
                Label("Cancel Setup", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .configured:
            HStack(spacing: 8) {
                Button {
                    refresh()
                } label: {
                    Label("Refresh Checks", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("\(remoteName):")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                if case .failed(let detail) = phase {
                    SettingsInlineAlert(text: detail, tint: Theme.error)
                }
                HStack(spacing: 8) {
                    Button {
                        retry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .controlSize(.small)

                    Button {
                        refresh()
                    } label: {
                        Label("Refresh Checks", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        case .idle, .ready:
            Button {
                start()
            } label: {
                Label("Connect Google Drive", systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .controlSize(.small)
        }
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
