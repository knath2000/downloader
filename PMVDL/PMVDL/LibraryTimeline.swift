import AppKit
import SwiftUI

enum LibraryTimelineFilter: String, CaseIterable, Identifiable {
    case all
    case videos
    case links
    case uploads
    case favorites

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "All"
        case .videos: return "Videos"
        case .links: return "Links"
        case .uploads: return "Uploads"
        case .favorites: return "Favorites"
        }
    }

    var tint: Color {
        switch self {
        case .all: return Theme.gold
        case .videos: return Theme.skyBlue
        case .links: return Theme.lavender
        case .uploads: return Theme.success
        case .favorites: return Theme.hotPink
        }
    }

    func matches(_ entry: LibraryTimelineEntry) -> Bool {
        switch self {
        case .all:
            return true
        case .videos:
            if case .video = entry { return true }
            return false
        case .links:
            if case .link = entry { return true }
            return false
        case .uploads:
            if case .upload = entry { return true }
            return false
        case .favorites:
            if case .favorite = entry { return true }
            return false
        }
    }

    func matches(_ entry: LibraryTimelineEntry, favoriteURLs: Set<String>) -> Bool {
        switch self {
        case .favorites:
            if case .favorite = entry { return true }
            if case .video(let item) = entry {
                return favoriteURLs.contains(LibraryTimelineBuilder.normalizedURL(item.url))
            }
            return false
        default:
            return matches(entry)
        }
    }
}

enum LibraryViewMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: Self { self }

    var title: String {
        switch self {
        case .list: return "List View"
        case .grid: return "Thumbnail View"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .list: return Theme.skyBlue
        case .grid: return Theme.lavender
        }
    }
}

struct LibraryTimelineFilterCounts {
    let entries: [LibraryTimelineEntry]
    let favoriteURLs: Set<String>

    init(entries: [LibraryTimelineEntry], favoriteURLs: Set<String> = []) {
        self.entries = entries
        self.favoriteURLs = favoriteURLs
    }

    func count(for filter: LibraryTimelineFilter) -> Int {
        entries.filter { filter.matches($0, favoriteURLs: favoriteURLs) }.count
    }
}

enum LibraryTimelineEntry: Identifiable {
    case video(LibraryItem)
    case link(HistoryItem)
    case upload(CompletedUploadItem)
    case favorite(FeedFavoriteItem)

    var id: String {
        switch self {
        case .video(let item): return "video-\(item.id.uuidString)"
        case .link(let item): return "link-\(item.id.uuidString)"
        case .upload(let item): return "upload-\(item.id.uuidString)"
        case .favorite(let item): return "favorite-\(item.id)"
        }
    }

    var title: String {
        switch self {
        case .video(let item): return LibraryDisplay.title(for: item)
        case .link(let item): return item.title
        case .upload(let item): return item.title
        case .favorite(let item): return item.title
        }
    }

    var url: String {
        switch self {
        case .video(let item): return item.url
        case .link(let item): return item.url
        case .upload(let item): return item.url
        case .favorite(let item): return item.url
        }
    }

    var timestamp: Date {
        switch self {
        case .video(let item): return item.extractedAt
        case .link(let item): return item.recordedAt
        case .upload(let item): return item.completedAt
        case .favorite(let item): return item.favoritedAt
        }
    }

    var thumbnailIdentity: String {
        switch self {
        case .video(let item):
            return item.thumbnailURL ?? item.mp4Url ?? item.hlsUrls.first?.url ?? item.url
        default:
            return id
        }
    }

    var libraryItem: LibraryItem? {
        if case .video(let item) = self { return item }
        return nil
    }
}

private extension LibraryTimelineEntry {
    var isFavorite: Bool {
        if case .favorite = self { return true }
        return false
    }
}

struct LibraryTimelineDayBucket: Identifiable {
    let date: Date
    let entries: [LibraryTimelineEntry]

    var id: Date { date }
}

