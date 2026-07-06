import AppKit
import AVKit
import SwiftUI

private enum FeedCardLayout {
    static let cornerRadius: CGFloat = 12
    static let thumbnailRadius: CGFloat = 10
    static let padding: CGFloat = 9
    static let titleFontSize: CGFloat = 13
    static let titleLineLimit = 2
}

struct FeedCardView: View {
    let item: FeedItem
    let isFavorite: Bool
    let downloadedMatch: DownloadedFeedMatch?
    let isScrolling: Bool
    let toggleFavorite: () -> Void
    let extract: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var previewCoordinator = FeedPreviewCoordinator.shared
    @State private var isHovered = false
    @State private var shouldShowVideoPreview = false
    @State private var hoverPreviewTask: Task<Void, Never>?
    @State private var scrubFraction: CGFloat?
    @State private var previewImages: [String: NSImage] = [:]
    @State private var didRequestPreviewPrefetch = false
    @State private var previewPrefetchTask: Task<Void, Never>?

    init(
        item: FeedItem,
        isFavorite: Bool = false,
        downloadedMatch: DownloadedFeedMatch? = nil,
        isScrolling: Bool = false,
        toggleFavorite: @escaping () -> Void = {},
        extract: @escaping () -> Void
    ) {
        self.item = item
        self.isFavorite = isFavorite
        self.downloadedMatch = downloadedMatch
        self.isScrolling = isScrolling
        self.toggleFavorite = toggleFavorite
        self.extract = extract
    }

