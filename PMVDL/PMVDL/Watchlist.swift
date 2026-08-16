import AppKit
import SwiftUI

struct WatchlistItem: Identifiable, Codable, Hashable {
    let id: UUID
    let sourcePageURL: String
    var title: String
    var provider: String
    var thumbnailURL: String?
    var watched: Bool
    var watchedAt: Date?
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), sourcePageURL: String, title: String, provider: String, thumbnailURL: String?, watched: Bool = false, watchedAt: Date? = nil, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.sourcePageURL = Self.normalizedURL(sourcePageURL)
        self.title = title
        self.provider = provider
        self.thumbnailURL = thumbnailURL
        self.watched = watched
        self.watchedAt = watchedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(feedItem: FeedItem) {
        self.init(
            sourcePageURL: feedItem.url,
            title: feedItem.title,
            provider: feedItem.siteName,
            thumbnailURL: feedItem.thumbnailURL
        )
    }

    static func normalizedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        components.fragment = nil
        return components.url?.absoluteString ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class WatchlistStore: ObservableObject {
    static let shared = WatchlistStore()

    @Published private(set) var items: [WatchlistItem] = []

    private let fileURL: URL

    private init(fileURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LustreStudio", isDirectory: true)
        self.fileURL = fileURL ?? support.appendingPathComponent("watchlist.json")
        load()
    }

    func contains(_ rawURL: String) -> Bool {
        let normalized = WatchlistItem.normalizedURL(rawURL)
        return items.contains { $0.sourcePageURL == normalized }
    }

    func add(_ item: WatchlistItem) {
        if let index = items.firstIndex(where: { $0.sourcePageURL == item.sourcePageURL }) {
            items[index].title = item.title
            items[index].provider = item.provider
            items[index].thumbnailURL = item.thumbnailURL ?? items[index].thumbnailURL
            items[index].updatedAt = .now
        } else {
            items.insert(item, at: 0)
        }
        save()
    }

    func add(feedItem: FeedItem) {
        add(WatchlistItem(feedItem: feedItem))
    }

    func toggle(feedItem: FeedItem) {
        if contains(feedItem.url) {
            remove(sourcePageURL: feedItem.url)
        } else {
            add(feedItem: feedItem)
        }
    }

    func toggleWatched(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].watched.toggle()
        items[index].watchedAt = items[index].watched ? .now : nil
        items[index].updatedAt = .now
        save()
    }

    @discardableResult
    func remove(id: UUID) -> WatchlistItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)
        save()
        return removed
    }

    func remove(sourcePageURL: String) {
        let normalized = WatchlistItem.normalizedURL(sourcePageURL)
        items.removeAll { $0.sourcePageURL == normalized }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([WatchlistItem].self, from: data) else {
            items = []
            return
        }
        var seen = Set<String>()
        items = decoded.sorted { $0.updatedAt > $1.updatedAt }.filter {
            seen.insert($0.sourcePageURL).inserted
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
        } catch {
            AppStateManager.shared.transientMessage = AppTransientMessage(text: "Watchlist could not be saved.")
        }
    }
}

private enum WatchlistStatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case unwatched = "Unwatched"
    case watched = "Watched"
    var id: String { rawValue }
}

private enum WatchlistSort: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case oldest = "Oldest"
    case title = "Title"
    var id: String { rawValue }
}

private enum WatchlistGrouping: String, CaseIterable, Identifiable {
    case none = "No grouping"
    case provider = "Provider"
    case watched = "Watched state"
    var id: String { rawValue }
}

struct WatchlistView: View {
    @StateObject private var store = WatchlistStore.shared
    @State private var query = ""
    @State private var status: WatchlistStatusFilter = .all
    @State private var provider = "All providers"
    @State private var sort: WatchlistSort = .newest
    @State private var grouping: WatchlistGrouping = .none
    @State private var selected = Set<UUID>()
    @State private var downloadTarget: CloudTarget = .local
    @State private var removedItem: WatchlistItem?
    @AppStorage("gdriveRemoteName") private var gdriveRemoteName = "gdrive"
    @AppStorage("gdriveRemotePath") private var gdriveRemotePath = "VidDL/"

    private var providers: [String] {
        ["All providers"] + Set(store.items.map(\.provider)).sorted()
    }