enum LibraryTimelineBuilder {
    static func entries(
        libraryItems: [LibraryItem],
        historyItems: [HistoryItem],
        completedUploads: [CompletedUploadItem],
        favoriteItems: [FeedFavoriteItem]
    ) -> [LibraryTimelineEntry] {
        let libraryURLs = Set(libraryItems.map { normalizedURL($0.url) }.filter { !$0.isEmpty })
        let videos = libraryItems.map(LibraryTimelineEntry.video)
        let links = historyItems
            .filter { !libraryURLs.contains(normalizedURL($0.url)) }
            .map(LibraryTimelineEntry.link)
        let uploads = completedUploads.map(LibraryTimelineEntry.upload)
        let favorites = favoriteItems
            .filter { !libraryURLs.contains(normalizedURL($0.url)) }
            .map(LibraryTimelineEntry.favorite)

        return (videos + links + uploads + favorites).sorted {
            if $0.timestamp == $1.timestamp { return $0.id < $1.id }
            return $0.timestamp > $1.timestamp
        }
    }

    static func filteredEntries(
        _ entries: [LibraryTimelineEntry],
        query: String,
        filter: LibraryTimelineFilter,
        favoriteURLs: Set<String> = [],
        pipelineSearchTextByURL: [String: String] = [:]
    ) -> [LibraryTimelineEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            let queryMatches = normalizedQuery.isEmpty || searchText(for: entry, pipelineSearchTextByURL: pipelineSearchTextByURL).contains(normalizedQuery)
            let filterMatches: Bool
            switch filter {
            case .favorites:
                filterMatches = entry.isFavorite || favoriteURLs.contains(normalizedURL(entry.url))
            default:
                filterMatches = filter.matches(entry)
            }
            return queryMatches && filterMatches
        }
    }

    static func selectedEntryID(currentID: String?, in entries: [LibraryTimelineEntry]) -> String? {
        if let currentID, entries.contains(where: { $0.id == currentID }) {
            return currentID
        }
        return nil
    }

    static func selectedEntry(currentID: String?, in entries: [LibraryTimelineEntry]) -> LibraryTimelineEntry? {
        guard let id = selectedEntryID(currentID: currentID, in: entries) else { return nil }
        return entries.first { $0.id == id }
    }

    static func videoSelection(_ selection: Set<UUID>, toggling entry: LibraryTimelineEntry) -> Set<UUID> {
        guard case .video(let item) = entry else { return selection }
        var next = selection
        if next.contains(item.id) {
            next.remove(item.id)
        } else {
            next.insert(item.id)
        }
        return next
    }

    static func searchText(for entry: LibraryTimelineEntry, pipelineSearchTextByURL: [String: String] = [:]) -> String {
        switch entry {
        case .video(let item):
            return LibraryDisplay.searchText(for: item, pipelineSearchText: pipelineSearchTextByURL[item.url] ?? "")
        case .link(let item):
            return "\(item.title) \(item.provider) \(item.url) \(LibraryDisplay.domain(for: item.url))".lowercased()
        case .upload(let item):
            return "\(item.title) \(item.provider) \(item.destination) \(item.remotePath) \(item.url) \(LibraryDisplay.domain(for: item.url))".lowercased()
        case .favorite(let item):
            return FavoritesDisplay.searchText(for: item)
        }
    }

    static func normalizedURL(_ raw: String) -> String {
        FeedFavoriteItem.normalizedURL(raw)
    }
}

enum LibrarySourceKind: Equatable {
    case mp4
    case hls
    case page

    static func kind(for item: LibraryItem) -> LibrarySourceKind {
        if !item.hlsUrls.isEmpty { return .hls }
        if item.mp4Url != nil { return .mp4 }
        return .page
    }

    var label: String {
        switch self {
        case .mp4: return "MP4"
        case .hls: return "HLS"
        case .page: return "Page"
        }
    }

    var tint: Color {
        switch self {
        case .mp4: return Theme.gold
        case .hls: return Theme.taoRed
        case .page: return Theme.textSecondary
        }
    }
}

