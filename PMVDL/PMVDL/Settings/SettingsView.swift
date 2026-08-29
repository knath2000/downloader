import AppKit
import SwiftUI

struct SettingsView: View {
    let onUpgradeRequired: () -> Void

    @AppStorage("downloadSubtitles") private var downloadSubtitles = false
    @AppStorage("embeddedSubsMode") private var embeddedSubsMode = false
    @AppStorage(AppPreferenceKeys.preventSleepWhileRunning) private var preventSleepWhileRunning = false
    @AppStorage(DownloadPaths.customDownloadDirectoryKey) private var customDownloadDirectory = ""
    @StateObject private var license = LicenseManager.shared
    @StateObject private var shortcuts = ShortcutManager.shared
    @State private var activationCode = ""
    @State private var activationResult = ""
    @State private var recoveryCode = ""
    @State private var shortcutCapture: ShortcutCaptureTarget?

    init(onUpgradeRequired: @escaping () -> Void = {}) {
        self.onUpgradeRequired = onUpgradeRequired
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                downloadCard
                notificationCard
                shortcutsCard
                licenseCard
                aboutCard
            }
            .frame(maxWidth: SettingsLayoutMetrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(18)
        }
    }

    private var downloadCard: some View {
        SettingsCard(tint: Theme.gold) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                SettingsCardTitle(
                    title: "Downloads",
                    subtitle: "Local and Mega download behavior.",
                    systemImage: "arrow.down.circle.fill",
                    tint: Theme.gold
                )
                SettingsToggleRow(
                    title: "Auto-download subtitles",
                    subtitle: ProFeatureGate.canDownloadSubtitles ? "Fetch subtitles when available." : "Requires LustreStudio Pro.",
                    systemImage: "captions.bubble.fill",
                    tint: Theme.skyBlue,
                    isOn: Binding(
                        get: { downloadSubtitles },
                        set: { enabled in
                            if enabled && !ProFeatureGate.canDownloadSubtitles {
                                onUpgradeRequired()
                            } else {
                                downloadSubtitles = enabled
                            }
                        }
                    )
                )
                SettingsDivider()
                SettingsToggleRow(
                    title: "Prevent sleep while running",
                    subtitle: "Keep this Mac awake while downloads are active.",
                    systemImage: "moon.zzz.fill",
                    tint: Theme.lavender,
                    isOn: $preventSleepWhileRunning
                )
                if downloadSubtitles && ProFeatureGate.canDownloadSubtitles {
                    SettingsDivider()
                    Picker("Subtitle mode", selection: $embeddedSubsMode) {
                        Text("Sidecar files").tag(false)
                        Text("Embedded").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                SettingsDivider()
                SettingsFieldRow("Location") {
                    HStack {
                        Text(DownloadPaths.downloadDir.path)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Browse", action: browseForDownloadLocation)
                        Button("Open") {
                            DownloadPaths.ensureDownloadDir()
                            NSWorkspace.shared.open(DownloadPaths.downloadDir)
                        }
                        if DownloadPaths.hasCustomDownloadDir {
                            Button("Reset") {
                                customDownloadDirectory = ""
                                DownloadPaths.resetCustomDownloadDir()
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var notificationCard: some View {
        SettingsCard(tint: Theme.amber) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                SettingsCardTitle(
                    title: "Notifications",
                    subtitle: "Choose which events should notify you.",
                    systemImage: "bell.badge.fill",
                    tint: Theme.amber
                )
                notificationToggle("Download complete", type: .uploadComplete, tint: Theme.success)
                SettingsDivider()
                notificationToggle("Download failed", type: .uploadFailed, tint: Theme.error)
                SettingsDivider()
                notificationToggle("Extraction complete", type: .scrapeComplete, tint: Theme.skyBlue)
            }
        }
    }

    private func notificationToggle(
        _ title: String,
        type: NotificationManager.EventType,
        tint: Color
    ) -> some View {
        SettingsToggleRow(
            title: title,
            subtitle: "Show a macOS notification.",
            systemImage: "bell.fill",
            tint: tint,
            isOn: Binding(
                get: { NotificationManager.shared.isEnabled(type) },
                set: { NotificationManager.shared.setEnabled(type, enabled: $0) }
            )
        )
    }

    @ViewBuilder
    private var licenseCard: some View {
        SettingsCard(tint: ProFeatureGate.isPro ? Theme.success : Theme.coral) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                SettingsCardTitle(
                    title: "LustreStudio Pro",
                    subtitle: ProFeatureGate.isPro ? "Activated on this Mac." : "\(license.freeDownloadsRemaining) free downloads remaining.",
                    systemImage: "crown.fill",
                    tint: ProFeatureGate.isPro ? Theme.success : Theme.coral,
                    status: ProFeatureGate.isPro ? "Active" : nil
                )
                if ProFeatureGate.isPro {
                    SettingsFeatureLine("Unlimited downloads", tint: Theme.success)
                    SettingsFeatureLine("Batch downloads, Feed, audio, and subtitles", tint: Theme.success)
                    Button("Deactivate") {
                        license.deactivateLocalLicense()
                    }
                    .buttonStyle(.bordered)
                } else {
                    GlassTextField(
                        label: "Activation code",
                        placeholder: "VIDDL-LOCAL-…",
                        text: $activationCode,
                        help: "Enter your personal recovery code."
                    )
                    if !activationResult.isEmpty {
                        SettingsInlineAlert(text: activationResult, tint: recoveryCode.isEmpty ? Theme.error : Theme.success)
                    }
                    if !recoveryCode.isEmpty {
                        HStack {
                            Text(recoveryCode)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("Copy") { ClipboardManager.copy(recoveryCode) }
                        }
                    }
                    Button("Activate Pro") {
                        recoveryCode = license.activatePersonal(code: activationCode) ?? ""
                        activationResult = recoveryCode.isEmpty
                            ? "Activation failed."
                            : "Pro activated. Save the new recovery code."
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(activationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var shortcutsCard: some View {
        SettingsCard(tint: Theme.success) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                SettingsCardTitle(
                    title: "Keyboard Shortcuts",
                    subtitle: "Customize app-wide shortcuts. Press the record button then type the new combination.",
                    systemImage: "command",
                    tint: Theme.success
                )

                VStack(spacing: 6) {
                    ForEach(ShortcutAction.allCases) { action in
                        ShortcutRow(
                            action: action,
                            isCapturing: shortcutCapture == action,
                            beginCapture: { shortcutCapture = action },
                            cancelCapture: { shortcutCapture = nil },
                            capture: { key, mods in
                                if let action = shortcutCapture {
                                    if action.isSystemReserved {
                                        // Don't let users unbind Quit on macOS — fall back to default.
                                        ToastQueue.shared.warning("'\(action.title)' uses a system reserved shortcut and cannot be changed.")
                                    } else {
                                        shortcuts.set(action, key: key, modifiers: mods)
                                    }
                                }
                                shortcutCapture = nil
                            },
                            reset: { shortcuts.reset(action) }
                        )
                    }
                }

                SettingsDivider()

                HStack {
                    Spacer()
                    Button("Reset All to Defaults") {
                        shortcuts.resetAll()
                        ToastQueue.shared.info("Keyboard shortcuts restored to defaults.")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var aboutCard: some View {
        SettingsCard(tint: Theme.skyBlue) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.rowSpacing) {
                SettingsCardTitle(
                    title: "About",
                    subtitle: "LustreStudio \(version)",
                    systemImage: "info.circle.fill",
                    tint: Theme.skyBlue
                )
                Button("About LustreStudio", action: showAboutWindow)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?.?.?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func browseForDownloadLocation() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Location"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = DownloadPaths.downloadDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customDownloadDirectory = url.path
        DownloadPaths.setCustomDownloadDir(url)
    }
}

// MARK: - Keyboard Shortcuts UI

/// Identifies which shortcut action is being re-recorded.
typealias ShortcutCaptureTarget = ShortcutAction

private struct ShortcutRow: View {
    let action: ShortcutAction
    let isCapturing: Bool
    let beginCapture: () -> Void
    let cancelCapture: () -> Void
    let capture: (KeyEquivalent, EventModifiers) -> Void
    let reset: () -> Void

    @StateObject private var manager = ShortcutManager.shared
    @State private var recordingError: String?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if action.isSystemReserved {
                    Text("Reserved by system")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Default: \(ShortcutManager.format(key: action.defaultKey, modifiers: action.defaultModifiers))")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()

            if isCapturing {
                Text("Press shortcut…")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.warning.opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.warning.opacity(0.5), lineWidth: 1))
                    .onKeyPress { press in
                        let key = press.key
                        let mods = press.modifiers
                        if mods.isEmpty && key == .escape {
                            cancelCapture()
                            return .handled
                        }
                        if mods.isEmpty { return .ignored }
                        capture(key, mods)
                        return .handled
                    }
                    .frame(minWidth: 110)
            } else {
                Text(manager.displayString(for: action))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.surface2.opacity(0.6), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.textSecondary.opacity(0.3), lineWidth: 0.5))
                    .frame(minWidth: 110)
            }

            Button(action: isCapturing ? cancelCapture : beginCapture) {
                Image(systemName: isCapturing ? "xmark.circle.fill" : "pencil.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isCapturing ? Theme.error : Theme.success)
            }
            .buttonStyle(.plain)
            .help(isCapturing ? "Cancel" : "Record new shortcut")

            Button(action: reset) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(manager.overrides[action] == nil)
            .help("Reset to default")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface1.opacity(isCapturing ? 0.95 : 0.7))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                    isCapturing ? Theme.warning.opacity(0.5) : .white.opacity(0.06),
                    lineWidth: 0.8
                ))
        )
    }
}
