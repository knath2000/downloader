import SwiftUI

@MainActor
struct LibraryView: View {
    @StateObject private var library = VideoLibrary.shared
    @State private var searchText = ""
    @State private var thumbnailImages: [String: NSImage] = [:]

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
                Image(systemName: "books.vertical.fill").foregroundStyle(.blue)
                Text("Library").font(.headline)
                Spacer()
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .font(.caption)
                Text("\(library.items.count)")
                    .font(.caption).foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                        .padding()
                    Text("No videos in library yet").font(.caption).foregroundStyle(.secondary)
                    Text("Extract a video URL to add items here")
                        .font(.caption2).foregroundStyle(.tertiary)
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

    /// Synchronous disk-cache read — instant if thumbnail was generated during upload.
    private func cachedThumbnail(for item: LibraryItem) -> NSImage? {
        let url = item.mp4Url ?? item.url
        let key = "pmvdl_thumb_\(url.hashValue).jpg"
        return ThumbnailCache.cachedThumbnail(forKey: key)
    }

    /// Backfill thumbnails for all items that don't already have a cached thumbnail.
    /// Falls back to downloading the first 2 MB of the remote video for items not
    /// previously uploaded by this app.
    private func regenerateAllThumbnails() {
        for item in library.items {
            Task {
                let url = item.mp4Url ?? item.url
                let key = "pmvdl_thumb_\(url.hashValue).jpg"
                let existing = await ThumbnailCache.shared.cachedImage(forKey: key)
                guard existing == nil else { return }
                // Re-download first 2 MB and generate thumbnail
                _ = try? await ThumbnailCache.generateAndCache(fromRemoteURL: url)
            }
        }
    }
}

struct LibraryCardView: View {
    let item: LibraryItem
    let thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thumbnail area
            ZStack {
                Rectangle().fill(Color.gray.opacity(0.15))
                    .frame(height: 113).cornerRadius(6)

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 113)
                        .clipped()
                        .cornerRadius(6)
                        .transition(.opacity)
                } else {
                    Image(systemName: "film")
                        .resizable().scaledToFit()
                        .frame(width: 30, height: 30)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.bold())
                    .lineLimit(2)
                Text(item.extractedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
                if let quality = item.hlsUrls.first {
                    Text(quality.label).font(.caption2).foregroundStyle(.blue)
                } else if item.mp4Url != nil {
                    Text("MP4").font(.caption2).foregroundStyle(.blue)
                }
            }

            Button("Copy URL") {
                ClipboardManager.copy(item.url)
            }.buttonStyle(.bordered).controlSize(.mini).font(.caption)
                .contextMenu {
                    Button("Copy MP4 Link") { if let u = item.mp4Url { ClipboardManager.copy(u) } }
                    Divider()
                    Button("Delete from Library", role: .destructive) {
                        withAnimation { VideoLibrary.shared.remove(item) }
                    }
                }
        }
        .padding(8)
        .background(Color.gray.opacity(0.08).cornerRadius(8))
    }
}