    private var tint: Color {
        FeedStudioTint.color(for: item.studio ?? item.siteName)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            cardContent
                .contentShape(RoundedRectangle(cornerRadius: FeedCardLayout.cornerRadius))
                .onTapGesture {
                    extract()
                }

            favoriteButton
                .padding(17)
        }
        .contentShape(RoundedRectangle(cornerRadius: FeedCardLayout.cornerRadius))
        .onHover { hovering in
            handleHover(hovering)
        }
        .onChange(of: previewCoordinator.activeURL) { _, activeURL in
            if activeURL != item.previewVideoURL {
                shouldShowVideoPreview = false
            }
        }
        .onChange(of: isScrolling) { _, scrolling in
            guard scrolling else { return }
            cancelTransientPreviewWork()
        }
        .onDisappear {
            hoverPreviewTask?.cancel()
            hoverPreviewTask = nil
            cancelPreviewPrefetch()
            if previewCoordinator.activeURL == item.previewVideoURL {
                previewCoordinator.clear(url: item.previewVideoURL)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Extracts this video. Use the favorite action to save it."))
        .accessibilityAction(named: Text("Extract")) {
            extract()
        }
        .accessibilityAction(named: Text(isFavorite ? "Remove from Favorites" : "Add to Favorites")) {
            toggleFavorite()
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnailArea

            VStack(alignment: .leading, spacing: 5) {
                Text(FeedDisplay.title(for: item))
                    .font(.system(size: FeedCardLayout.titleFontSize, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(FeedCardLayout.titleLineLimit)
                    .lineSpacing(1)
                    .help(item.title)

                if !metadataChips.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(metadataChips, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary.opacity(0.92))
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Theme.accentDim.opacity(0.22), in: Capsule())
                        }
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 9, weight: .bold))
                    Text(metadataText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(FeedSiteDisplayName.name(for: item.siteName))
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary.opacity(0.95))
            }
        }
        .padding(FeedCardLayout.padding)
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(
            color: .black.opacity(allowsHoverEffects ? 0.30 : 0.16),
            radius: allowsHoverEffects ? 14 : 7,
            x: 0,
            y: allowsHoverEffects ? 7 : 3
        )
        .scaleEffect(allowsHoverEffects && !reduceMotion ? 1.01 : 1)
        .animation(isScrolling || reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.76), value: isHovered)
    }

    private var allowsHoverEffects: Bool {
        isHovered && !isScrolling
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: FeedCardLayout.cornerRadius)
            .fill(Theme.surface1.opacity(0.64))
            .overlay(
                RoundedRectangle(cornerRadius: FeedCardLayout.cornerRadius)
                    .fill(tint.opacity(allowsHoverEffects ? 0.14 : 0.07))
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: FeedCardLayout.cornerRadius)
            .strokeBorder(allowsHoverEffects ? tint.opacity(0.52) : .white.opacity(0.10), lineWidth: allowsHoverEffects ? 1.1 : 0.7)
    }

    private var metadataText: String {
        if item.viewCount > 0 {
            return "\(FeedDisplay.viewCount(item.viewCount)) - \(FeedDisplay.uploadTime(for: item.uploadDate))"
        }
        return FeedDisplay.uploadTime(for: item.uploadDate)
    }

    private var metadataChips: [String] {
        var output: [String] = []
        output.append(contentsOf: item.qualityLabels.prefix(1))
        output.append(contentsOf: item.categories.prefix(1))
        output.append(contentsOf: item.tags.prefix(max(0, 2 - output.count)))
        return output
    }

    private var previewURLs: [String] {
        var output: [String] = []
        func append(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  !output.contains(value) else { return }
            output.append(value)
        }
        append(item.thumbnailURL)
        item.previewURLs.forEach { append($0) }
        return output
    }

    private var activePreviewIndex: Int? {
        let urls = previewURLs
        guard item.previewVideoURL == nil, urls.count > 1, let scrubFraction else { return nil }
        let index = Int((scrubFraction * CGFloat(urls.count)).rounded(.down))
        return min(max(index, 0), urls.count - 1)
    }

    private var activePreviewURL: String? {
        guard let activePreviewIndex else { return nil }
        let urls = previewURLs
        guard urls.indices.contains(activePreviewIndex) else { return nil }
        return urls[activePreviewIndex]
    }

    private var thumbnailArea: some View {
        GeometryReader { proxy in
            ZStack {
                thumbnailImage

                if shouldShowVideoPreview,
                   let previewVideoURL = item.previewVideoURL,
                   previewCoordinator.activeURL == previewVideoURL {
                    PornHubVideoPreview(urlString: previewVideoURL)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    if activePreviewIndex != nil {
                        scrubIndicator
                            .padding(.horizontal, 7)
                            .padding(.bottom, 4)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .transition(.opacity)
                    }
                }
            }
            .onContinuousHover { phase in
                updateScrub(phase, width: proxy.size.width)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: FeedCardLayout.thumbnailRadius))
        .overlay(alignment: .topTrailing) {
            if let uploaderBadge {
                studioBadge(uploaderBadge.name, isPerformer: uploaderBadge.isPerformer)
                    .padding(7)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let duration = item.durationSeconds {
                durationBadge(duration)
                    .padding(7)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let downloadedMatch {
                downloadedBadge(downloadedMatch)
                    .padding(7)
            }
        }
        .help(item.url)
    }

    private var favoriteButton: some View {
        Button(action: toggleFavorite) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isFavorite ? Theme.hotPink : .white)
                .frame(width: 28, height: 28)
                .background(.black.opacity(isFavorite ? 0.48 : 0.34), in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(
                            isFavorite ? Theme.hotPink.opacity(0.75) : .white.opacity(0.22),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
        .accessibilityLabel(Text(isFavorite ? "Remove from Favorites" : "Add to Favorites"))
    }

    private var thumbnailImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: FeedCardLayout.thumbnailRadius)
                .fill(placeholderColor.opacity(0.70))

            if let activePreviewURL,
               let image = previewImages[activePreviewURL] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if let thumbnailURL = item.thumbnailURL,
               let url = URL(string: thumbnailURL) {
                RefererAwareAsyncImage(url: url, referer: item.referer) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.72)
                            .tint(.white)
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
    }

    private var scrubIndicator: some View {
        let urls = previewURLs
        return HStack(spacing: 2) {
            ForEach(urls.indices, id: \.self) { index in
                Capsule()
                    .fill(index == activePreviewIndex ? .white : .white.opacity(0.30))
                    .frame(height: index == activePreviewIndex ? 4 : 3)
            }
        }
        .padding(3)
        .background(.black.opacity(0.36), in: Capsule())
    }

    private var uploaderBadge: (name: String, isPerformer: Bool)? {
        if let studio = item.studio {
            return (studio, false)
        }
        guard item.siteName == PornHubFeedScraper.supportedHost,
              item.studioURL != nil,
              let performer = item.performers.first else { return nil }
        return (performer, true)
    }

    private func studioBadge(_ studio: String, isPerformer: Bool) -> some View {
        Group {
            if let urlString = item.studioURL, let url = URL(string: urlString) {
                Button {
                    Task {
                        await FeedViewModel.shared.navigateToPornHubUploader(url: url.absoluteString, name: studio)
                    }
                } label: {
                    studioBadgeContent(studio, isPerformer: isPerformer)
                }
                .buttonStyle(.plain)
                .help(urlString)
            } else {
                studioBadgeContent(studio, isPerformer: isPerformer)
            }
        }
    }

    private func studioBadgeContent(_ studio: String, isPerformer: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: isPerformer ? "person.crop.circle.fill" : "building.2.fill")
                .font(.system(size: 8, weight: .black))
            Text(studio)
                .lineLimit(1)
        }
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.38), in: Capsule())
    }

    private func durationBadge(_ seconds: Int) -> some View {
        Text(FeedDisplay.duration(seconds))
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.48), in: Capsule())
    }

    private func downloadedBadge(_ match: DownloadedFeedMatch) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .black))
            Text("Downloaded")
                .font(.system(size: 9, weight: .black, design: .rounded))
        }
        .foregroundStyle(Theme.success)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.56), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.success.opacity(0.55), lineWidth: 0.7))
        .help(match.tooltip)
    }

    private var placeholder: some View {
        Text(initials)
            .font(.system(.title2, design: .rounded).weight(.bold))
            .foregroundStyle(.white.opacity(0.82))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var initials: String {
        let value = item.studio ?? FeedDisplay.title(for: item)
        let letters = value
            .split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" })
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
        return letters.isEmpty ? "V" : letters.uppercased()
    }

    private var placeholderColor: Color {
        tint == Theme.textSecondary ? Theme.lavender : tint
    }

    private var accessibilityLabel: String {
        var pieces = [FeedDisplay.title(for: item), item.studio ?? item.siteName, metadataText]
        if let duration = item.durationSeconds {
            pieces.append(FeedDisplay.duration(duration))
        }
        if downloadedMatch != nil {
            pieces.append("downloaded")
        }
        return pieces.joined(separator: ", ")
    }

    private func updateScrub(_ phase: HoverPhase, width: CGFloat) {
        guard item.previewVideoURL == nil, previewURLs.count > 1 else { return }
        switch phase {
        case .active(let location):
            guard width > 0 else { return }
            scrubFraction = min(max(location.x / width, 0), 1)
            if !isScrolling {
                prefetchPreviewImagesIfNeeded()
            }
        case .ended:
            scrubFraction = nil
            cancelPreviewPrefetch()
        }
    }

    private func handleHover(_ hovering: Bool) {
        isHovered = hovering

        if isScrolling {
            cancelTransientPreviewWork()
            return
        }

        guard let previewVideoURL = item.previewVideoURL else {
            if !hovering {
                scrubFraction = nil
                cancelPreviewPrefetch()
            }
            return
        }

        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil

        if hovering {
            hoverPreviewTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, isHovered else { return }
                previewCoordinator.activate(url: previewVideoURL)
                shouldShowVideoPreview = true
            }
        } else {
            shouldShowVideoPreview = false
            previewCoordinator.clear(url: previewVideoURL)
            scrubFraction = nil
            cancelPreviewPrefetch()
        }
    }

    private func prefetchPreviewImagesIfNeeded() {
        guard !didRequestPreviewPrefetch, previewPrefetchTask == nil else { return }
        didRequestPreviewPrefetch = true
        let urls = previewURLs
        let referer = item.referer
        previewPrefetchTask = Task {
            for url in urls {
                guard !Task.isCancelled else { return }
                if let cached = await ThumbnailCache.shared.cachedImage(forIdentity: url) {
                    await MainActor.run { previewImages[url] = cached }
                    continue
                }
                if let image = try? await ThumbnailCache.downloadAndCacheImage(
                    fromImageURL: url,
                    cacheIdentity: url,
                    referer: referer,
                    maxPixelSize: 640
                ) {
                    await MainActor.run { previewImages[url] = image }
                }
            }
            await MainActor.run {
                previewPrefetchTask = nil
            }
        }
    }

    private func cancelPreviewPrefetch() {
        previewPrefetchTask?.cancel()
        previewPrefetchTask = nil
    }

    private func cancelTransientPreviewWork() {
        hoverPreviewTask?.cancel()
        hoverPreviewTask = nil
        shouldShowVideoPreview = false
        scrubFraction = nil
        cancelPreviewPrefetch()
        if let previewVideoURL = item.previewVideoURL {
            previewCoordinator.clear(url: previewVideoURL)
        }
    }

}