    private var visibleItems: [WatchlistItem] {
        let filtered = store.items.filter { item in
            let statusMatches = status == .all || item.watched == (status == .watched)
            let providerMatches = provider == "All providers" || item.provider == provider
            let queryMatches = query.isEmpty || "\(item.title) \(item.provider) \(item.sourcePageURL)"
                .localizedCaseInsensitiveContains(query)
            return statusMatches && providerMatches && queryMatches
        }
        switch sort {
        case .newest: return filtered.sorted { $0.updatedAt > $1.updatedAt }
        case .oldest: return filtered.sorted { $0.updatedAt < $1.updatedAt }
        case .title: return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    private var groupNames: [String] {
        switch grouping {
        case .none: return [""]
        case .provider: return Array(Set(visibleItems.map(\.provider))).sorted()
        case .watched: return ["Unwatched", "Watched"].filter { groupItems($0).isEmpty == false }
        }
    }

    var body: some View {
        MobileScreenScaffold(
            title: "Watchlist",
            subtitle: "Scenes saved on this Mac",
            accent: Theme.accent
        ) {
            Text("\(store.items.count)")
                .font(.title2.bold())
                .foregroundStyle(Theme.accent)
        } content: {
            VStack(spacing: 14) {
                metrics
                controls
                batchBar
                if visibleItems.isEmpty {
                    ContentUnavailableView(
                        store.items.isEmpty ? "Your Watchlist is empty" : "No matching scenes",
                        systemImage: "bookmark",
                        description: Text(store.items.isEmpty ? "Save a scene from Feed to begin." : "Adjust the search or filters.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(groupNames, id: \.self) { group in
                            if !group.isEmpty {
                                Text(group)
                                    .font(.headline)
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(groupItems(group)) { item in row(item) }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let removedItem {
                HStack {
                    Text("Removed \(removedItem.title)")
                    Button("Undo") {
                        store.add(removedItem)
                        self.removedItem = nil
                    }
                }
                .padding(12)
                .background(Theme.surface1, in: Capsule())
                .padding(.bottom, 90)
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            metric("All", count: store.items.count, filter: .all)
            metric("Unwatched", count: store.items.filter { !$0.watched }.count, filter: .unwatched)
            metric("Watched", count: store.items.filter(\.watched).count, filter: .watched)
        }
    }

    private func metric(_ title: String, count: Int, filter: WatchlistStatusFilter) -> some View {
        Button {
            status = filter
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
                Text("\(count)").font(.title2.bold()).foregroundStyle(status == filter ? Theme.accent : Theme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .mobileCard(tint: status == filter ? Theme.accent : Theme.surface2, isElevated: false)
        }
        .buttonStyle(.plain)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            TextField("Search your collection…", text: $query)
                .textFieldStyle(.roundedBorder)
            Picker("Provider", selection: $provider) {
                ForEach(providers, id: \.self, content: Text.init)
            }
            .frame(width: 180)
            Picker("Sort", selection: $sort) {
                ForEach(WatchlistSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 130)
            Picker("Group", selection: $grouping) {
                ForEach(WatchlistGrouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .frame(width: 145)
        }
    }

    private var batchBar: some View {
        HStack {
            Button(selected.count == visibleItems.count && !selected.isEmpty ? "Clear visible" : "Select visible") {
                let ids = Set(visibleItems.map(\.id))
                if !ids.isEmpty && ids.isSubset(of: selected) { selected.subtract(ids) }
                else { selected.formUnion(ids) }
            }
            Text("\(selected.count) selected").foregroundStyle(Theme.textSecondary)
            Spacer()
            Picker("Destination", selection: $downloadTarget) {
                ForEach(DestinationAvailabilityPolicy.newJobTargets, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .frame(width: 150)
            Button("Extract all", action: extractSelected)
                .disabled(selected.isEmpty)
            Button("Download all", action: downloadSelected)
                .disabled(selected.isEmpty)
        }
    }

    private func row(_ item: WatchlistItem) -> some View {
        HStack(spacing: 14) {
            Toggle("", isOn: Binding(
                get: { selected.contains(item.id) },
                set: { isSelected in
                    if isSelected {
                        selected.insert(item.id)
                    } else {
                        selected.remove(item.id)
                    }
                }
            ))
            .toggleStyle(.checkbox)
            AsyncImage(url: item.thumbnailURL.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack { Theme.surface2; Image(systemName: "photo") }
            }
            .frame(width: 150, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.provider.uppercased()).font(.caption2.bold()).foregroundStyle(Theme.accent)
                    if item.watched { Label("Watched", systemImage: "checkmark.circle.fill").font(.caption2) }
                }
                Text(item.title).font(.headline).lineLimit(2)
                Text("Added \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                HStack {
                    Button("Extract") { extract([item]) }
                    Button("Download") { download([item]) }
                    Button(item.watched ? "Mark unwatched" : "Mark watched") { store.toggleWatched(id: item.id) }
                    Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.sourcePageURL, forType: .string) }
                    Button("Remove", role: .destructive) { removedItem = store.remove(id: item.id) }
                }
                .buttonStyle(.borderless)
            }
            Spacer()
        }
        .padding(14)
        .mobileCard(tint: item.watched ? Theme.success : Theme.accent, isElevated: false)
    }

    private func selectedItems() -> [WatchlistItem] {
        visibleItems.filter { selected.contains($0.id) }
    }

    private func groupItems(_ group: String) -> [WatchlistItem] {
        switch grouping {
        case .none: return visibleItems
        case .provider: return visibleItems.filter { $0.provider == group }
        case .watched: return visibleItems.filter { $0.watched == (group == "Watched") }
        }
    }

    private func extractSelected() { extract(selectedItems()) }
    private func downloadSelected() { download(selectedItems()) }

    private func extract(_ items: [WatchlistItem]) {
        guard !items.isEmpty else { return }
        AppStateManager.shared.pendingExtractURL = items.map(\.sourcePageURL).joined(separator: "\n")
        AppStateManager.shared.pendingExtractShouldStart = true
        AppStateManager.shared.select(.home)
    }

    private func download(_ items: [WatchlistItem]) {
        let context = DownloadJobContext(
            megaRemotePath: "",
            gdriveRemoteName: gdriveRemoteName,
            gdriveRemotePath: gdriveRemotePath
        )
        for item in items {
            _ = DownloadJobRunner.shared.queue(
                sourcePageURL: item.sourcePageURL,
                preferredQualityLabel: nil,
                title: item.title,
                target: downloadTarget,
                context: context
            )
        }
    }
}
