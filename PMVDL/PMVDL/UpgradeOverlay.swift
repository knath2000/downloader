import SwiftUI

/// Full-screen overlay prompting upgrade when free limits are exceeded.
struct UpgradeOverlay: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "crown.fill")
                    .resizable().scaledToFit()
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.yellow)

                Text("Upgrade to Pro").font(.title2.bold())
                Text("Unlock unlimited batch downloads, scheduling,\nand multi-cloud upload.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    FeatureRow(icon: "checkmark.seal.fill", text: "Unlimited batch downloads")
                    FeatureRow(icon: "checkmark.seal.fill", text: "Schedule downloads")
                    FeatureRow(icon: "checkmark.seal.fill", text: "Multi-cloud simultaneous upload")
                    FeatureRow(icon: "checkmark.seal.fill", text: "Priority support")
                }
                .padding()

                Button("Activate License") {
                    // Navigate to settings tab
                    AppStateManager.shared.select(.settings)
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("7-day free trial: 10 downloads included")
                    .font(.caption2).foregroundStyle(.tertiary)

                Button("Not now", action: onDismiss)
                    .buttonStyle(.plain).font(.caption)
            }
            .padding(30)
            .frame(maxWidth: 400)
            .background(Color(nsColor: .windowBackgroundColor).cornerRadius(16))
        }
    }
}

struct FeatureRow: View {
    let icon: String; let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(.green).frame(width: 18)
            Text(text).font(.callout)
            Spacer()
        }
    }
}
