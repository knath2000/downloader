import SwiftUI

struct HomeHeroHeader: View {
    let isYtDlpReady: Bool
    let isPro: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("brandLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .shadow(color: Theme.skyBlue.opacity(0.18), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("VidDL")
                    .font(.system(.title2, design: .rounded).weight(.black))
                    .foregroundStyle(Theme.textPrimary)

                Text("Paste URLs, extract video sources, then download locally or send to cloud storage.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    HomeStatusPill(
                        label: isYtDlpReady ? "yt-dlp ready" : "Install yt-dlp",
                        systemImage: isYtDlpReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        color: isYtDlpReady ? Theme.success : Theme.warning
                    )
                    if isPro {
                        HomeStatusPill(label: "Pro", systemImage: "crown.fill", color: Theme.gold)
                    }
                    HomeStatusPill(label: "Cmd+Return", systemImage: "keyboard", color: Theme.skyBlue)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard(tint: Theme.skyBlue.opacity(0.10), cornerRadius: HomeLayoutMetrics.cardCornerRadius)
    }
}

struct HomeStatusPill: View {
    let label: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }
}
