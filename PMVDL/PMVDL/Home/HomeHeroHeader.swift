import SwiftUI

struct HomeHeroHeader: View {
    let inputModel: HomeURLInputModel
    let resultCount: Int
    let queuedCount: Int
    let isYtDlpReady: Bool
    let isPro: Bool
    @Binding var showingStatusPopover: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("brandLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .shadow(color: Theme.skyBlue.opacity(0.18), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("LustreStudio")
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

            statusButton
        }
        .padding(16)
        .glassCard(tint: Theme.skyBlue.opacity(0.10), cornerRadius: HomeLayoutMetrics.cardCornerRadius)
    }

    private var statusButton: some View {
        Button {
            showingStatusPopover.toggle()
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Label("Status", systemImage: "checklist")
                    Text(statusSummaryText)
                        .foregroundStyle(Theme.textSecondary)
                }
                Label("Status", systemImage: "checklist")
                Image(systemName: "checklist")
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(statusAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(statusAccent.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(statusAccent.opacity(0.24), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Show Home status")
        .popover(isPresented: $showingStatusPopover, arrowEdge: .bottom) {
            HomeStatusRail(
                inputModel: inputModel,
                resultCount: resultCount,
                queuedCount: queuedCount,
                isYtDlpReady: isYtDlpReady,
                isPro: isPro,
                width: HomeLayoutMetrics.statusPopoverWidth
            )
            .padding(12)
        }
    }

    private var statusSummaryText: String {
        if inputModel.invalidLines.isEmpty {
            return "\(inputModel.readyCount) ready · \(resultCount) results"
        }
        return "\(inputModel.invalidLines.count) needs attention"
    }

    private var statusAccent: Color {
        if !inputModel.invalidLines.isEmpty || !isYtDlpReady {
            return Theme.warning
        }
        return Theme.skyBlue
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