@MainActor
enum LibraryPipelineDisplay {
    static func compactBadges(for rawURL: String, store: LibraryPipelineStore) -> [LibraryPipelineBadgeModel] {
        var badges: [LibraryPipelineBadgeModel] = []
        for destination in LibraryPipelineDestination.allCases {
            let stage = store.stage(for: rawURL, destination: destination)
            switch stage {
            case .running:
                badges.append(.init(id: "\(destination.rawValue)-running", title: destination.title, tint: Theme.skyBlue))
            case .succeeded:
                badges.append(.init(id: "\(destination.rawValue)-ok", title: destination.title, tint: tint(for: destination)))
            case .failed:
                badges.append(.init(id: "\(destination.rawValue)-failed", title: "Failed", tint: Theme.error))
            case .notStarted:
                continue
            }
        }
        return Array(badges.prefix(3))
    }

    static func tint(for destination: LibraryPipelineDestination) -> Color {
        switch destination {
        case .local: return Theme.gold
        case .mega: return Theme.success
        case .gdrive: return Theme.skyBlue
        case .seedbox: return Theme.lavender
        }
    }
}

enum LibraryDisplay {
    static func title(for item: LibraryItem) -> String {
        displayTitle(item.title)
    }

    static func displayTitle(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(
            of: #"_[0-9A-Fa-f][0-9A-Fa-f_-]{10,}.*$"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? raw : stripped
    }

    static func domain(for rawURL: String) -> String {
        guard let host = URL(string: rawURL)?.host?.replacingOccurrences(of: "www.", with: "") else {
            return "unknown source"
        }
        return host
    }

    @MainActor
    static func detailLine(for item: LibraryItem, pipelineStore: LibraryPipelineStore) -> String {
        let base = LibraryTimelineURLFormatter.prettyURL(item.url)
        let badges = LibraryPipelineDisplay.compactBadges(for: item.url, store: pipelineStore).map(\.title)
        guard !badges.isEmpty else { return base }
        return "\(base) · \(badges.joined(separator: ", "))"
    }

    static func searchText(for item: LibraryItem, pipelineSearchText: String) -> String {
        "\(displayTitle(item.title)) \(item.title) \(item.url) \(domain(for: item.url)) \(LibrarySourceKind.kind(for: item).label) \(pipelineSearchText)".lowercased()
    }
}

enum LibraryTimelineProviderTint {
    static func key(for provider: String) -> String {
        provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func color(for provider: String) -> Color {
        color(forKey: key(for: provider))
    }

    static func color(forKey key: String) -> Color {
        switch key {
        case "pornhub":
            return Theme.coral
        case "streamtape":
            return Theme.skyBlue
        case "video site", "nativevideopage":
            return Theme.gold
        case "providerlink", "all porn stream":
            return Theme.lavender
        case "vidara":
            return Theme.electricLime
        case "lulustream", "lulu stream", "luluvid":
            return Theme.hotPink
        case "doodstream", "playmogo":
            return Theme.taoRed
        case "favorites":
            return Theme.hotPink
        default:
            return Theme.textSecondary
        }
    }

    static func displayName(for provider: String) -> String {
        switch key(for: provider) {
        case "pornhub":
            return "PornHub"
        case "streamtape":
            return "StreamTape"
        case "video site", "nativevideopage":
            return "Video Site"
        case "providerlink":
            return "Provider Link"
        case "all porn stream":
            return "All Porn Stream"
        case "vidara":
            return "Vidara"
        case "lulustream", "lulu stream", "luluvid":
            return "LuluStream"
        case "doodstream":
            return "DoodStream"
        case "playmogo":
            return "Playmogo"
        case "favorites":
            return "Favorites"
        default:
            let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Unknown" : trimmed
        }
    }
}

enum LibraryTimelineURLFormatter {
    static func prettyURL(_ raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host?.replacingOccurrences(of: "www.", with: "") else {
            return raw
        }
        guard let shortID = shortIdentifier(from: raw) else {
            return host
        }
        return "\(host) · \(shortID)"
    }

