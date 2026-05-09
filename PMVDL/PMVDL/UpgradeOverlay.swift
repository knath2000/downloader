import SwiftUI

/// Full-screen overlay prompting upgrade when free limits are exceeded.
struct UpgradeOverlay: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "crown.fill")
                    .resizable().scaledToFit()
                    .frame(width: 48, height: 48)
                    .foregroundStyle(Theme.accent)

                Text("Upgrade to Pro")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.textPrimary)
                Text("You have \(LicenseManager.freeDownloadLimit) free downloads.\nUpgrade for unlimited downloads and higher Pro limits.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    FeatureRow(icon: "checkmark.seal.fill", text: "\(LicenseManager.freeDownloadLimit) → unlimited total downloads")
                    FeatureRow(icon: "checkmark.seal.fill", text: "\(ProFeatureGate.freeConcurrentDownloadLimit) → \(ProFeatureGate.proConcurrentDownloadLimit) concurrent downloads")
                    FeatureRow(icon: "checkmark.seal.fill", text: "Batch download more than \(ProFeatureGate.freeBatchLimit) items")
                    FeatureRow(icon: "checkmark.seal.fill", text: "Upload to multiple clouds at once")
                    FeatureRow(icon: "checkmark.seal.fill", text: "Video processing tools")
                    FeatureRow(icon: "checkmark.seal.fill", text: "Audio downloads and subtitles")
                }
                .padding()

                Button("Buy or Activate Pro") {
                    AppStateManager.shared.select(.settings)
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("VidDL Pro — $0.99 one-time")
                    .font(.caption2).foregroundStyle(Theme.textSecondary.opacity(0.6))

                Button("Not now", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(30)
            .frame(maxWidth: 400)
            .background(Theme.surface1)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Theme.accent.opacity(0.4), lineWidth: 1)
            )
        }
    }
}

struct FeatureRow: View {
    let icon: String; let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.success).frame(width: 18)
            Text(text).font(.callout).foregroundStyle(Theme.textPrimary)
            Spacer()
        }
    }
}
