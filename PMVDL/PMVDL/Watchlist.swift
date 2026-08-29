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
    var sortOrder: Int = Int.max

    init(id: UUID = UUID(), sourcePageURL: String, title: String, provider: String, thumbnailURL: String?, watched: Bool = false, watchedAt: Date? = nil, createdAt: Date = .now, updatedAt: Date = .now, sortOrder: Int = Int.max) {
        self.id = id
        self.sourcePageURL = Self.normalizedURL(sourcePageURL)
        self.title = title
        self.provider = provider
        self.thumbnailURL = thumbnailURL
        self.watched = watched
        self.watchedAt = watchedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
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

    @Published var items: [WatchlistItem] = []

    private let fileURL: URL

    private init(fileURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LustreStudio", isDirectory: true)
        self.fileURL = fileURL ?? support.appendingPathComponent("watchlist.json")
        load()
        // Repair pre-existing duration-only titles offline (no cloud dependency) so the
        // cards show real titles even when the local agent is unavailable.
        Task { await repairDurationTitles() }
        Task { await synchronizeWithAgent() }
    }

    /// Reorders items and reassigns sequential sortOrders - public for drag-drop
    func reorderItems(_ newItems: [WatchlistItem]) {
        items = newItems
        reassignSequentialSortOrders()
        save()
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
            var newItem = item
            // Assign sortOrder = max + 1 for new items (append to end)
            let maxSortOrder = items.map(\.sortOrder).filter { $0 != Int.max }.max() ?? 0
            newItem.sortOrder = maxSortOrder + 1
            items.insert(newItem, at: 0)
        }
        save()
        Task { try? await LustreAgentClient().saveWatchlist(itemForSync(item.sourcePageURL)) }
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
        let item = items[index]
        Task { try? await LustreAgentClient().saveWatchlist(item) }
    }

    @discardableResult
    func remove(id: UUID) -> WatchlistItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = items.remove(at: index)
        save()
        Task { try? await LustreAgentClient().removeWatchlist(sourcePageURL: removed.sourcePageURL) }
        return removed
    }

    func remove(sourcePageURL: String) {
        let normalized = WatchlistItem.normalizedURL(sourcePageURL)
        let removed = items.first { $0.sourcePageURL == normalized }
        items.removeAll { $0.sourcePageURL == normalized }
        save()
        if let removed { Task { try? await LustreAgentClient().removeWatchlist(sourcePageURL: removed.sourcePageURL) } }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([WatchlistItem].self, from: data) else {
            items = []
            return
        }
        var seen = Set<String>()
        items = decoded
            .sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.updatedAt > $1.updatedAt
            }
            .filter {
                seen.insert($0.sourcePageURL).inserted
            }
        // Assign sequential sortOrder to any items with Int.max (legacy/unassigned)
        reassignSequentialSortOrdersIfNeeded()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
        } catch {
            ToastQueue.shared.error("Watchlist could not be saved.")
        }
    }

    /// Reassigns sequential sortOrders to all items, preserving relative order
    private func reassignSequentialSortOrders() {
        for (index, item) in items.enumerated() {
            if item.sortOrder != index {
                items[index].sortOrder = index
            }
        }
    }

    /// Only reassigns if there are items with Int.max (legacy items without sortOrder)
    private func reassignSequentialSortOrdersIfNeeded() {
        let hasLegacyItems = items.contains { $0.sortOrder == Int.max }
        if hasLegacyItems {
            reassignSequentialSortOrders()
            save()
        }
    }

    /// Clears all custom sort orders, reverting to date-based sorting
    func resetSortOrder() {
        for index in items.indices {
            items[index].sortOrder = Int.max
        }
        save()
    }

    /// Reorders items and reassigns sequential sortOrders
    func moveItems(fromOffsets: IndexSet, toOffset: Int) {
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        reassignSequentialSortOrders()
        save()
    }

    func updateThumbnailURL(for id: UUID, thumbnailURL: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].thumbnailURL = thumbnailURL
        items[index].updatedAt = .now
        save()
    }

    private func itemForSync(_ sourcePageURL: String) -> WatchlistItem {
        items.first { $0.sourcePageURL == sourcePageURL }!
    }

    private func synchronizeWithAgent() async {
        guard let client = try? LustreAgentClient() else { return }
        do {
            if !UserDefaults.standard.bool(forKey: "cloudCollectionsWatchlistMigrated") {
                for item in items { _ = try await client.saveWatchlist(item) }
                UserDefaults.standard.set(true, forKey: "cloudCollectionsWatchlistMigrated")
            }
            let snapshot = try await client.collections()
            // The cloud agent can echo back title values that are actually video
            // durations (e.g. "21:22") for some providers. Merge cloud data in without
            // clobbering locally-known real titles, watched state, thumbnails, or sort order.
            items = mergeCloud(snapshot.watchlist)
            // Repair any entries whose title is a bare duration by re-fetching the real title.
            await repairDurationTitles()
            save()
        } catch {}
    }

    /// Merges the cloud snapshot into the current local items keyed by `sourcePageURL`.
    /// Local fields are preferred when the cloud value is missing, empty, or looks like a
    /// bare duration (e.g. "21:22" or "1:08:03"), so a wrong cloud title never overwrites a
    /// correct local one.
    private func mergeCloud(_ cloud: [WatchlistItem]) -> [WatchlistItem] {
        // Seed with local items so entries never disappear, then overlay cloud fields that are trustworthy.
        var merged = items

        for cloudItem in cloud {
            if let index = merged.firstIndex(where: { $0.sourcePageURL == cloudItem.sourcePageURL }) {
                var local = merged[index]
                // Prefer local title unless the cloud title is genuinely better (non-empty, non-duration).
                if isBareDuration(local.title) || local.title.isEmpty {
                    if !isBareDuration(cloudItem.title), !cloudItem.title.isEmpty {
                        local.title = cloudItem.title
                    }
                }
                if local.thumbnailURL == nil { local.thumbnailURL = cloudItem.thumbnailURL }
                if local.provider.isEmpty { local.provider = cloudItem.provider }
                // Watched state goes cloud -> local (cloud is source of truth for playback progress).
                local.watched = cloudItem.watched
                local.watchedAt = cloudItem.watchedAt
                local.updatedAt = max(local.updatedAt, cloudItem.updatedAt)
                if cloudItem.sortOrder != Int.max { local.sortOrder = cloudItem.sortOrder }
                merged[index] = local
            } else {
                merged.append(cloudItem)
            }
        }

        return merged.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Returns true when a string is a bare duration such as "21:22" or "1:08:03"
    /// (with no spaces or other text), which the cloud agent has been observed to store
    /// in place of a real title for PornHub items.
    private func isBareDuration(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Allow only digits and colon separators, with 1-3 colon-delimited groups.
        let allowed = CharacterSet(charactersIn: "0123456789:")
        guard trimmed.rangeOfCharacter(from: allowed.inverted) == nil else { return false }
        let parts = trimmed.split(separator: ":").map(String.init)
        return (1...3).contains(parts.count) && parts.allSatisfy { Int($0) != nil }
    }

    /// Re-fetches the real page title for any item whose title is a bare duration.
    private func repairDurationTitles() async {
        let needsRepair = items.enumerated().filter { isBareDuration($0.element.title) }
        guard !needsRepair.isEmpty else { return }

        for index in needsRepair.map(\.offset) {
            let item = items[index]
            guard let viewkey = DownloadedFeedIndex.pornHubViewkey(item.sourcePageURL) else { continue }
            guard let realTitle = try? await PornHubFeedScraper.fetchVideoPageTitle(viewkey: viewkey),
                  !realTitle.isEmpty, !isBareDuration(realTitle) else { continue }
            items[index].title = realTitle
            items[index].updatedAt = .now
            // Best-effort: persist the correction so the cloud stops echoing the duration.
            // Failure here is non-fatal; the local correction still wins via mergeCloud.
            try? await LustreAgentClient().saveWatchlist(items[index])
        }
        // Always persist local corrections (works even when the cloud is unavailable).
        save()
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
    @StateObject private var thumbnailStore = WatchlistThumbnailStore.shared
    @StateObject private var selectionManager = SelectionManager.shared
    @State private var query = ""
    @State private var status: WatchlistStatusFilter = .all
    @State private var provider = "All providers"
    @State private var sort: WatchlistSort = .newest
    @State private var grouping: WatchlistGrouping = .none
    @State private var downloadTarget: CloudTarget = .local
    @State private var removedItem: WatchlistItem?

    private var selected: Set<String> {
        get { selectionManager.selection(for: .watchlist) }
        set { selectionManager.selectAll(Array(newValue), in: .watchlist) }
    }

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
        case .newest:
            return filtered.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.updatedAt > $1.updatedAt
            }
        case .oldest:
            return filtered.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.updatedAt < $1.updatedAt
            }
        case .title:
            return filtered.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
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
                    if store.items.isEmpty {
                        EmptyStateView.watchlistEmpty()
                            .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "No matching scenes",
                            subtitle: "Adjust the search or filters.",
                            tint: Theme.hotPink,
                            isSearchEmpty: true,
                            searchText: query,
                            clearSearchAction: { query = "" }
                        )
                        .frame(maxWidth: CGFloat.infinity, minHeight: 320)
                    }
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
                                .onMove(perform: { indices, newOffset in
                                    moveWatchlistItems(in: group, indices: indices, newOffset: newOffset)
                                })
                        }
                    }
                }
            }
            .onAppear {
                Task {
                    await thumbnailStore.refresh(items: visibleItems, force: false)
                }
            }
            .onChange(of: visibleItems.count) { _, _ in
                Task {
                    await thumbnailStore.refresh(items: visibleItems, force: false)
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
            Button("Reset Order") {
                store.resetSortOrder()
            }
            .help("Clear custom sort order, revert to date-based sorting")
        }
    }

    private var batchBar: some View {
        HStack {
            WatchlistPillButton(
                selected.count == visibleItems.count && !selected.isEmpty ? "Clear visible" : "Select visible",
                systemImage: selected.isEmpty ? "checklist" : "checkmark.circle.fill",
                tint: Theme.lavender
            ) {
                let ids = Set(visibleItems.map(\.id.uuidString))
                if !ids.isEmpty && ids.isSubset(of: selected) {
                    selectionManager.deselectAll(in: .watchlist)
                } else {
                    selectionManager.selectAll(Array(ids), in: .watchlist)
                }
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

    private func thumbnail(for item: WatchlistItem) -> NSImage? {
        thumbnailStore.state(for: item).image
    }

    private func isThumbnailLoading(_ item: WatchlistItem) -> Bool {
        thumbnailStore.state(for: item).isLoading
    }

    private func thumbnailFailed(_ item: WatchlistItem) -> Bool {
        thumbnailStore.state(for: item).didFail
    }

    private func row(_ item: WatchlistItem) -> some View {
        HStack(spacing: 14) {
            Toggle("", isOn: selectionManager.binding(for: item.id.uuidString, in: .watchlist))
                .toggleStyle(.checkbox)
            Group {
                if let image = thumbnail(for: item) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else if isThumbnailLoading(item) {
                    ZStack { Theme.surface2; ProgressView() }
                } else {
                    ZStack { Theme.surface2; Image(systemName: "photo") }
                }
            }
            .frame(width: 150, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .task(id: item.id, priority: .utility) {
                await thumbnailStore.load(item: item)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.provider.uppercased()).font(.caption2.bold()).foregroundStyle(Theme.accent)
                    if item.watched { Label("Watched", systemImage: "checkmark.circle.fill").font(.caption2) }
                }
                Text(item.title).font(.headline).lineLimit(2)
                Text("Added \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    WatchlistPillButton("Extract Links", systemImage: "link.badge.plus", tint: Theme.warning) {
                        extract([item])
                    }
                    .help("Extract downloadable links")
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
                        let removed = store.remove(id: item.id)
                        if let removed = removed {
                            selectionManager.registerUndo(itemIDs: [item.id.uuidString], context: .watchlist) {
                                store.add(removed)
                            }
                            removedItem = removed
                            ToastQueue.shared.showWithUndo(
                                "Removed from Watchlist",
                                type: .info,
                                duration: 8.0,
                                actionText: "Undo"
                            ) {
                                selectionManager.undoLastDelete(in: .watchlist)
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(14)
        .mobileCard(tint: item.watched ? Theme.success : Theme.accent, isElevated: false)
        .appContextMenu(
            title: item.title,
            subtitle: item.sourcePageURL,
            accent: item.watched ? Theme.success : Theme.accent,
            actions: [
                AppContextMenuAction("Extract Links", systemImage: "link.badge.plus", action: { extract([item]) }),
                AppContextMenuAction("Download", systemImage: "arrow.down.circle.fill", action: { download([item]) }),
                AppContextMenuAction("Copy Video URL", systemImage: "doc.on.doc", action: { ClipboardManager.copy(item.sourcePageURL) }),
                AppContextMenuAction(item.watched ? "Mark Unwatched" : "Mark Watched", systemImage: item.watched ? "circle" : "checkmark.circle.fill", action: { store.toggleWatched(id: item.id) }),
                AppContextMenuAction("Remove", systemImage: "trash", role: .destructive, action: {
                        let removed = store.remove(id: item.id)
                        if let removed = removed {
                            selectionManager.registerUndo(itemIDs: [item.id.uuidString], context: .watchlist) {
                                store.add(removed)
                            }
                            removedItem = removed
                            ToastQueue.shared.showWithUndo(
                                "Removed from Watchlist",
                                type: .info,
                                duration: 8.0,
                                actionText: "Undo"
                            ) {
                                selectionManager.undoLastDelete(in: .watchlist)
                            }
                        }
                    })
            ]
        )
    }

    private func selectedItems() -> [WatchlistItem] {
        visibleItems.filter { selected.contains($0.id.uuidString) }
    }

    private func groupItems(_ group: String) -> [WatchlistItem] {
        switch grouping {
        case .none: return visibleItems
        case .provider: return visibleItems.filter { $0.provider == group }
        case .watched: return visibleItems.filter { $0.watched == (group == "Watched") }
        }
    }

    private func moveWatchlistItems(in group: String, indices: IndexSet, newOffset: Int) {
        // We need to reorder in the full items array, not just visible items
        // First, get the group items in the order they appear in the full store.items
        let groupItemsArray = groupItems(group)
        // Create a mutable copy of the full items array
        var reorderedItems = store.items
        // For each index in indices, find the corresponding item in the full array and move it
        var movedItems: [WatchlistItem] = []
        for index in indices {
            if index < groupItemsArray.count {
                movedItems.append(groupItemsArray[index])
            }
        }
        // Remove moved items from their current positions
        for item in movedItems {
            if let idx = reorderedItems.firstIndex(where: { $0.id == item.id }) {
                reorderedItems.remove(at: idx)
            }
        }
        // Find the target position in the full array
        // The target position is after the item at newOffset in the group (or at end if newOffset >= count)
        let targetIndex: Int
        if newOffset >= groupItemsArray.count - indices.count {
            // Moving to end of group - find the last group item in full array
            let lastGroupItem = groupItemsArray.last!
            targetIndex = (reorderedItems.firstIndex(where: { $0.id == lastGroupItem.id }) ?? reorderedItems.count) + 1
        } else {
            // Moving to before the item at newOffset in group
            let targetGroupItem = groupItemsArray[newOffset]
            targetIndex = reorderedItems.firstIndex(where: { $0.id == targetGroupItem.id }) ?? reorderedItems.count
        }
        // Insert moved items at target position
        reorderedItems.insert(contentsOf: movedItems, at: min(targetIndex, reorderedItems.count))
        // Reassign sequential sortOrders
        for (index, item) in reorderedItems.enumerated() {
            reorderedItems[index].sortOrder = index
        }
        // Update store using public method
        store.reorderItems(reorderedItems)
    }

    private func extractSelected() { extract(selectedItems()) }
    private func downloadSelected() { download(selectedItems()) }

    private func extract(_ items: [WatchlistItem]) {
        guard !items.isEmpty else { return }
        AppStateManager.shared.pendingExtractTitles = Dictionary(
            items.map { ($0.sourcePageURL, $0.title) },
            uniquingKeysWith: { first, _ in first }
        )
        AppStateManager.shared.pendingExtractThumbnailURLs = Dictionary(
            items.compactMap { item in item.thumbnailURL.map { (item.sourcePageURL, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        AppStateManager.shared.pendingExtractURL = items.map(\.sourcePageURL).joined(separator: "\n")
        AppStateManager.shared.pendingExtractShouldStart = true
        AppStateManager.shared.select(.home)
    }

    private func download(_ items: [WatchlistItem]) {
        let context = DownloadJobContext(megaRemotePath: "")
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
