import SwiftUI

@MainActor
struct LibraryView: View {
    @StateObject private var library = VideoLibrary.shared
    @StateObject private var thumbnailStore = LibraryThumbnailStore()
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
                Button {
                    regenerateAllThumbnails()
                } label: {
                    HStack(spacing: 6) {
                        if thumbnailStore.isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text("Refreshing...")
                        } else {
                            Text("Refresh Thumbnails")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(thumbnailStore.isRefreshing || library.items.isEmpty)
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
                            LibraryCardView(
                                item: item,
                                thumbnail: thumbnailStore.image(for: item),
                                isThumbnailLoading: thumbnailStore.isLoading(item),
                                thumbnailFailed: thumbnailStore.didFail(item),
                                refreshThumbnail: {
                                    Task { await thumbnailStore.load(item: item, force: true) }
                                }
                            )
                            .task(id: thumbnailTaskID(for: item)) {
                                await thumbnailStore.load(item: item)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
        }
    }

    private func regenerateAllThumbnails() {
        Task {
            await thumbnailStore.refresh(items: library.items, force: true)
        }
    }

    private func thumbnailTaskID(for item: LibraryItem) -> String {
        item.thumbnailURL ?? item.mp4Url ?? item.hlsUrls.first?.url ?? item.url
    }
}

struct LibraryCardView: View {
    let item: LibraryItem
    let thumbnail: NSImage?
    let isThumbnailLoading: Bool
    let thumbnailFailed: Bool
    let refreshThumbnail: () -> Void
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
                        if isThumbnailLoading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.accent)
                        } else {
                            Image(systemName: thumbnailFailed ? "photo.badge.exclamationmark" : "film")
                                .resizable().scaledToFit()
                                .frame(width: 28, height: 28)
                                .foregroundStyle(thumbnailFailed ? Theme.warning.opacity(0.8) : Theme.accent.opacity(0.5))
                        }
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
            Button("Refresh Thumbnail") { refreshThumbnail() }
            Divider()
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

@MainActor
final class LibraryThumbnailStore: ObservableObject {
    @Published private var images: [UUID: NSImage] = [:]
    @Published private var loadingIDs: Set<UUID> = []
    @Published private var failedIDs: Set<UUID> = []
    @Published var isRefreshing = false

    private let resolver: LibraryThumbnailResolver
    private var attemptedIdentities = Set<String>()

    init(resolver: LibraryThumbnailResolver = .live) {
        self.resolver = resolver
    }

    func image(for item: LibraryItem) -> NSImage? {
        images[item.id]
    }

    func isLoading(_ item: LibraryItem) -> Bool {
        loadingIDs.contains(item.id)
    }

    func didFail(_ item: LibraryItem) -> Bool {
        failedIDs.contains(item.id)
    }

    func load(item: LibraryItem, force: Bool = false) async {
        let identity = item.thumbnailURL ?? item.mp4Url ?? item.hlsUrls.first?.url ?? item.url
        if !force, attemptedIdentities.contains(identity) { return }
        attemptedIdentities.insert(identity)

        if !force {
            if let thumbnailURL = item.thumbnailURL,
               let cached = await ThumbnailCache.shared.cachedImage(forIdentity: thumbnailURL) {
                images[item.id] = cached
                failedIDs.remove(item.id)
                return
            }
            if let mediaURL = item.mp4Url,
               let cached = await ThumbnailCache.shared.cachedImage(forIdentity: mediaURL) {
                images[item.id] = cached
                failedIDs.remove(item.id)
                return
            }
            if let mediaURL = item.hlsUrls.first(where: { $0.kind != .pageUrl })?.url,
               let cached = await ThumbnailCache.shared.cachedImage(forIdentity: mediaURL) {
                images[item.id] = cached
                failedIDs.remove(item.id)
                return
            }
        }

        loadingIDs.insert(item.id)
        failedIDs.remove(item.id)
        defer { loadingIDs.remove(item.id) }

        do {
            let result = try await resolver.loadThumbnail(for: item)
            if let image = result.image {
                images[item.id] = image
            }
            if let thumbnailURL = result.thumbnailURL,
               result.source != .mediaFrame {
                VideoLibrary.shared.updateThumbnailURL(forID: item.id, thumbnailURL: thumbnailURL)
            }
        } catch {
            failedIDs.insert(item.id)
        }
    }

    func refresh(items: [LibraryItem], force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        for item in items {
            await load(item: item, force: force)
        }
    }
}
