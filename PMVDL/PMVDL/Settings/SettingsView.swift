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
    @AppStorage("downloadSubtitles") private var downloadSubtitles = false
    @AppStorage("embeddedSubsMode") private var embeddedSubsMode = false
    @StateObject private var license = LicenseManager.shared
    @StateObject private var updater = UpdateManager.shared
    @StateObject private var dependencyStore = SettingsDependencyStore.shared
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

    private func color(for tone: SettingsDependencyTone) -> Color {
        switch tone {
        case .checking: return Theme.textSecondary
        case .success:  return Theme.success
        case .warning:  return Theme.warning
        case .error:    return Theme.error
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.groupSpacing) {
                SettingsPageHeader(
                    isRefreshing: dependencyStore.isRefreshing,
                    refreshAction: {
                        Task { await dependencyStore.refresh(input: dependencyInput, force: true) }
                    }
                )

                cloudDestinationsGroup
                appPreferencesGroup
            }
            .frame(maxWidth: SettingsLayoutMetrics.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, SettingsLayoutMetrics.pageHorizontalPadding)
            .padding(.top, SettingsLayoutMetrics.pageTopPadding)
            .padding(.bottom, SettingsLayoutMetrics.pageBottomPadding)
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

    private var cloudDestinationsGroup: some View {
        VStack(alignment: .leading, spacing: SettingsLayoutMetrics.cardSpacing) {
            SettingsGroupHeader(
                "Cloud Destinations",
                subtitle: "Configure where completed downloads are uploaded."
            )

            megaUploadSection
            googleDriveUploadSection
            seedboxTransferSection
        }
    }

    private var appPreferencesGroup: some View {
        VStack(alignment: .leading, spacing: SettingsLayoutMetrics.cardSpacing) {
            SettingsGroupHeader(
                "App Preferences",
                subtitle: "Notifications, download helpers, updates, extensions, and license information."
            )

            notificationsSection
            downloadOptionsSection
            updatesSection
            extensionsSection
            licenseSection
            aboutSection
        }
    }

    private var megaUploadSection: some View {
        SettingsSectionCard(
            title: "Mega Upload",
            subtitle: "Upload completed Mega transfers into a MEGAcmd folder.",
            systemImage: "cloud.fill",
            tint: Theme.success
        ) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                megaSetupCard

                SettingsFieldRow(
                    "Remote path",
                    help: "VidDL uploads completed Mega transfers into this folder after MEGAcmd is installed and signed in."
                ) {
                    TextField("/Cloud/VidDL/", text: $megaRemotePath)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var googleDriveUploadSection: some View {
        SettingsSectionCard(
            title: "Google Drive Upload",
            subtitle: "Use rclone to upload completed files to a Google Drive remote.",
            systemImage: "externaldrive.fill.badge.checkmark",
            tint: Theme.skyBlue
        ) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                gdriveSetupCard

                SettingsFieldRow(
                    "Remote name",
                    help: "The remote name must match the Google Drive remote created in rclone."
                ) {
                    TextField("gdrive", text: $gdriveRemoteName)
                        .textFieldStyle(.roundedBorder)
                }

                SettingsFieldRow("Remote path") {
                    TextField("VidDL/", text: $gdriveRemotePath)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var seedboxTransferSection: some View {
        SettingsSectionCard(
            title: "Seedbox Transfer",
            subtitle: "Stream direct downloads to a seedbox via rclone or WebDAV.",
            systemImage: "server.rack",
            tint: Theme.lavender
        ) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                seedboxSetupCard

                SettingsFieldRow("Transfer mode") {
                    Picker("Transfer Mode", selection: $seedboxTransferMode) {
                        Text("rclone rcat").tag("rclone")
                        Text("WebDAV PUT").tag("webdav")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                seedboxModeFields
                seedboxTestConnectionRow
            }
        }
    }

    @ViewBuilder
    private var seedboxModeFields: some View {
        if seedboxTransferMode == "webdav" {
            SettingsFieldRow("WebDAV URL") {
                TextField("https://example.com/webdav", text: $seedboxWebdavURL)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsFieldRow("Username") {
                TextField("Username", text: $seedboxWebdavUser)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsFieldRow("Password") {
                SecureField("Password", text: $seedboxWebdavPassword)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsFieldRow(
                "Remote path",
                help: "Direct video URLs upload with native WebDAV PUT. HLS, yt-dlp, and audio fall back to local assembly and need the rclone remote below."
            ) {
                TextField("/", text: $seedboxRemotePath)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsFieldRow("Fallback remote") {
                TextField("seedbox", text: $seedboxRemoteName)
                    .textFieldStyle(.roundedBorder)
            }
        } else {
            SettingsFieldRow("Remote name") {
                TextField("seedbox", text: $seedboxRemoteName)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsFieldRow(
                "Remote path",
                help: "The remote name must match any rclone remote for your seedbox, such as SFTP, FTP, WebDAV, or S3."
            ) {
                TextField("/", text: $seedboxRemotePath)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var seedboxTestConnectionRow: some View {
        SettingsFieldRow("Connection") {
            VStack(alignment: .leading, spacing: 6) {
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
                    Text(seedboxTestResult)
                        .font(.caption)
                        .foregroundStyle(seedboxTestSucceeded == true ? Theme.success : Theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var notificationsSection: some View {
        SettingsSectionCard(
            title: "Notifications",
            subtitle: "Choose which VidDL events should notify you.",
            systemImage: "bell.badge.fill",
            tint: Theme.amber
        ) {
            VStack(alignment: .leading, spacing: 8) {
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
            .toggleStyle(.checkbox)
        }
    }

    private var downloadOptionsSection: some View {
        SettingsSectionCard(
            title: "Download Options",
            subtitle: "Configure download behavior and helper tools.",
            systemImage: "arrow.down.circle.fill",
            tint: Theme.coral
        ) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                Toggle("Auto-download subtitles", isOn: $downloadSubtitles)
                    .toggleStyle(.checkbox)

                if downloadSubtitles {
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
                    }
                }

                SettingsDependencyInlineRow(
                    model: dependencyModel.ytDlp,
                    color: color(for: dependencyModel.ytDlp.tone)
                )

                SettingsDependencyInlineRow(
                    model: dependencyModel.ffmpeg,
                    color: color(for: dependencyModel.ffmpeg.tone)
                )

                Button("Open Downloads Folder") {
                    DownloadPaths.ensureDownloadDir()
                    NSWorkspace.shared.open(DownloadPaths.downloadDir)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var updatesSection: some View {
        SettingsSectionCard(
            title: "Updates",
            subtitle: "Check the installed VidDL version.",
            systemImage: "arrow.triangle.2.circlepath",
            tint: Theme.skyBlue
        ) {
            HStack(spacing: 12) {
                Text("Current: \(updater.currentVersion)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 12)
                Button("Check for Updates") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var extensionsSection: some View {
        SettingsSectionCard(
            title: "Extensions",
            subtitle: "Browser and share-sheet integrations.",
            systemImage: "safari.fill",
            tint: Theme.lavender
        ) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Safari Extension", value: "Install via Safari > Extensions")
                LabeledContent("Share Extension", value: "Available in Share menu")
            }
            .font(.caption)
            .frame(maxWidth: SettingsLayoutMetrics.fieldMaxWidth, alignment: .leading)
        }
    }

    @ViewBuilder
    private var licenseSection: some View {
        if !ProFeatureGate.isPro {
            SettingsSectionCard(
                title: "Upgrade to Pro",
                subtitle: "Unlock VidDL Pro features with a one-time purchase.",
                systemImage: "crown.fill",
                tint: Theme.gold
            ) {
                upgradeToProContent
            }
        } else {
            SettingsSectionCard(
                title: "Pro License",
                subtitle: "Your local Pro activation state.",
                systemImage: "checkmark.seal.fill",
                tint: Theme.success
            ) {
                proLicenseContent
            }
        }
    }

    private var upgradeToProContent: some View {
        VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
            HStack(spacing: 8) {
                Image(systemName: "crown.fill").foregroundStyle(Theme.gold)
                Text("VidDL Pro - $0.99 one-time")
                    .font(.subheadline.bold())
                    .foregroundStyle(Theme.textPrimary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("- Unlimited batch downloads")
                Text("- Multi-cloud simultaneous upload")
                Text("- Priority support")
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)

            SettingsFieldRow(
                "Email",
                help: "Enter the email to use for your Pro license."
            ) {
                TextField("Email", text: $activateEmail)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            if !activationResult.isEmpty {
                Text(activationResult)
                    .font(.caption)
                    .foregroundStyle(activationResult.hasPrefix("OK") ? Theme.success : Theme.error)
            }

            if !license.lastError.isEmpty {
                Text(license.lastError)
                    .font(.caption)
                    .foregroundStyle(Theme.error)
            }

            Text("Free downloads remaining: \(license.freeDownloadsRemaining)")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 8) {
                Button("Buy Pro") {
                    Task {
                        isActivating = true
                        let ok = await license.startCheckout(email: trimmedActivationEmail)
                        activationResult = ok ? "Checkout opened. After payment, return here or click Open VidDL on the success page." : "Checkout failed."
                        isActivating = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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
            }
        }
        .frame(maxWidth: SettingsLayoutMetrics.fieldMaxWidth, alignment: .leading)
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

    private var proLicenseContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Theme.success)
            Text("Pro activated for \(license.activationEmail)")
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Button("Deactivate") {
                license.deactivateLocalLicense()
                activationResult = "License deactivated."
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: SettingsLayoutMetrics.fieldMaxWidth, alignment: .leading)
    }

    private var aboutSection: some View {
        SettingsSectionCard(
            title: "About",
            systemImage: "info.circle.fill",
            tint: Theme.textSecondary
        ) {
            Button("About VidDL") { showAboutWindow() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var megaSetupCard: some View {
        SettingsDependencyCard(model: dependencyModel.mega, color: color(for: dependencyModel.mega.tone))
    }

    private var gdriveSetupCard: some View {
        SettingsDependencyCard(model: dependencyModel.gdrive, color: color(for: dependencyModel.gdrive.tone))
    }

    private var seedboxSetupCard: some View {
        SettingsDependencyCard(model: dependencyModel.seedbox, color: color(for: dependencyModel.seedbox.tone))
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
    static let contentMaxWidth: CGFloat = 1080
    static let pageHorizontalPadding: CGFloat = 28
    static let pageTopPadding: CGFloat = 24
    static let pageBottomPadding: CGFloat = 36
    static let groupSpacing: CGFloat = 22
    static let cardSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 10
    static let innerPadding: CGFloat = 16
    static let labelWidth: CGFloat = 138
    static let fieldMaxWidth: CGFloat = 720
    static let cardCornerRadius: CGFloat = 16
    static let controlCornerRadius: CGFloat = 10
    static let iconBoxSize: CGFloat = 34
}

private struct SettingsPageHeader: View {
    let isRefreshing: Bool
    let refreshAction: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalContent
            verticalContent
        }
        .padding(SettingsLayoutMetrics.innerPadding)
        .glassCard(tint: Theme.accent.opacity(0.18), cornerRadius: SettingsLayoutMetrics.cardCornerRadius)
    }

    private var horizontalContent: some View {
        HStack(alignment: .center, spacing: 16) {
            headerIcon
            headerText
            Spacer(minLength: 16)
            refreshButton
        }
    }

    private var verticalContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                headerIcon
                headerText
            }
            refreshButton
        }
    }

    private var headerIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.accent.opacity(0.18))
                .frame(width: 42, height: 42)
            Image(systemName: "gearshape.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.accent)
        }
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cloud & App Settings")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Configure upload destinations, download helpers, notifications, and app options.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var refreshButton: some View {
        HStack(spacing: 8) {
            if isRefreshing {
                ProgressView()
                    .scaleEffect(0.7)
                    .controlSize(.small)
            }

            Button(action: refreshAction) {
                Label("Refresh Checks", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRefreshing)
        }
    }
}

private struct SettingsGroupHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing + 2) {
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
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)
            }

            content
        }
        .padding(SettingsLayoutMetrics.innerPadding)
        .glassCard(tint: tint.opacity(0.12), cornerRadius: SettingsLayoutMetrics.cardCornerRadius)
    }
}

private struct SettingsFieldRow<Content: View>: View {
    let title: String
    let help: String?
    let content: Content

    init(
        _ title: String,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.help = help
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            verticalLayout
        }
    }

    private var horizontalLayout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: SettingsLayoutMetrics.labelWidth, alignment: .trailing)

            VStack(alignment: .leading, spacing: 5) {
                content
                    .frame(maxWidth: SettingsLayoutMetrics.fieldMaxWidth, alignment: .leading)
                if let help {
                    SettingsHelpText(help)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)

            content
                .frame(maxWidth: .infinity, alignment: .leading)

            if let help {
                SettingsHelpText(help)
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
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsDependencyCard: View {
    let icon: String
    let title: String
    let status: String
    let detail: String
    let command: String?
    let footnote: String
    let color: Color
    let isReady: Bool

    init(model: SettingsDependencyCardModel, color: Color) {
        self.icon = model.icon
        self.title = model.title
        self.status = model.status
        self.detail = model.detail
        self.command = model.command
        self.footnote = model.footnote
        self.color = color
        self.isReady = model.isReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(isReady ? 0.16 : 0.22))
                        .frame(width: SettingsLayoutMetrics.iconBoxSize, height: SettingsLayoutMetrics.iconBoxSize)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)

                        Text(status.uppercased())
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(color.opacity(0.16), in: Capsule())
                    }

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let command {
                SettingsCommandRow(command: command)
            }

            SettingsHelpText(footnote)
        }
        .padding(12)
        .background(Theme.surface2.opacity(0.20), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(isReady ? 0.25 : 0.45), lineWidth: 1)
        )
        .frame(maxWidth: SettingsLayoutMetrics.fieldMaxWidth, alignment: .leading)
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
        .background(Theme.surface2.opacity(0.20), in: RoundedRectangle(cornerRadius: SettingsLayoutMetrics.controlCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.controlCornerRadius)
                .stroke((isReady ? Theme.success : color).opacity(0.25), lineWidth: 1)
        )
        .frame(maxWidth: SettingsLayoutMetrics.fieldMaxWidth, alignment: .leading)
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
        .frame(maxWidth: SettingsLayoutMetrics.fieldMaxWidth, alignment: .leading)
    }
}
