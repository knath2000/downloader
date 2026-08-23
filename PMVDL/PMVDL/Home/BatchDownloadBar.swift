import SwiftUI

extension CloudTarget {
    var homeDisplayName: String {
        switch self {
        case .local: return "Local"
        case .mega: return "Mega"
        case .gdrive, .seedbox: return "Unavailable"
        }
    }

    var homeBatchButtonTitle: String {
        switch self {
        case .local: return "Download All to Local"
        case .mega: return "Send All to Mega"
        case .gdrive, .seedbox: return "Destination Unavailable"
        }
    }

    var homeActionTitle: String {
        switch self {
        case .local: return "Download"
        case .mega: return "Send to Mega"
        case .gdrive, .seedbox: return "Destination Unavailable"
        }
    }
}

struct BatchDownloadBar: View {
    let queuedCount: Int
    @Binding var selectedTarget: CloudTarget
    let isSubmitting: Bool
    let progressText: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(queuedCount) queued")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(isSubmitting ? progressText : "Batch download extracted results.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Picker("Batch target", selection: $selectedTarget) {
                ForEach(DestinationAvailabilityPolicy.newJobTargets, id: \.self) { target in
                    Label(target.homeDisplayName, systemImage: target.icon).tag(target)
                }
            }
            .labelsHidden()
            .frame(width: 132)
            .help("Choose destination for all queued downloads")

            Button(action: action) {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("Adding")
                } else {
                    Label(selectedTarget.homeBatchButtonTitle, systemImage: selectedTarget.icon)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.skyBlue)
            .disabled(isSubmitting || queuedCount == 0)
        }
        .padding(14)
        .glassCard(tint: Theme.skyBlue.opacity(0.10), cornerRadius: HomeLayoutMetrics.cardCornerRadius)
    }
}
