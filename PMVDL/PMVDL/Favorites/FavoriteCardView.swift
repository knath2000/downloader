import AppKit
import SwiftUI

struct FavoriteCardView: View {
    let item: FeedFavoriteItem
    let extract: () -> Void
    let openSource: () -> Void
    let copyLink: () -> Void
    let remove: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: extract) {
                cardContent
            }
            .buttonStyle(.plain)

            removeButton
                .padding(17)
        }
        .scaleEffect(isHovered && !reduceMotion ? 1.012 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72), value: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onHover { isHovered = $0 }
        .appContextMenu(
            title: item.title,
            subtitle: item.url,
            accent: Theme.hotPink,
            actions: [
                AppContextMenuAction("Extract", systemImage: "bolt.fill", action: extract),
                AppContextMenuAction("Copy Link", systemImage: "doc.on.doc", action: copyLink),
                AppContextMenuAction("Open in Browser", systemImage: "safari", action: openSource),
                AppContextMenuAction("Remove from Favorites", systemImage: "heart.slash", role: .destructive, action: remove)
            ]
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(item.siteName), \(item.title), \(metadataText)"))
        .accessibilityAction(named: Text("Remove from Favorites")) {
            remove()
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnailArea

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .help(item.title)

                if !chips.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(chips, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary.opacity(0.94))
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Theme.hotPink.opacity(0.18), in: Capsule())
                        }
                    }
                }

                Text(metadataText)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.surface1.opacity(0.64))
                .overlay(RoundedRectangle(cornerRadius: 16).fill(Theme.hotPink.opacity(isHovered ? 0.14 : 0.07)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isHovered ? Theme.hotPink.opacity(0.52) : .white.opacity(0.10), lineWidth: isHovered ? 1.1 : 0.7)
        )
        .shadow(color: .black.opacity(isHovered ? 0.30 : 0.16), radius: isHovered ? 14 : 7, x: 0, y: isHovered ? 7 : 3)
    }

    private var thumbnailArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13)
                .fill(Theme.hotPink.opacity(0.20))

            if let thumbnailURL = item.thumbnailURL,
               let url = URL(string: thumbnailURL) {
                RefererAwareAsyncImage(url: url, referer: item.referer) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
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

            if isHovered {
                LinearGradient(
                    colors: [.black.opacity(0.05), .black.opacity(0.54)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .transition(.opacity)

                Label("Extract", systemImage: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.hotPink.opacity(0.82), in: Capsule())
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(alignment: .bottomLeading) {
            if let durationSeconds = item.durationSeconds {
                Text(FavoritesDisplay.duration(durationSeconds))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.48), in: Capsule())
                    .padding(7)
            }
        }
    }

    private var removeButton: some View {
        Button(action: remove) {
            Image(systemName: "heart.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.hotPink)
                .frame(width: 28, height: 28)
                .background(.black.opacity(0.42), in: Circle())
                .overlay(Circle().strokeBorder(Theme.hotPink.opacity(0.62), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .help("Remove from Favorites")
        .accessibilityLabel(Text("Remove from Favorites"))
    }

    private var placeholder: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.white.opacity(0.82))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var metadataText: String {
        var parts: [String] = [item.siteName]
        if item.viewCount > 0 {
            parts.append(FavoritesDisplay.viewCount(item.viewCount))
        }
        parts.append("Saved \(item.favoritedAt.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " - ")
    }

    private var chips: [String] {
        var output: [String] = []
        output.append(contentsOf: item.qualityLabels.prefix(2))
        output.append(contentsOf: item.categories.prefix(1))
        return Array(output.prefix(3))
    }
}
