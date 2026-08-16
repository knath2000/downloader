import AppKit
import SwiftUI

struct VideoResultCard: View {
    let result: ExtractResult
    let isRetrying: Bool
    let localState: (String) -> UploadState?
    let megaState: (String) -> UploadState?
    let gdriveState: (String) -> UploadState?
    let seedboxState: (String) -> UploadState?
    let onRetry: () -> Void
    let onLocal: (String) -> Void
    let onMega: (String) -> Void
    let onGDrive: (String) -> Void
    let onSeedbox: (String) -> Void
    let onMultiple: (String, Set<CloudTarget>) -> Void

    @ObservedObject private var watchlist = WatchlistStore.shared
    @State private var selectedQualityID: String?
    @State private var selectedTarget: CloudTarget = .local
    @State private var selectedDestinations: Set<CloudTarget> = []
    @State private var showsDestinationPicker = false
    @State private var showAdvanced = false

    private var presentation: VideoResultPresentation {
        VideoResultPresentation(result: result)
    }

    private var selectedQuality: VideoQualityChoice? {
        presentation.qualities.first { $0.id == selectedQualityID } ?? presentation.qualities.first
    }

    private var selectedState: UploadState? {
        guard let url = selectedQuality?.url else { return nil }
        switch selectedTarget {
        case .local: return localState(url)
        case .mega: return megaState(url)
        case .gdrive: return gdriveState(url)
        case .seedbox: return seedboxState(url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if result.source != nil {
                controls
                statusLine
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VideoResultRow(
                        result: result,
                        localState: selectedQuality.map { localState($0.url) } ?? nil,
                        megaState: selectedQuality.map { megaState($0.url) } ?? nil,
                        gdriveState: selectedQuality.map { gdriveState($0.url) } ?? nil,
                        seedboxState: selectedQuality.map { seedboxState($0.url) } ?? nil,
                        onLocal: onLocal,
                        onMega: onMega,
                        onGDrive: onGDrive,
                        onSeedbox: onSeedbox
                    )
                    .padding(.top, 6)
                }
                .font(.caption.weight(.semibold))
            } else if let error = result.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(displayError(error))
                        .font(.caption)
                        .foregroundStyle(Theme.error)
                        .fixedSize(horizontal: false, vertical: true)

                    if isRetrying {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Retrying...")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else {
                        Button {
                            onRetry()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(14)
        .glassCard(tint: siteAccentColor(for: result.url).opacity(0.12), cornerRadius: HomeLayoutMetrics.cardCornerRadius)
        .onAppear {
            if selectedQualityID == nil {
                selectedQualityID = presentation.recommendedQualityID
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(presentation.siteName)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    statusPill
                }

                Text(result.url)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(siteAccentColor(for: result.url).opacity(0.16))
                .frame(width: 92, height: 56)

            if let value = presentation.thumbnailURL, let url = URL(string: value) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        fallbackThumbnail
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    @unknown default:
                        fallbackThumbnail
                    }
                }
                .frame(width: 92, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                fallbackThumbnail
            }
        }
    }

    private var fallbackThumbnail: some View {
        Image(systemName: result.error == nil ? "film.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(result.error == nil ? siteAccentColor(for: result.url) : Theme.error)
    }

    private var statusPill: some View {
        let color: Color
        let label: String
        if result.error == nil {
            color = selectedState == nil ? Theme.success : stateColor(selectedState!)
            label = selectedState.map(stateLabel) ?? "Ready"
        } else {
            color = isRetrying ? Theme.skyBlue : Theme.error
            label = isRetrying ? "Retrying" : "Error"
        }
        return Text(label.uppercased())
            .font(.system(size: 9, weight: .black))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                qualityPicker
                targetPicker
                primaryAction
                multipleDestinationButton
                watchlistButton
                copyButton
            }
            VStack(alignment: .leading, spacing: 8) {
                qualityPicker
                targetPicker
                HStack(spacing: 8) {
                    primaryAction
                    multipleDestinationButton
                    watchlistButton
                    copyButton
                }
            }
        }
    }