@MainActor
private final class FeedPreviewCoordinator: ObservableObject {
    static let shared = FeedPreviewCoordinator()

    @Published private(set) var activeURL: String?

    func activate(url: String) {
        activeURL = url
    }

    func clear(url: String?) {
        guard activeURL == url else { return }
        activeURL = nil
    }
}

private struct PornHubVideoPreview: View {
    let urlString: String

    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .disabled(true)
                    .clipped()
            }
        }
        .onAppear {
            guard player == nil, let url = URL(string: urlString) else { return }
            let headers = [
                "User-Agent": NetworkConstants.chromeUserAgent,
                "Referer": "https://www.pornhub.com/",
            ]
            let asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": headers,
            ])
            let item = AVPlayerItem(asset: asset)
            let nextPlayer = AVPlayer(playerItem: item)
            nextPlayer.isMuted = true
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak nextPlayer] _ in
                nextPlayer?.seek(to: .zero)
                nextPlayer?.play()
            }
            player = nextPlayer
            nextPlayer.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
        }
    }
}

private enum FeedStudioTint {
    static func color(for value: String) -> Color {
        let palette: [Color] = [
            Theme.gold, Theme.coral, Theme.skyBlue, Theme.lavender,
            Theme.hotPink, Theme.electricLime, Theme.taoRed, Theme.success
        ]
        let seed = value.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(seed) % palette.count]
    }
}

private enum FeedSiteDisplayName {
    static func name(for site: String) -> String {
        switch site {
        case AllPornStreamFeedScraper.supportedHost:
            return "AllPornStream"
        case RentryFeedScraper.supportedHost:
            return "OnlyFan420"
        case HQPornerFeedScraper.supportedHost:
            return "HQPorner"
        case EpornerFeedScraper.supportedHost:
            return "Eporner"
        default:
            return site
        }
    }
}
