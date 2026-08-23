import SwiftUI

enum SettingsLayoutMetrics {
    static let contentMaxWidth: CGFloat = 720
    static let rowSpacing: CGFloat = 12
    static let cardCornerRadius: CGFloat = 14
    static let controlCornerRadius: CGFloat = 9
}

struct SettingsCard<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(tint: tint.opacity(0.12), cornerRadius: SettingsLayoutMetrics.cardCornerRadius)
    }
}

struct SettingsCardTitle: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var status: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(.headline.weight(.bold))
                    if let status {
                        Text(status.uppercased())
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(tint)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
    }
}

struct SettingsFieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}

struct GlassTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let help: String

    var body: some View {
        SettingsFieldRow(label) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.surface1.opacity(0.45), in: RoundedRectangle(cornerRadius: SettingsLayoutMetrics.controlCornerRadius))
                .help(help)
        }
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
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
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
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
    }
}

struct SettingsInlineAlert: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().overlay(Theme.borderSubtle.opacity(0.6))
    }
}
