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
        HStack(spacing: 6) {
            metric("All", count: store.items.count, filter: .all, tint: Theme.warning)
            metric("Unwatched", count: store.items.filter { !$0.watched }.count, filter: .unwatched, tint: Theme.skyBlue)
            metric("Watched", count: store.items.filter(\.watched).count, filter: .watched, tint: Theme.success)
            Spacer()
        }
    }

    private func metric(_ title: String, count: Int, filter: WatchlistStatusFilter, tint: Color) -> some View {
        Button {
            status = filter
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)")
                    .font(.system(size: 9, weight: .black))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.white.opacity(status == filter ? 0.24 : 0.12), in: Capsule())
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(status == filter ? tint : tint.opacity(0.45), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(status == filter ? 0.28 : 0.12), lineWidth: 0.5))
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
            WatchlistPillButton(
                selected.count == visibleItems.count && !selected.isEmpty ? "Clear visible" : "Select visible",
                systemImage: selected.isEmpty ? "checklist" : "checkmark.circle.fill",
                tint: Theme.lavender
            ) {
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
            WatchlistPillButton("Extract all", systemImage: "bolt.fill", tint: Theme.warning, disabled: selected.isEmpty, action: extractSelected)
            WatchlistPillButton("Download all", systemImage: "arrow.down.circle.fill", tint: Theme.skyBlue, disabled: selected.isEmpty, action: downloadSelected)
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
                HStack(spacing: 6) {
                    WatchlistPillButton("Extract", systemImage: "bolt.fill", tint: Theme.warning) { extract([item]) }
                    WatchlistPillButton("Download", systemImage: "arrow.down.circle.fill", tint: Theme.skyBlue) { download([item]) }
                    WatchlistPillButton(
                        item.watched ? "Unwatched" : "Watched",
                        systemImage: item.watched ? "circle" : "checkmark.circle.fill",
                        tint: Theme.success
                    ) {
                        store.toggleWatched(id: item.id)
                    }
                    WatchlistPillButton("Copy URL", systemImage: "doc.on.doc.fill", tint: Theme.lavender) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.sourcePageURL, forType: .string)
                    }
                    WatchlistPillButton("Remove", systemImage: "trash.fill", tint: Theme.error) {
                        removedItem = store.remove(id: item.id)
                    }
                }
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

private struct WatchlistPillButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let disabled: Bool
    let action: () -> Void

    init(_ title: String, systemImage: String, tint: Color, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(disabled ? Theme.textSecondary.opacity(0.55) : tint)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(tint.opacity(disabled ? 0.06 : 0.14), in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(disabled ? 0.1 : 0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
