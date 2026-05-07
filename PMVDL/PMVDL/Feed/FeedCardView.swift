import AppKit
import SwiftUI

private enum FeedCardLayout {
    static let cornerRadius: CGFloat = 16
    static let thumbnailRadius: CGFloat = 13
    static let padding: CGFloat = 10
    static let titleFontSize: CGFloat = 13
    static let titleLineLimit = 2
}

struct FeedCardView: View {
    let item: FeedItem
    let isFavorite: Bool
    let toggleFavorite: () -> Void
    let extract: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(
        item: FeedItem,
        isFavorite: Bool = false,
        toggleFavorite: @escaping () -> Void = {},
        extract: @escaping () -> Void
    ) {
        self.item = item
        self.isFavorite = isFavorite
        self.toggleFavorite = toggleFavorite
        self.extract = extract
    }

    private var tint: Color {
        FeedStudioTint.color(for: item.studio ?? item.siteName)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: extract) {
                cardContent
            }
            .buttonStyle(.plain)

            favoriteButton
                .padding(17)
        }
        .contentShape(RoundedRectangle(cornerRadius: FeedCardLayout.cornerRadius))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Extract") { extract() }
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                toggleFavorite()
            }

            Divider()

            Button("Copy Link") { ClipboardManager.copy(item.url) }
            Button("Open in Browser") { openInBrowser() }
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
        .shadow(color: .black.opacity(isHovered ? 0.30 : 0.16), radius: isHovered ? 14 : 7, x: 0, y: isHovered ? 7 : 3)
        .scaleEffect(isHovered && !reduceMotion ? 1.01 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.76), value: isHovered)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: FeedCardLayout.cornerRadius)
            .fill(Theme.surface1.opacity(0.64))
            .overlay(
                RoundedRectangle(cornerRadius: FeedCardLayout.cornerRadius)
                    .fill(tint.opacity(isHovered ? 0.14 : 0.07))
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: FeedCardLayout.cornerRadius)
            .strokeBorder(isHovered ? tint.opacity(0.52) : .white.opacity(0.10), lineWidth: isHovered ? 1.1 : 0.7)
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

    private var thumbnailArea: some View {
        ZStack {
            thumbnailImage

            if isHovered {
                hoverOverlay
                    .transition(.opacity)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: FeedCardLayout.thumbnailRadius))
        .overlay(alignment: .topTrailing) {
            if let studio = item.studio {
                studioBadge(studio)
                    .padding(7)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let duration = item.durationSeconds {
                durationBadge(duration)
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

            if let thumbnailURL = item.thumbnailURL,
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

    private var hoverOverlay: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.10), .black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )

            Button(action: extract) {
                Label("Extract", systemImage: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(tint.opacity(0.84), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func studioBadge(_ studio: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
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
        return pieces.joined(separator: ", ")
    }

    private func openInBrowser() {
        guard let url = URL(string: item.url) else { return }
        NSWorkspace.shared.open(url)
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
        default:
            return site
        }
    }
}
