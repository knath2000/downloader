import AppKit
import SwiftUI

enum SettingsLayoutMetrics {
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

enum SettingsPanel: String, CaseIterable, Identifiable {
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
        case .pro: return "LustreStudio Pro"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .cloud: return "Google Drive destination."
        case .notifications: return "Event alerts."
        case .downloads: return "Saving, subtitles, and tools."
        case .pro: return "License and unlocks."
        case .about: return "Version and app info."
        }
    }

    var modalSubtitle: String {
        switch self {
        case .cloud: return "Configure the Google Drive destination used by the background Agent."
        case .notifications: return "Choose which LustreStudio events can notify you."
        case .downloads: return "Fine-tune downloads, subtitles, sleep prevention, and helper tools."
        case .pro: return "Manage your LustreStudio Pro purchase and activation."
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

struct SettingsTile: View {
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
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .mobileCard(tint: panel.color.opacity(isEmphasized ? 0.26 : 0.16), cornerRadius: MobileMetrics.cardRadius, isElevated: isEmphasized)
        .contentShape(RoundedRectangle(cornerRadius: MobileMetrics.cardRadius, style: .continuous))
    }
}

struct SettingsModalSurface<Content: View>: View {
    let panel: SettingsPanel
    let tint: Color
    let content: Content

    init(
        panel: SettingsPanel,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.panel = panel
        self.tint = tint
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

struct SettingsCard<Content: View>: View {
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

struct SettingsCardTitle: View {
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

struct SettingsFieldRow<Content: View>: View {
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

struct GlassTextField: View {
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

struct SettingsHelpText: View {
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

struct SettingsDependencySummary: View {
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

struct SettingsDependencyInlineRow: View {
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

struct GDriveSetupStatusCard: View {
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

struct RcloneSeedboxSetupCard: View {
    let phase: RcloneRemoteSetupPhase
    let message: String
    let tint: Color
    let remoteName: String
    let isRunning: Bool
    let start: () -> Void
    let useExisting: () -> Void
    let cancel: () -> Void
    let retry: () -> Void
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.bold)).foregroundStyle(Theme.textPrimary)
                    Text(message).font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if isRunning { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 8) {
                switch phase {
                case .idle, .ready:
                    Button("Connect SFTP", action: start).buttonStyle(.borderedProminent).tint(tint).controlSize(.small)
                    Button("Refresh", action: refresh).buttonStyle(.bordered).controlSize(.small)
                case .existingRemote:
                    Button("Use Existing", action: useExisting).buttonStyle(.borderedProminent).tint(tint).controlSize(.small)
                    Button("Refresh", action: refresh).buttonStyle(.bordered).controlSize(.small)
                case .authorizing, .verifying:
                    Button("Cancel", action: cancel).buttonStyle(.bordered).controlSize(.small)
                case .configured:
                    Label("\(remoteName): ready", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(Theme.success)
                    Button("Refresh", action: refresh).buttonStyle(.bordered).controlSize(.small)
                case .missingRclone, .failed:
                    Button("Retry", action: retry).buttonStyle(.borderedProminent).tint(tint).controlSize(.small)
                    Button("Refresh", action: refresh).buttonStyle(.bordered).controlSize(.small)
                }
            }
            if case .missingRclone = phase { SettingsCommandRow(command: "brew install rclone") }
            if case .failed(let detail) = phase { SettingsInlineAlert(text: detail, tint: Theme.error) }
        }
        .padding(10)
        .background(Theme.surface2.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.18), lineWidth: 0.5))
    }

    private var title: String {
        switch phase {
        case .configured: return "Seedbox SFTP is ready"
        case .missingRclone: return "rclone is required"
        case .existingRemote: return "SFTP remote already exists"
        case .authorizing: return "Connecting to SFTP"
        case .verifying: return "Verifying SFTP remote"
        case .failed: return "SFTP setup failed"
        case .idle, .ready: return "Connect a seedbox over SFTP"
        }
    }

    private var icon: String {
        switch phase {
        case .configured: return "checkmark.circle.fill"
        case .missingRclone, .failed: return "exclamationmark.triangle.fill"
        default: return "server.rack"
        }
    }
}

struct SettingsCommandRow: View {
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

struct SettingsToggleRow: View {
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


struct SettingsInfoRow<Action: View>: View {
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

struct SettingsFeatureLine: View {
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

struct SettingsInlineAlert: View {
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

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.border.opacity(0.55))
            .frame(height: 0.5)
    }
}