    private var qualityPicker: some View {
        Picker("Quality", selection: Binding(
            get: { selectedQualityID ?? presentation.recommendedQualityID ?? "" },
            set: { selectedQualityID = $0 }
        )) {
            ForEach(presentation.qualities) { quality in
                Text(quality.label).tag(quality.id)
            }
        }
        .frame(maxWidth: 180)
        .help("Choose video quality")
    }

    private var targetPicker: some View {
        Picker("Target", selection: $selectedTarget) {
            ForEach(DestinationAvailabilityPolicy.newJobTargets, id: \.self) { target in
                Label(target.homeDisplayName, systemImage: target.icon).tag(target)
            }
        }
        .frame(maxWidth: 180)
        .help("Choose download destination")
    }

    private var primaryAction: some View {
        Button {
            guard let url = selectedQuality?.url else { return }
            switch selectedTarget {
            case .local: onLocal(url)
            case .mega: onMega(url)
            case .gdrive: onGDrive(url)
            case .seedbox: onSeedbox(url)
            }
        } label: {
            Label(selectedTarget.homeActionTitle, systemImage: selectedTarget.icon)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.skyBlue)
        .disabled(selectedQuality == nil)
    }

    private var multipleDestinationButton: some View {
        Button {
            showsDestinationPicker = true
        } label: {
            Label("Multiple", systemImage: "square.3.layers.3d.down.right")
        }
        .buttonStyle(.bordered)
        .disabled(selectedQuality == nil)
        .popover(isPresented: $showsDestinationPicker, arrowEdge: .bottom) {
            MultiDestinationPicker(
                selected: $selectedDestinations,
                start: {
                    guard let url = selectedQuality?.url else { return }
                    showsDestinationPicker = false
                    onMultiple(url, selectedDestinations)
                }
            )
        }
    }

    private var copyButton: some View {
        Button {
            if let url = selectedQuality?.url {
                ClipboardManager.copy(url)
            }
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .disabled(selectedQuality == nil)
    }

    private var watchlistButton: some View {
        let isSaved = watchlist.contains(result.url)
        return Button {
            if isSaved {
                watchlist.remove(sourcePageURL: result.url)
            } else if let source = result.source {
                watchlist.add(WatchlistItem(
                    sourcePageURL: result.url,
                    title: source.title ?? result.url,
                    provider: source.siteName ?? URL(string: result.url)?.host ?? "Video",
                    thumbnailURL: source.thumbnail
                ))
            }
        } label: {
            Label(isSaved ? "Saved" : "Watchlist", systemImage: isSaved ? "bookmark.fill" : "bookmark")
        }
        .buttonStyle(.bordered)
        .disabled(result.source == nil)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let selectedState {
            switch selectedState {
            case .uploading(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            case .done(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.success)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.error)
            }
        }
    }

    private func displayError(_ error: String) -> String {
        if error.localizedCaseInsensitiveContains("invalid url") {
            return error
        }
        return "Could not extract video sources from this page."
    }

    private func stateLabel(_ state: UploadState) -> String {
        switch state {
        case .uploading: return "Running"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    private func stateColor(_ state: UploadState) -> Color {
        switch state {
        case .uploading: return Theme.skyBlue
        case .done: return Theme.success
        case .failed: return Theme.error
        }
    }
}

struct MultiDestinationPicker: View {
    @Binding var selected: Set<CloudTarget>
    let start: () -> Void

    private let destinations: [CloudTarget] = [.gdrive, .seedbox]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send to multiple destinations")
                .font(.headline.weight(.semibold))

            ForEach(destinations, id: \.self) { destination in
                Button {
                    if selected.contains(destination) {
                        selected.remove(destination)
                    } else {
                        selected.insert(destination)
                    }
                } label: {
                    Label(destination.homeDisplayName, systemImage: selected.contains(destination) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selected.contains(destination) ? Theme.success : Theme.textPrimary)
                }
                .buttonStyle(.plain)
            }

            Button("Start transfers", action: start)
                .buttonStyle(.borderedProminent)
                .tint(Theme.skyBlue)
                .disabled(selected.isEmpty)
        }
        .padding(16)
        .frame(width: 240)
    }
}