    private static func shortIdentifier(from raw: String) -> String? {
        guard let components = URLComponents(string: raw) else { return nil }
        let queryKeys = ["viewkey", "id", "v", "video", "file"]
        for key in queryKeys {
            if let value = components.queryItems?.first(where: { $0.name.lowercased() == key })?.value,
               !value.isEmpty {
                return value.count > 10 ? String(value.prefix(6)) : value
            }
        }

        if let path = components.path.split(separator: "/").last.map(String.init),
           !path.isEmpty {
            return path.count > 18 ? String(path.suffix(8)) : path
        }
        return nil
    }
}

enum LibraryTimelineDestinationFormatter {
    static func shortName(for destination: String) -> String {
        let lower = destination.lowercased()
        if lower.contains("mega") { return "MEGA" }
        if lower.contains("drive") || lower.contains("gdrive") { return "Drive" }
        if lower.contains("seedbox") { return "Seedbox" }
        if lower.contains("local") { return "Local" }
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Remote" : trimmed
    }

    static func displayName(for destination: String) -> String {
        shortName(for: destination)
    }

    static func color(for destination: String) -> Color {
        let lower = destination.lowercased()
        if lower.contains("mega") { return Theme.success }
        if lower.contains("drive") || lower.contains("gdrive") { return Theme.skyBlue }
        if lower.contains("seedbox") { return Theme.lavender }
        if lower.contains("local") { return Theme.gold }
        return Theme.textSecondary
    }
}

enum LibraryDateFormatter {
    static func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static func timeLabel(for date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

enum LibraryDownloadContext {
    static func current() -> DownloadJobContext {
        let defaults = UserDefaults.standard
        return DownloadJobContext(
            megaRemotePath: defaults.string(forKey: "megaRemotePath") ?? "/Cloud/VidDL/",
            gdriveRemoteName: defaults.string(forKey: "gdriveRemoteName") ?? "gdrive",
            gdriveRemotePath: defaults.string(forKey: "gdriveRemotePath") ?? "VidDL/",
            seedboxTransferMode: defaults.string(forKey: "seedboxTransferMode") ?? "rclone",
            seedboxRemoteName: defaults.string(forKey: "seedboxRemoteName") ?? "seedbox",
            seedboxRemotePath: defaults.string(forKey: "seedboxRemotePath") ?? "/",
            seedboxWebdavURL: defaults.string(forKey: "seedboxWebdavURL") ?? "",
            seedboxWebdavUser: defaults.string(forKey: "seedboxWebdavUser") ?? "",
            seedboxWebdavPassword: SecureStore.string(forKey: "seedboxWebdavPassword") ?? ""
        )
    }

    static func resolution(for item: LibraryItem) -> DownloadResolution? {
        let source = VideoSource(
            mp4: item.mp4Url,
            hls: item.hlsUrls,
            title: item.title,
            thumbnail: item.thumbnailURL,
            siteName: LibraryDisplay.domain(for: item.url)
        )
        let result = ExtractResult(url: item.url, source: source, error: nil)

        if let mp4 = item.mp4Url {
            return DownloadResolution(
                requestedUrl: mp4,
                finalUrl: mp4,
                result: result,
                source: source,
                title: item.title,
                mediaKind: .direct,
                headers: source.headers(forQualityURL: mp4),
                sourcePageUrl: item.url
            )
        }

        guard let quality = item.hlsUrls.first(where: { $0.kind != .pageUrl }) ?? item.hlsUrls.first else {
            return nil
        }
        let mediaKind: DownloadMediaKind = quality.kind == .pageUrl ? .ytDlp : .hls
        return DownloadResolution(
            requestedUrl: quality.url,
            finalUrl: quality.url,
            result: result,
            source: source,
            title: item.title,
            mediaKind: mediaKind,
            headers: quality.headers,
            sourcePageUrl: quality.sourcePageUrl ?? item.url
        )
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
        if !force, images[item.id] != nil || loadingIDs.contains(item.id) || attemptedIdentities.contains(identity) {
            return
        }

        loadingIDs.insert(item.id)
        failedIDs.remove(item.id)
        attemptedIdentities.insert(identity)
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
        guard !items.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        for item in items {
            if force {
                images[item.id] = nil
                attemptedIdentities.remove(item.thumbnailURL ?? item.mp4Url ?? item.hlsUrls.first?.url ?? item.url)
            }
            await load(item: item, force: true)
        }
    }
}
