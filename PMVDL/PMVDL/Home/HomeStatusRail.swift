import SwiftUI

struct HomeStatusRail: View {
    let inputModel: HomeURLInputModel
    let resultCount: Int
    let queuedCount: Int
    let isYtDlpReady: Bool
    let isPro: Bool
    var width: CGFloat = HomeLayoutMetrics.statusRailWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            railCard(title: "Input", systemImage: "link") {
                metric("\(inputModel.readyCount)", label: "ready")
                if !inputModel.invalidLines.isEmpty {
                    metric("\(inputModel.invalidLines.count)", label: "need attention", color: Theme.warning)
                }
            }

            railCard(title: "Results", systemImage: "film.stack") {
                metric("\(resultCount)", label: "extracted")
                metric("\(queuedCount)", label: "batch ready")
            }

            railCard(title: "Status", systemImage: "checklist") {
                HomeStatusPill(
                    label: isYtDlpReady ? "yt-dlp ready" : "yt-dlp missing",
                    systemImage: isYtDlpReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    color: isYtDlpReady ? Theme.success : Theme.warning
                )
                if isPro {
                    HomeStatusPill(label: "Pro active", systemImage: "crown.fill", color: Theme.gold)
                }
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    private func railCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard(tint: Theme.surface2.opacity(0.18), cornerRadius: 14)
    }

    private func metric(_ value: String, label: String, color: Color = Theme.skyBlue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.title3.weight(.heavy))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
