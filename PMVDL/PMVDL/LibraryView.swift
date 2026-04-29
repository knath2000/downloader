import SwiftUI

@MainActor
struct LibraryView: View {
    @StateObject private var library = VideoLibrary.shared
    @State private var searchText = ""

    var filteredItems: [LibraryItem] {
        guard !searchText.isEmpty else { return library.items }
        let lower = searchText.lowercased()
        return library.items.filter {
            $0.title.lowercased().contains(lower)
            || $0.url.lowercased().contains(lower)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "books.vertical.fill").foregroundStyle(Theme.accent)
                Text("Library").font(.headline).foregroundStyle(Theme.textPrimary)
                Spacer()
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .font(.caption)
                Text("\(library.items.count)")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accentDim, in: Capsule())
                Button("Refresh Thumbnails") {
                    regenerateAllThumbnails()
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if library.items.isEmpty {
                VStack {
                    Image(systemName: "books.vertical")
                        .resizable().scaledToFit()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(Theme.accent.opacity(0.4))
                        .padding()
                    Text("No videos in library yet").font(.caption).foregroundStyle(Theme.textSecondary)
                    Text("Extract a video URL to add items here")
                        .font(.caption2).foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 200), spacing: 12)
                    ], spacing: 12) {
                        ForEach(filteredItems) { item in
                            LibraryCardView(item: item, thumbnail: cachedThumbnail(for: item))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
        }
    }

    private func cachedThumbnail(for item: LibraryItem) -> NSImage? {
        let url = item.mp4Url ?? item.url
        let key = "pmvdl_thumb_\(url.hashValue).jpg"
        return ThumbnailCache.cachedThumbnail(forKey: key)
    }

    private func regenerateAllThumbnails() {
        for item in library.items {
            Task {
                let url = item.mp4Url ?? item.url
                let key = "pmvdl_thumb_\(url.hashValue).jpg"
                let existing = await ThumbnailCache.shared.cachedImage(forKey: key)
                guard existing == nil else { return }
                _ = try? await ThumbnailCache.generateAndCache(fromRemoteURL: url)
            }
        }
    }
}

struct LibraryCardView: View {
    let item: LibraryItem
    let thumbnail: NSImage?
    @State private var isHovered = false

    var siteName: String {
        item.hlsUrls.first.map { _ in "" } ?? (item.mp4Url != nil ? "MP4" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thumbnail area
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.surface2)
                        .frame(height: 113)

                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 113)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .transition(.opacity)
                    } else {
                        Image(systemName: "film")
                            .resizable().scaledToFit()
                            .frame(width: 28, height: 28)
                            .foregroundStyle(Theme.accent.opacity(0.5))
                    }
                }

                // Source badge (top-right of thumbnail)
                let label = item.hlsUrls.first.map { _ in "Video" } ?? (item.mp4Url != nil ? "MP4" : nil)
                if let label {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(item.extractedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(8)
        .background(isHovered ? Theme.surface2 : Theme.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isHovered ? Theme.accent.opacity(0.3) : Theme.border, lineWidth: 0.5))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy Page URL") { ClipboardManager.copy(item.url) }
            if let mp4 = item.mp4Url {
                Button("Copy MP4 Link") { ClipboardManager.copy(mp4) }
            }
            Divider()
            Button("Delete from Library", role: .destructive) {
                withAnimation { VideoLibrary.shared.remove(item) }
            }
        }
    }
}
