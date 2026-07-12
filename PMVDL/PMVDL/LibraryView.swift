import AppKit
import SwiftUI

@MainActor
struct LibraryView: View {
    @StateObject private var appState = AppStateManager.shared
    @StateObject private var library = VideoLibrary.shared
    @StateObject private var history = HistoryManager.shared
    @StateObject private var favorites = FeedFavoritesStore.shared
    @StateObject private var pipeline = LibraryPipelineStore.shared
    @StateObject private var thumbnailStore = LibraryThumbnailStore()
    let onUpgradeRequired: () -> Void

    @State private var searchText = ""
    @State private var timelineFilter: LibraryTimelineFilter = .all
    @State private var viewMode: LibraryViewMode = .list
    @State private var selectedEntryID: String?
    @State private var selection: Set<UUID> = []
    @State private var showingBulkDeleteConfirmation = false
    @State private var pendingDeleteItem: LibraryItem?
    @State private var pendingFavoriteRemoval: FeedFavoriteItem?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(onUpgradeRequired: @escaping () -> Void = {}) {
        self.onUpgradeRequired = onUpgradeRequired
    }

    private var timelineEntries: [LibraryTimelineEntry] {
        LibraryTimelineBuilder.entries(
            libraryItems: library.items,
            historyItems: history.items,
            completedUploads: history.completedUploads,
            favoriteItems: favorites.items
        )
    }

    private var favoriteURLs: Set<String> {
        Set(favorites.items.map { LibraryTimelineBuilder.normalizedURL($0.url) })
    }

    private var pipelineSearchTextByURL: [String: String] {
        Dictionary(uniqueKeysWithValues: library.items.map { item in
            (item.url, pipeline.searchText(for: item.url))
        })
    }

    private var filteredEntries: [LibraryTimelineEntry] {
        LibraryTimelineBuilder.filteredEntries(
            timelineEntries,
            query: searchText,
            filter: timelineFilter,
            favoriteURLs: favoriteURLs,
            pipelineSearchTextByURL: pipelineSearchTextByURL
        )
    }

    private var dayBuckets: [LibraryTimelineDayBucket] {
        Dictionary(grouping: filteredEntries) { entry in
            Calendar.current.startOfDay(for: entry.timestamp)
        }
        .map { date, entries in
            LibraryTimelineDayBucket(date: date, entries: entries.sorted { $0.timestamp > $1.timestamp })
        }
        .sorted { $0.date > $1.date }
    }

    private var visibleVideoItems: [LibraryItem] {
        filteredEntries.compactMap(\.libraryItem)
    }

    private var selectedItems: [LibraryItem] {
        library.items.filter { selection.contains($0.id) }
    }

    private var selectedEntry: LibraryTimelineEntry? {
        LibraryTimelineBuilder.selectedEntry(currentID: selectedEntryID, in: filteredEntries)
    }

    private var filteredEntryIDs: [String] {
        filteredEntries.map(\.id)
    }

    var body: some View {
        libraryShell
            .safeAreaInset(edge: .bottom) {
                selectionBar
            }
            .confirmationDialog(
                "Delete selected library items?",
                isPresented: $showingBulkDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete \(selection.count) Items", role: .destructive) {
                    deleteSelectedItems()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the selected items from the library. This cannot be undone.")
            }
            .confirmationDialog(
                "Delete from library?",
                isPresented: Binding(
                    get: { pendingDeleteItem != nil },
                    set: { if !$0 { pendingDeleteItem = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let item = pendingDeleteItem {
                        withAnimation {
                            library.remove(item)
                            favorites.remove(url: item.url)
                            selection.remove(item.id)
                        }
                    }
                    pendingDeleteItem = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteItem = nil
                }
            } message: {
                Text(pendingDeleteItem.map { "Remove \"\(LibraryDisplay.title(for: $0))\" from the library?" } ?? "")
            }
            .confirmationDialog(
                "Remove from Favorites?",
                isPresented: Binding(
                    get: { pendingFavoriteRemoval != nil },
                    set: { if !$0 { pendingFavoriteRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let item = pendingFavoriteRemoval {
                        favorites.remove(id: item.id)
                    }
                    pendingFavoriteRemoval = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingFavoriteRemoval = nil
                }
            } message: {
                Text(pendingFavoriteRemoval.map { "Remove \"\($0.title)\" from Favorites?" } ?? "")
            }
            .onExitCommand {
                handleExitCommand()
            }
            .onDeleteCommand {
                handleDeleteCommand()
            }
            .onChange(of: filteredEntryIDs) { _, _ in
                syncSelectedEntry()
            }
            .onChange(of: appState.pendingLibraryItemID) { _, newValue in
                focusLibraryItem(id: newValue)
            }
            .onAppear {
                syncSelectedEntry()
                focusLibraryItem(id: appState.pendingLibraryItemID)
            }
            .background(searchShortcut)
    }

    private var libraryShell: some View {
        ZStack {
            libraryScrollPanel
            selectedEntryModal
        }
    }

    private var libraryScrollPanel: some View {
        ScrollView {
            commandPanel
                .frame(
                    width: max(AppShellSurfaceMetrics.appModalSurfaceWidth(for: appState.windowSize) - 12, 760),
                    alignment: .topLeading
                )
                .frame(
                    minHeight: AppShellSurfaceMetrics.appModalAvailableHeight(
                        for: appState.windowSize,
                        reservedTopInset: AppShellSurfaceMetrics.appModalTitlebarClearance,
                        reservedBottomInset: 4
                    ),
                    alignment: .topLeading
                )
                .padding(.horizontal, 12)
                .padding(.top, AppShellSurfaceMetrics.appModalBackdropInset)
                .padding(.bottom, selection.isEmpty ? 92 : 132)
        }
    }

    private var commandPanel: some View {
        LibraryCommandPanel(
            searchText: $searchText,
            timelineFilter: $timelineFilter,
            viewMode: $viewMode,
            visibleCount: filteredEntries.count,
            totalCount: timelineEntries.count,
            counts: LibraryTimelineFilterCounts(entries: timelineEntries, favoriteURLs: favoriteURLs),
            isRefreshing: thumbnailStore.isRefreshing,
            canRefreshThumbnails: !visibleVideoItems.isEmpty,
            searchFocused: $searchFocused,
            refreshAction: regenerateAllThumbnails,
            favoritesAllowed: ProFeatureGate.canUseFavorites,
            onFavoritesRequested: showFavoritesOrUpgrade
        ) {
            content
        }
    }

    @ViewBuilder
    private var selectedEntryModal: some View {
        if viewMode == .list, let selectedEntry {
            AppModalOverlay(dismiss: { selectedEntryID = nil }, size: .detail) {
                LibraryDetailModalShell {
                    detailPanel(for: selectedEntry)
                }
            }
            .zIndex(20)
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if !selection.isEmpty {
            LibrarySelectionBar(
                count: selection.count,
                deleteAction: { showingBulkDeleteConfirmation = true },
                uploadMegaAction: { uploadSelected(to: .mega) },
                uploadDriveAction: { uploadSelected(to: .gdrive) },
                clearAction: { selection.removeAll() }
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            .frame(maxWidth: AppShellSurfaceMetrics.appModalSurfaceWidth(for: appState.windowSize))
            .frame(maxWidth: .infinity)
        }
    }

    private var searchShortcut: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
    }

    private func showFavoritesOrUpgrade() {
        if ProFeatureGate.canUseFavorites {
            timelineFilter = .favorites
        } else {
            onUpgradeRequired()
        }
    }

    private func handleExitCommand() {
        if searchFocused {
            if searchText.isEmpty {
                searchFocused = false
            } else {
                searchText = ""
            }
        } else if !selection.isEmpty {
            selection.removeAll()
        } else if selectedEntryID != nil {
            selectedEntryID = nil
        }
    }

    private func handleDeleteCommand() {
        if !selection.isEmpty {
            showingBulkDeleteConfirmation = true
        } else if let selectedEntry {
            switch selectedEntry {
            case .video(let item):
                pendingDeleteItem = item
            case .favorite(let item):
                pendingFavoriteRemoval = item
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if timelineEntries.isEmpty {
            LibraryEmptyState()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        } else if filteredEntries.isEmpty {
            LibraryNoResultsState(
                searchText: searchText,
                filter: timelineFilter,
                clearAction: clearFilters
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        } else {
            switch viewMode {
            case .list:
                timelineScroll()
            case .grid:
                thumbnailBrowser()
            }
        }
    }

    private func timelineScroll() -> some View {
        LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
            ForEach(dayBuckets) { bucket in
                Section {
                    ForEach(bucket.entries) { entry in
                        LibraryTimelineRow(
                            entry: entry,
                            thumbnail: thumbnail(for: entry),
                            isThumbnailLoading: isThumbnailLoading(entry),
                            thumbnailFailed: thumbnailFailed(entry),
                            isPreviewSelected: selectedEntry?.id == entry.id,
                            isBulkSelected: isBulkSelected(entry),
                            refreshThumbnail: { item in
                                Task { await thumbnailStore.load(item: item, force: true) }
                            },
                            openMedia: openPreferredMedia,
                            openSource: openSource,
                            reExtractVideo: reExtract,
                            uploadVideo: { item, target in uploadItems([item], to: target) },
                            requestDeleteVideo: { pendingDeleteItem = $0 },
                            toggleFavoriteVideo: toggleFavorite,
                            selectEntry: selectEntry,
                            toggleVideoSelection: toggleVideoSelection,
                            extractAgain: reExtract,
                            removeLink: { history.remove($0) },
                            removeUpload: { history.removeCompletedUpload($0) },
                            extractFavorite: extractFavorite,
                            removeFavorite: { pendingFavoriteRemoval = $0 },
                            pipelineStore: pipeline,
                            favoritesStore: favorites,
                            onUpgradeRequired: onUpgradeRequired
                        )
                        .task(id: entry.thumbnailIdentity) {
                            if case .video(let item) = entry {
                                await thumbnailStore.load(item: item)
                            }
                        }
                    }
                } header: {
                    LibraryDayHeader(date: bucket.date, count: bucket.entries.count)
                }
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
    }

    private func thumbnailBrowser() -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                thumbnailGrid()
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)

                detailSidebar
                    .frame(width: 360)
            }

            VStack(alignment: .leading, spacing: 14) {
                thumbnailGrid()
                detailSidebar
            }
        }
        .padding(.top, 2)
    }

    private func thumbnailGrid() -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(filteredEntries) { entry in
                LibraryThumbnailGridCard(
                    entry: entry,
                    thumbnail: thumbnail(for: entry),
                    isThumbnailLoading: isThumbnailLoading(entry),
                    thumbnailFailed: thumbnailFailed(entry),
                    isSelected: selectedEntry?.id == entry.id,
                    isBulkSelected: isBulkSelected(entry),
                    refreshThumbnail: { item in
                        Task { await thumbnailStore.load(item: item, force: true) }
                    },
                    selectEntry: selectEntry,
                    toggleVideoSelection: toggleVideoSelection,
                    pipelineStore: pipeline,
                    favoritesStore: favorites
                )
                .task(id: entry.thumbnailIdentity) {
                    if case .video(let item) = entry {
                        await thumbnailStore.load(item: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var detailSidebar: some View {
        if let selectedEntry {
            ScrollView {
                detailPanel(for: selectedEntry)
            }
            .frame(maxHeight: AppShellSurfaceMetrics.mainPanelHeight(for: appState.windowSize) - 190)
        } else {
            LibraryInlineDetailEmptyState()
        }
    }

    private func detailPanel(for entry: LibraryTimelineEntry) -> some View {
        LibraryDetailPanel(
            entry: entry,
            thumbnail: thumbnail(for: entry),
            isThumbnailLoading: isThumbnailLoading(entry),
            thumbnailFailed: thumbnailFailed(entry),
            refreshThumbnail: { item in
                Task { await thumbnailStore.load(item: item, force: true) }
            },
            openMedia: openPreferredMedia,
            openSource: openSource,
            reExtractVideo: reExtract,
            uploadVideo: { item, target in uploadItems([item], to: target) },
            requestDeleteVideo: { pendingDeleteItem = $0 },
            toggleFavoriteVideo: toggleFavorite,
            extractAgain: reExtract,
            removeLink: { history.remove($0) },
            removeUpload: { history.removeCompletedUpload($0) },
            openURL: openURLString,
            extractFavorite: extractFavorite,
            removeFavorite: { pendingFavoriteRemoval = $0 },
            pipelineStore: pipeline,
            favoritesStore: favorites,
            onUpgradeRequired: onUpgradeRequired
        )
    }

    private func regenerateAllThumbnails() {
        let items = visibleVideoItems
        guard !items.isEmpty else { return }
        Task {
            await thumbnailStore.refresh(items: items, force: true)
        }
    }

    private func clearFilters() {
        searchText = ""
        timelineFilter = .all
    }

    private func thumbnail(for entry: LibraryTimelineEntry) -> NSImage? {
        guard let item = entry.libraryItem else { return nil }
        return thumbnailStore.image(for: item)
    }

    private func isThumbnailLoading(_ entry: LibraryTimelineEntry) -> Bool {
        guard let item = entry.libraryItem else { return false }
        return thumbnailStore.isLoading(item)
    }

    private func thumbnailFailed(_ entry: LibraryTimelineEntry) -> Bool {
        guard let item = entry.libraryItem else { return false }
        return thumbnailStore.didFail(item)
    }

    private func isBulkSelected(_ entry: LibraryTimelineEntry) -> Bool {
        guard let item = entry.libraryItem else { return false }
        return selection.contains(item.id)
    }

    private func selectEntry(_ entry: LibraryTimelineEntry) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.78)) {
            selectedEntryID = entry.id
        }
    }

    private func toggleVideoSelection(_ entry: LibraryTimelineEntry) {
        selection = LibraryTimelineBuilder.videoSelection(selection, toggling: entry)
    }

    private func syncSelectedEntry() {
        selectedEntryID = LibraryTimelineBuilder.selectedEntryID(currentID: selectedEntryID, in: filteredEntries)
    }

    private func focusLibraryItem(id: UUID?) {
        guard let id,
              library.items.contains(where: { $0.id == id }) else { return }
        searchText = ""
        timelineFilter = .videos
        selection.removeAll()
        selectedEntryID = "video-\(id.uuidString)"
        appState.pendingLibraryItemID = nil
    }

    private func deleteSelectedItems() {
        let items = selectedItems
        withAnimation {
            for item in items {
                library.remove(item)
                favorites.remove(url: item.url)
            }
            selection.removeAll()
        }
    }

    private func openPreferredMedia(for item: LibraryItem) {
        let candidate = item.mp4Url ?? item.remotePaths[CloudTarget.local.rawValue] ?? item.hlsUrls.first(where: { $0.kind != .pageUrl })?.url ?? item.url
        openURLString(candidate)
    }

    private func openSource(for item: LibraryItem) {
        openURLString(item.url)
    }

    private func openURLString(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func reExtract(_ item: LibraryItem) {
        appState.pendingExtractURL = item.url
        appState.pendingExtractShouldStart = true
        appState.select(.home)
    }

    private func reExtract(_ item: HistoryItem) {
        appState.pendingExtractURL = item.url
        appState.pendingExtractShouldStart = true
        appState.select(.home)
    }

    private func extractFavorite(_ item: FeedFavoriteItem) {
        guard ProFeatureGate.canUseFavorites else {
            onUpgradeRequired()
            return
        }
        LibraryFavoritesActions.extract(item, appState: appState)
    }

    private func uploadSelected(to target: CloudTarget) {
        uploadItems(selectedItems, to: target)
        selection.removeAll()
    }

    private func uploadItems(_ items: [LibraryItem], to target: CloudTarget) {
        let context = LibraryDownloadContext.current()
        for item in items {
            guard let resolution = LibraryDownloadContext.resolution(for: item) else { continue }
            guard ProFeatureGate.canDownloadAudio || !resolution.isAudio else {
                onUpgradeRequired()
                return
            }
            DownloadJobRunner.shared.start(resolution: resolution, target: target, context: context)
        }
        appState.select(.home)
    }

    private func toggleFavorite(_ item: LibraryItem) {
        guard ProFeatureGate.canUseFavorites else {
            onUpgradeRequired()
            return
        }

        if favorites.contains(url: item.url) {
            favorites.remove(url: item.url)
        } else {
            favorites.add(
                FeedFavoriteItem(
                    id: FeedFavoriteItem.normalizedURL(item.url),
                    title: LibraryDisplay.title(for: item),
                    url: FeedFavoriteItem.normalizedURL(item.url),
                    thumbnailURL: item.thumbnailURL,
                    uploadDate: item.extractedAt,
                    favoritedAt: Date(),
                    viewCount: 0,
                    siteName: LibraryDisplay.domain(for: item.url),
                    studio: item.uploaderName,
                    durationSeconds: nil,
                    categories: [],
                    tags: [],
                    performers: [],
                    qualityLabels: [LibrarySourceKind.kind(for: item).label],
                    sourceKind: "library"
                )
            )
        }
    }
}

private struct LibraryCommandPanel<Content: View>: View {
    @Binding var searchText: String
    @Binding var timelineFilter: LibraryTimelineFilter
    @Binding var viewMode: LibraryViewMode

    let visibleCount: Int
    let totalCount: Int
    let counts: LibraryTimelineFilterCounts
    let isRefreshing: Bool
    let canRefreshThumbnails: Bool
    let searchFocused: FocusState<Bool>.Binding
    let refreshAction: () -> Void
    let favoritesAllowed: Bool
    let onFavoritesRequested: () -> Void
    @ViewBuilder let content: () -> Content
    @ObservedObject private var appState = AppStateManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    titleBlock
                    Spacer(minLength: 16)
                    statusPills
                }

                VStack(alignment: .leading, spacing: 12) {
                    titleBlock
                    statusPills
                }
            }

            Divider()
                .overlay(Theme.borderSubtle.opacity(0.65))

            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        LibrarySearchField(text: $searchText, searchFocused: searchFocused)
                        LibraryViewModePicker(selection: $viewMode)
                        refreshButton
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        LibrarySearchField(text: $searchText, searchFocused: searchFocused)
                        HStack(spacing: 10) {
                            LibraryViewModePicker(selection: $viewMode)
                            refreshButton
                        }
                    }
                }

                LibraryFilterChips(
                    selection: $timelineFilter,
                    counts: counts,
                    favoritesAllowed: favoritesAllowed,
                    onFavoritesRequested: onFavoritesRequested
                )
            }

            content()
        }
        .padding(28)
        .frame(minHeight: AppShellSurfaceMetrics.appModalSurfaceHeight(for: appState.windowSize), alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [
                            Theme.surfaceGlass.opacity(0.76),
                            Theme.surface1.opacity(0.52)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Theme.border.opacity(0.64), lineWidth: 1)
        )
        .shadow(color: Theme.skyBlue.opacity(0.12), radius: 20, x: 0, y: 16)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Library")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Text("Review extracted videos, saved links, uploads, and favorites.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
    }

    private var statusPills: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                LibraryStatusPill(title: LibrarySummaryText.summary(visibleCount: visibleCount, totalCount: totalCount), systemName: "rectangle.stack.fill", tint: Theme.skyBlue)
                LibraryStatusPill(title: "\(counts.count(for: .videos)) videos", systemName: "play.rectangle.fill", tint: Theme.success)
                LibraryStatusPill(title: "\(counts.count(for: .favorites)) favorites", systemName: "heart.fill", tint: Theme.hotPink)
            }

            VStack(alignment: .leading, spacing: 8) {
                LibraryStatusPill(title: LibrarySummaryText.summary(visibleCount: visibleCount, totalCount: totalCount), systemName: "rectangle.stack.fill", tint: Theme.skyBlue)
                LibraryStatusPill(title: "\(counts.count(for: .videos)) videos", systemName: "play.rectangle.fill", tint: Theme.success)
                LibraryStatusPill(title: "\(counts.count(for: .favorites)) favorites", systemName: "heart.fill", tint: Theme.hotPink)
            }
        }
    }

    private var refreshButton: some View {
        Button(action: refreshAction) {
            HStack(spacing: 6) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.72)
                    Text("Refreshing")
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Refresh Thumbnails")
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isRefreshing || !canRefreshThumbnails ? Theme.textSecondary.opacity(0.55) : Theme.skyBlue)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.skyBlue.opacity(0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.skyBlue.opacity(0.28), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing || !canRefreshThumbnails)
    }
}

private struct LibraryStatusPill: View {
    let title: String
    let systemName: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemName)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.24), lineWidth: 0.5))
    }
}

private struct LibraryViewModePicker: View {
    @Binding var selection: LibraryViewMode

    var body: some View {
        HStack(spacing: 4) {
            ForEach(LibraryViewMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(selection == mode ? Theme.textPrimary : Theme.textSecondary)
                        .frame(width: 28, height: 26)
                        .background(selection == mode ? mode.tint.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selection == mode ? mode.tint.opacity(0.45) : .clear, lineWidth: 0.7)
                        )
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .padding(3)
        .background(Theme.surface0.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderSubtle.opacity(0.8), lineWidth: 0.5))
    }
}

private struct LibrarySearchField: View {
    @Binding var text: String
    let searchFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField("Search title, provider, URL, destination, or error", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(searchFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.surface0.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.borderSubtle.opacity(0.8), lineWidth: 0.5))
        .frame(maxWidth: 520)
    }
}

private struct LibraryFilterChips: View {
    @Binding var selection: LibraryTimelineFilter
    let counts: LibraryTimelineFilterCounts
    let favoritesAllowed: Bool
    let onFavoritesRequested: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LibraryTimelineFilter.allCases) { filter in
                    LibraryFilterChip(
                        title: filter.title,
                        count: counts.count(for: filter),
                        tint: filter.tint,
                        isSelected: selection == filter,
                        isLocked: filter == .favorites && !favoritesAllowed
                    ) {
                        if filter == .favorites && !favoritesAllowed {
                            onFavoritesRequested()
                        } else {
                            selection = filter
                        }
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: 540)
    }
}

private struct LibraryFilterChip: View {
    let title: String
    let count: Int
    let tint: Color
    let isSelected: Bool
    let isLocked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .bold))
                }
                Text(title)
                Text("\(count)")
                    .font(.system(size: 9, weight: .black))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.white.opacity(isSelected ? 0.24 : 0.12), in: Capsule())
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background((isSelected ? tint : tint.opacity(0.45)), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(isSelected ? 0.28 : 0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

private enum LibrarySummaryText {
    static func summary(visibleCount: Int, totalCount: Int) -> String {
        if totalCount == 1 { return "1 item" }
        if visibleCount == totalCount { return "\(totalCount) items" }
        return "\(visibleCount) of \(totalCount) items"
    }
}

private struct LibraryDayHeader: View {
    let date: Date
    let count: Int

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Text(LibraryDateFormatter.dayLabel(for: date))
                    .font(.system(size: 11, weight: .bold))
                Text("\(count)")
                    .font(.system(size: 9, weight: .black))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.skyBlue.opacity(0.18), in: Capsule())
            }
            .foregroundStyle(Theme.skyBlue)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.surface0.opacity(0.62), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.skyBlue.opacity(0.25), lineWidth: 0.5))

            Spacer()
        }
        .padding(.vertical, 4)
        .background(
            LinearGradient(
                colors: [Theme.surfaceGlass.opacity(0.9), Theme.surfaceGlass.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct LibraryTimelineRow: View {
    let entry: LibraryTimelineEntry
    let thumbnail: NSImage?
    let isThumbnailLoading: Bool
    let thumbnailFailed: Bool
    let isPreviewSelected: Bool
    let isBulkSelected: Bool
    let refreshThumbnail: (LibraryItem) -> Void
    let openMedia: (LibraryItem) -> Void
    let openSource: (LibraryItem) -> Void
    let reExtractVideo: (LibraryItem) -> Void
    let uploadVideo: (LibraryItem, CloudTarget) -> Void
    let requestDeleteVideo: (LibraryItem) -> Void
    let toggleFavoriteVideo: (LibraryItem) -> Void
    let selectEntry: (LibraryTimelineEntry) -> Void
    let toggleVideoSelection: (LibraryTimelineEntry) -> Void
    let extractAgain: (HistoryItem) -> Void
    let removeLink: (HistoryItem) -> Void
    let removeUpload: (CompletedUploadItem) -> Void
    let extractFavorite: (FeedFavoriteItem) -> Void
    let removeFavorite: (FeedFavoriteItem) -> Void
    let pipelineStore: LibraryPipelineStore
    let favoritesStore: FeedFavoritesStore
    let onUpgradeRequired: () -> Void

    @State private var isHovering = false

    private var rowTint: Color {
        switch entry {
        case .video(let item):
            return LibrarySourceKind.kind(for: item).tint
        case .link(let item):
            return LibraryTimelineProviderTint.color(for: item.provider)
        case .upload(let item):
            return LibraryTimelineDestinationFormatter.color(for: item.destination)
        case .favorite:
            return Theme.hotPink
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            leadingTile

            VStack(alignment: .leading, spacing: 6) {
                titleLine
                detailLine
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Text(LibraryDateFormatter.timeLabel(for: entry.timestamp))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)

            actions
                .opacity(isHovering || isPreviewSelected ? 1 : 0)
                .allowsHitTesting(isHovering || isPreviewSelected)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.surface0.opacity(isPreviewSelected ? 0.66 : 0.42))
        )
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(rowTint.opacity(isPreviewSelected ? 0.12 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isPreviewSelected ? Theme.skyBlue.opacity(0.72) : Theme.borderSubtle.opacity(0.72), lineWidth: isPreviewSelected ? 1.2 : 0.5)
        )
        .overlay(alignment: .leading) {
            Capsule()
                .fill(rowTint.opacity(isPreviewSelected ? 0.92 : 0.45))
                .frame(width: 3)
                .padding(.vertical, 9)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { isHovering = $0 }
        .onTapGesture { handleTap() }
        .help(entry.url)
        .appContextMenu(title: entry.title, subtitle: entry.url, accent: rowTint, actions: contextActions)
    }

    @ViewBuilder
    private var leadingTile: some View {
        switch entry {
        case .video(let item):
            ZStack(alignment: .topLeading) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.surface2)

                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LibraryThumbnailPlaceholder(
                            item: item,
                            isLoading: isThumbnailLoading,
                            didFail: thumbnailFailed,
                            retryAction: { refreshThumbnail(item) }
                        )
                    }
                }
                .frame(width: 72, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if isBulkSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.gold)
                        .padding(5)
                }
            }
        case .favorite(let item):
            favoriteTile(item)
        case .link:
            timelineIconTile(systemName: "play.rectangle.fill", tint: rowTint)
        case .upload:
            timelineIconTile(systemName: "checkmark.icloud.fill", tint: rowTint)
        }
    }

    private func favoriteTile(_ item: FeedFavoriteItem) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.hotPink.opacity(0.18))

            if let thumbnailURL = item.thumbnailURL,
               let url = URL(string: thumbnailURL) {
                RefererAwareAsyncImage(url: url, referer: item.referer) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Image(systemName: "heart.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Theme.hotPink)
                    }
                }
            } else {
                Image(systemName: "heart.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.hotPink)
            }
        }
        .frame(width: 72, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func timelineIconTile(systemName: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.surface2.opacity(0.9))
            .frame(width: 72, height: 42)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(0.32), lineWidth: 0.8)
            )
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(tint)
            )
    }

    @ViewBuilder
    private var titleLine: some View {
        HStack(spacing: 6) {
            switch entry {
            case .video(let item):
                LibraryKindBadge(kind: LibrarySourceKind.kind(for: item))
                if favoritesStore.contains(url: item.url) {
                    LibraryTimelineHeart(isFilled: true, tint: Theme.hotPink)
                }
                ForEach(LibraryPipelineDisplay.compactBadges(for: item.url, store: pipelineStore), id: \.id) { badge in
                    LibraryPipelineBadge(badge: badge)
                }
            case .link(let item):
                LibraryTimelineProviderPill(provider: item.provider)
            case .upload(let item):
                LibraryTimelineProviderPill(provider: item.provider)
                LibraryTimelineDestinationChip(destination: item.destination)
            case .favorite:
                LibraryTimelineHeart(isFilled: true, tint: Theme.hotPink)
                LibraryTimelineProviderPill(provider: "Favorites")
            }

            Text(entry.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        switch entry {
        case .video(let item):
            Text(LibraryDisplay.detailLine(for: item, pipelineStore: pipelineStore))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .link(let item):
            Text(LibraryTimelineURLFormatter.prettyURL(item.url))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .upload(let item):
            Text("up \(LibraryTimelineDestinationFormatter.displayName(for: item.destination)) · \(item.remotePath)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .favorite(let item):
            Text(FavoritesDisplay.searchText(for: item))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            switch entry {
            case .video(let item):
                LibraryTimelineIconButton(systemName: favoritesStore.contains(url: item.url) ? "heart.fill" : "heart", help: "Favorite") {
                    toggleFavoriteVideo(item)
                }
                LibraryTimelineIconButton(systemName: "play.fill", help: "Open media") { openMedia(item) }
                LibraryTimelineIconButton(systemName: "safari", help: "Open source page") { openSource(item) }
                LibraryTimelineIconButton(systemName: "arrow.clockwise", help: "Re-extract") { reExtractVideo(item) }
                Menu {
                    Button("Local") { uploadVideo(item, .local) }
                    Button("Mega") { uploadVideo(item, .mega) }
                    Button("Google Drive") { uploadVideo(item, .gdrive) }
                    Button("Seedbox") { uploadVideo(item, .seedbox) }
                } label: {
                    LibraryTimelineMenuLabel(systemName: "arrow.up.circle", help: "Send")
                }
                .menuStyle(.borderlessButton)
            case .link(let item):
                LibraryTimelineIconButton(systemName: "arrow.clockwise", help: "Extract again") { extractAgain(item) }
                LibraryTimelineIconButton(systemName: "doc.on.doc", help: "Copy link") { ClipboardManager.copy(item.url) }
                LibraryTimelineIconButton(systemName: "safari", help: "Open link") { openURL(item.url) }
                LibraryTimelineIconButton(systemName: "trash", help: "Remove") { removeLink(item) }
            case .upload(let item):
                LibraryTimelineIconButton(systemName: "arrow.up.right.square", help: "Copy remote path") { ClipboardManager.copy(item.remotePath) }
                LibraryTimelineIconButton(systemName: "doc.on.doc", help: "Copy source link") { ClipboardManager.copy(item.url) }
                LibraryTimelineIconButton(systemName: "safari", help: "Open source") { openURL(item.url) }
                LibraryTimelineIconButton(systemName: "trash", help: "Remove") { removeUpload(item) }
            case .favorite(let item):
                LibraryTimelineIconButton(systemName: "arrow.clockwise", help: "Extract") { extractFavorite(item) }
                LibraryTimelineIconButton(systemName: "doc.on.doc", help: "Copy link") { ClipboardManager.copy(item.url) }
                LibraryTimelineIconButton(systemName: "safari", help: "Open source") { openURL(item.url) }
                LibraryTimelineIconButton(systemName: "heart.slash", help: "Remove favorite") { removeFavorite(item) }
            }
        }
    }

    private var contextActions: [AppContextMenuAction] {
        switch entry {
        case .video(let item):
            var actions = [
                AppContextMenuAction(favoritesStore.contains(url: item.url) ? "Remove Favorite" : "Add Favorite", systemImage: "heart", action: { toggleFavoriteVideo(item) }),
                AppContextMenuAction("Open Source Page", systemImage: "safari", action: { openSource(item) }),
                AppContextMenuAction("Open Media", systemImage: "play.rectangle", action: { openMedia(item) }),
                AppContextMenuAction("Re-extract", systemImage: "arrow.clockwise", action: { reExtractVideo(item) }),
                AppContextMenuAction("Send to Local", systemImage: "arrow.up.circle", action: { uploadVideo(item, .local) }),
                AppContextMenuAction("Send to Mega", systemImage: "arrow.up.circle", action: { uploadVideo(item, .mega) }),
                AppContextMenuAction("Send to Google Drive", systemImage: "arrow.up.circle", action: { uploadVideo(item, .gdrive) }),
                AppContextMenuAction("Send to Seedbox", systemImage: "arrow.up.circle", action: { uploadVideo(item, .seedbox) }),
                AppContextMenuAction("Refresh Thumbnail", systemImage: "photo", action: { refreshThumbnail(item) }),
                AppContextMenuAction("Copy Page URL", systemImage: "doc.on.doc", action: { ClipboardManager.copy(item.url) })
            ]
            if let mp4 = item.mp4Url {
                actions.append(AppContextMenuAction("Copy MP4 Link", systemImage: "doc.on.doc", action: { ClipboardManager.copy(mp4) }))
            }
            actions.append(AppContextMenuAction("Delete from Library", systemImage: "trash", role: .destructive, action: { requestDeleteVideo(item) }))
            return actions
        case .link(let item):
            return [
                AppContextMenuAction("Extract Again", systemImage: "arrow.clockwise", action: { extractAgain(item) }),
                AppContextMenuAction("Copy Link", systemImage: "doc.on.doc", action: { ClipboardManager.copy(item.url) }),
                AppContextMenuAction("Open Link", systemImage: "safari", action: { openURL(item.url) }),
                AppContextMenuAction("Remove", systemImage: "trash", role: .destructive, action: { removeLink(item) })
            ]
        case .upload(let item):
            return [
                AppContextMenuAction("Copy Remote Path", systemImage: "folder", action: { ClipboardManager.copy(item.remotePath) }),
                AppContextMenuAction("Copy Source Link", systemImage: "doc.on.doc", action: { ClipboardManager.copy(item.url) }),
                AppContextMenuAction("Open Source Link", systemImage: "safari", action: { openURL(item.url) }),
                AppContextMenuAction("Remove", systemImage: "trash", role: .destructive, action: { removeUpload(item) })
            ]
        case .favorite(let item):
            return [
                AppContextMenuAction("Extract", systemImage: "bolt.fill", action: { extractFavorite(item) }),
                AppContextMenuAction("Copy Link", systemImage: "doc.on.doc", action: { ClipboardManager.copy(item.url) }),
                AppContextMenuAction("Open Link", systemImage: "safari", action: { openURL(item.url) }),
                AppContextMenuAction("Remove Favorite", systemImage: "heart.slash", role: .destructive, action: { removeFavorite(item) })
            ]
        }
    }

    private func handleTap() {
        if case .favorite = entry, !ProFeatureGate.canUseFavorites {
            onUpgradeRequired()
            return
        }
        if NSEvent.modifierFlags.contains(.command) {
            toggleVideoSelection(entry)
            return
        }
        selectEntry(entry)
    }

    private func openURL(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct LibraryThumbnailGridCard: View {
    let entry: LibraryTimelineEntry
    let thumbnail: NSImage?
    let isThumbnailLoading: Bool
    let thumbnailFailed: Bool
    let isSelected: Bool
    let isBulkSelected: Bool
    let refreshThumbnail: (LibraryItem) -> Void
    let selectEntry: (LibraryTimelineEntry) -> Void
    let toggleVideoSelection: (LibraryTimelineEntry) -> Void
    let pipelineStore: LibraryPipelineStore
    let favoritesStore: FeedFavoritesStore

    @State private var isHovering = false

    private var tint: Color {
        switch entry {
        case .video(let item):
            return LibrarySourceKind.kind(for: item).tint
        case .link(let item):
            return LibraryTimelineProviderTint.color(for: item.provider)
        case .upload(let item):
            return LibraryTimelineDestinationFormatter.color(for: item.destination)
        case .favorite:
            return Theme.hotPink
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            mediaTile

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    badges
                }
                .frame(height: 18, alignment: .leading)

                Text(entry.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detailText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(9)
        .background(Theme.surface0.opacity(isSelected ? 0.68 : 0.44), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Theme.skyBlue.opacity(0.78) : Theme.borderSubtle.opacity(0.7), lineWidth: isSelected ? 1.2 : 0.6)
        )
        .shadow(color: isSelected ? Theme.skyBlue.opacity(0.16) : .clear, radius: 12, x: 0, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovering = $0 }
        .onTapGesture { handleTap() }
        .help(entry.url)
    }

    @ViewBuilder
    private var mediaTile: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.surface2)

                switch entry {
                case .video(let item):
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LibraryThumbnailPlaceholder(
                            item: item,
                            isLoading: isThumbnailLoading,
                            didFail: thumbnailFailed,
                            retryAction: { refreshThumbnail(item) }
                        )
                    }
                case .favorite(let item):
                    favoriteImage(item)
                case .link:
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(tint)
                case .upload:
                    Image(systemName: "checkmark.icloud.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if isBulkSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.gold)
                    .padding(7)
            }

            if isHovering || isSelected {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(6)
                    .background(.black.opacity(0.42), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(7)
            }
        }
    }

    @ViewBuilder
    private func favoriteImage(_ item: FeedFavoriteItem) -> some View {
        if let thumbnailURL = item.thumbnailURL,
           let url = URL(string: thumbnailURL) {
            RefererAwareAsyncImage(url: url, referer: item.referer) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    Image(systemName: "heart.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Theme.hotPink)
                }
            }
        } else {
            Image(systemName: "heart.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.hotPink)
        }
    }

    @ViewBuilder
    private var badges: some View {
        switch entry {
        case .video(let item):
            LibraryKindBadge(kind: LibrarySourceKind.kind(for: item))
            if favoritesStore.contains(url: item.url) {
                LibraryTimelineHeart(isFilled: true, tint: Theme.hotPink)
            }
        case .link(let item):
            LibraryTimelineProviderPill(provider: item.provider)
        case .upload(let item):
            LibraryTimelineDestinationChip(destination: item.destination)
        case .favorite:
            LibraryTimelineHeart(isFilled: true, tint: Theme.hotPink)
            LibraryTimelineProviderPill(provider: "Favorites")
        }
    }

    private var detailText: String {
        switch entry {
        case .video(let item):
            return LibraryDisplay.detailLine(for: item, pipelineStore: pipelineStore)
        case .link(let item):
            return LibraryTimelineURLFormatter.prettyURL(item.url)
        case .upload(let item):
            return LibraryTimelineDestinationFormatter.displayName(for: item.destination)
        case .favorite(let item):
            return item.siteName
        }
    }

    private func handleTap() {
        if case .favorite = entry, !ProFeatureGate.canUseFavorites {
            return
        }
        if NSEvent.modifierFlags.contains(.command) {
            toggleVideoSelection(entry)
            return
        }
        selectEntry(entry)
    }
}

private struct LibraryInlineDetailEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("Select an item")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(Theme.surface0.opacity(0.38), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.borderSubtle.opacity(0.7), lineWidth: 0.6))
    }
}

private struct LibraryDetailModalShell<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LibraryDetailPanel: View {
    let entry: LibraryTimelineEntry
    let thumbnail: NSImage?
    let isThumbnailLoading: Bool
    let thumbnailFailed: Bool
    let refreshThumbnail: (LibraryItem) -> Void
    let openMedia: (LibraryItem) -> Void
    let openSource: (LibraryItem) -> Void
    let reExtractVideo: (LibraryItem) -> Void
    let uploadVideo: (LibraryItem, CloudTarget) -> Void
    let requestDeleteVideo: (LibraryItem) -> Void
    let toggleFavoriteVideo: (LibraryItem) -> Void
    let extractAgain: (HistoryItem) -> Void
    let removeLink: (HistoryItem) -> Void
    let removeUpload: (CompletedUploadItem) -> Void
    let openURL: (String) -> Void
    let extractFavorite: (FeedFavoriteItem) -> Void
    let removeFavorite: (FeedFavoriteItem) -> Void
    let pipelineStore: LibraryPipelineStore
    let favoritesStore: FeedFavoritesStore
    let onUpgradeRequired: () -> Void

    private var tint: Color {
        switch entry {
        case .video(let item):
            return LibrarySourceKind.kind(for: item).tint
        case .link(let item):
            return LibraryTimelineProviderTint.color(for: item.provider)
        case .upload(let item):
            return LibraryTimelineDestinationFormatter.color(for: item.destination)
        case .favorite:
            return Theme.hotPink
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch entry {
            case .video(let item):
                videoPanel(item)
            case .link(let item):
                linkPanel(item)
            case .upload(let item):
                uploadPanel(item)
            case .favorite(let item):
                favoritePanel(item)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.surface0.opacity(0.48))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tint.opacity(0.24), lineWidth: 0.8)
        )
    }

    private func videoPanel(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.surface2)

                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LibraryThumbnailPlaceholder(
                            item: item,
                            isLoading: isThumbnailLoading,
                            didFail: thumbnailFailed,
                            retryAction: { refreshThumbnail(item) }
                        )
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 6) {
                    favoriteButton(for: item)
                    LibraryKindBadge(kind: LibrarySourceKind.kind(for: item))
                }
                .padding(8)
            }

            titleBlock(title: LibraryDisplay.title(for: item), subtitle: LibraryDisplay.domain(for: item.url))

            pipelineSection(for: item.url)

            metadataRows {
                LibraryDetailMetadataRow(label: "Source", value: item.url, systemName: "link")
                LibraryDetailMetadataRow(label: "Extracted", value: item.extractedAt.formatted(date: .abbreviated, time: .shortened), systemName: "calendar")
                LibraryDetailMetadataRow(label: "Media", value: LibrarySourceKind.kind(for: item).label, systemName: "film")
            }

            actionGroup {
                LibraryDetailActionButton(title: "Open Media", systemName: "play.fill", tint: Theme.skyBlue) { openMedia(item) }
                LibraryDetailActionButton(title: "Open Source", systemName: "safari", tint: Theme.textSecondary) { openSource(item) }
                LibraryDetailActionButton(title: "Re-extract", systemName: "arrow.clockwise", tint: Theme.lavender) { reExtractVideo(item) }
                LibraryDetailMenuButton(title: "Send", systemName: "arrow.up.circle", tint: Theme.success) {
                    Button("Local") { uploadVideo(item, .local) }
                    Button("Mega") { uploadVideo(item, .mega) }
                    Button("Google Drive") { uploadVideo(item, .gdrive) }
                    Button("Seedbox") { uploadVideo(item, .seedbox) }
                }
                LibraryDetailActionButton(title: "Refresh Thumbnail", systemName: "photo", tint: Theme.skyBlue) { refreshThumbnail(item) }
                LibraryDetailActionButton(title: "Delete", systemName: "trash", tint: Theme.error, role: .destructive) { requestDeleteVideo(item) }
            }
        }
    }

    private func linkPanel(_ item: HistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            iconHeader(
                systemName: "play.rectangle.fill",
                tint: LibraryTimelineProviderTint.color(for: item.provider),
                title: item.title,
                subtitle: LibraryTimelineProviderTint.displayName(for: item.provider)
            )

            metadataRows {
                LibraryDetailMetadataRow(label: "Source", value: item.url, systemName: "link")
                LibraryDetailMetadataRow(label: "Recorded", value: item.recordedAt.formatted(date: .abbreviated, time: .shortened), systemName: "clock")
                LibraryDetailMetadataRow(label: "Domain", value: LibraryDisplay.domain(for: item.url), systemName: "network")
            }

            actionGroup {
                LibraryDetailActionButton(title: "Extract Again", systemName: "arrow.clockwise", tint: Theme.lavender) { extractAgain(item) }
                LibraryDetailActionButton(title: "Open Link", systemName: "safari", tint: Theme.skyBlue) { openURL(item.url) }
                LibraryDetailActionButton(title: "Copy Link", systemName: "doc.on.doc", tint: Theme.textSecondary) { ClipboardManager.copy(item.url) }
                LibraryDetailActionButton(title: "Remove", systemName: "trash", tint: Theme.error, role: .destructive) { removeLink(item) }
            }
        }
    }

    private func uploadPanel(_ item: CompletedUploadItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            iconHeader(
                systemName: "checkmark.icloud.fill",
                tint: LibraryTimelineDestinationFormatter.color(for: item.destination),
                title: item.title,
                subtitle: LibraryTimelineDestinationFormatter.displayName(for: item.destination)
            )

            metadataRows {
                LibraryDetailMetadataRow(label: "Remote Path", value: item.remotePath, systemName: "externaldrive.fill")
                LibraryDetailMetadataRow(label: "Source", value: item.url, systemName: "link")
                LibraryDetailMetadataRow(label: "Completed", value: item.completedAt.formatted(date: .abbreviated, time: .shortened), systemName: "clock.badge.checkmark")
                LibraryDetailMetadataRow(label: "Provider", value: LibraryTimelineProviderTint.displayName(for: item.provider), systemName: "network")
            }

            actionGroup {
                LibraryDetailActionButton(title: "Copy Remote Path", systemName: "arrow.up.right.square", tint: Theme.success) { ClipboardManager.copy(item.remotePath) }
                LibraryDetailActionButton(title: "Copy Source Link", systemName: "doc.on.doc", tint: Theme.textSecondary) { ClipboardManager.copy(item.url) }
                LibraryDetailActionButton(title: "Open Source", systemName: "safari", tint: Theme.skyBlue) { openURL(item.url) }
                LibraryDetailActionButton(title: "Remove", systemName: "trash", tint: Theme.error, role: .destructive) { removeUpload(item) }
            }
        }
    }

    private func favoritePanel(_ item: FeedFavoriteItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            iconHeader(
                systemName: "heart.fill",
                tint: Theme.hotPink,
                title: item.title,
                subtitle: item.siteName
            )

            metadataRows {
                LibraryDetailMetadataRow(label: "Source", value: item.url, systemName: "link")
                LibraryDetailMetadataRow(label: "Saved", value: item.favoritedAt.formatted(date: .abbreviated, time: .shortened), systemName: "heart")
                LibraryDetailMetadataRow(label: "Feed", value: item.siteName, systemName: "network")
            }

            actionGroup {
                LibraryDetailActionButton(title: "Extract", systemName: "arrow.clockwise", tint: Theme.lavender) { extractFavorite(item) }
                LibraryDetailActionButton(title: "Open Source", systemName: "safari", tint: Theme.skyBlue) { openURL(item.url) }
                LibraryDetailActionButton(title: "Copy Link", systemName: "doc.on.doc", tint: Theme.textSecondary) { ClipboardManager.copy(item.url) }
                LibraryDetailActionButton(title: "Remove Favorite", systemName: "heart.slash", tint: Theme.error, role: .destructive) { removeFavorite(item) }
            }
        }
    }

    private func favoriteButton(for item: LibraryItem) -> some View {
        Button {
            toggleFavoriteVideo(item)
        } label: {
            Image(systemName: favoritesStore.contains(url: item.url) ? "heart.fill" : "heart")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.hotPink)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.28), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func pipelineSection(for rawURL: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pipeline")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(LibraryPipelineDestination.allCases) { destination in
                    let stage = pipelineStore.stage(for: rawURL, destination: destination)
                    LibraryPipelineRow(destination: destination, stage: stage)
                }
            }
            .padding(10)
            .background(Theme.surface0.opacity(0.34), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.skyBlue.opacity(0.12), lineWidth: 0.5))
        }
    }

    private func titleBlock(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func iconHeader(systemName: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface2.opacity(0.9))
                .frame(width: 52, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(tint.opacity(0.34), lineWidth: 1)
                )
                .overlay(
                    Image(systemName: systemName)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(tint)
                )

            titleBlock(title: title, subtitle: subtitle)
        }
    }

    private func metadataRows<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(10)
        .background(Theme.surface0.opacity(0.34), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.skyBlue.opacity(0.12), lineWidth: 0.5))
    }

    private func actionGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}

private struct LibraryDetailMetadataRow: View {
    let label: String
    let value: String
    let systemName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 15)

            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 76, alignment: .leading)
                .lineLimit(1)

            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
    }
}

private struct LibraryDetailActionButton: View {
    let title: String
    let systemName: String
    let tint: Color
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            LibraryDetailActionLabel(title: title, systemName: systemName, tint: tint)
        }
        .buttonStyle(.plain)
    }
}

private struct LibraryDetailMenuButton<Content: View>: View {
    let title: String
    let systemName: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            LibraryDetailActionLabel(title: title, systemName: systemName, tint: tint)
        }
        .menuStyle(.borderlessButton)
    }
}

private struct LibraryDetailActionLabel: View {
    let title: String
    let systemName: String
    let tint: Color

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        } icon: {
            Image(systemName: systemName)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.2), lineWidth: 0.5))
    }
}

private struct LibraryTimelineIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct LibraryTimelineMenuLabel: View {
    let systemName: String
    let help: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .help(help)
    }
}

private struct LibraryTimelineHeart: View {
    let isFilled: Bool
    let tint: Color

    var body: some View {
        Image(systemName: isFilled ? "heart.fill" : "heart")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 14, height: 14)
    }
}

private struct LibraryTimelineProviderPill: View {
    let provider: String

    var body: some View {
        Text(LibraryTimelineProviderTint.displayName(for: provider))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(LibraryTimelineProviderTint.color(for: provider).opacity(0.85), in: Capsule())
    }
}

private struct LibraryTimelineDestinationChip: View {
    let destination: String

    var body: some View {
        Text(LibraryTimelineDestinationFormatter.shortName(for: destination))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(LibraryTimelineDestinationFormatter.color(for: destination).opacity(0.86), in: Capsule())
    }
}

struct LibraryPipelineBadgeModel {
    let id: String
    let title: String
    let tint: Color
}

private struct LibraryPipelineBadge: View {
    let badge: LibraryPipelineBadgeModel

    var body: some View {
        Text(badge.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(badge.tint)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badge.tint.opacity(0.18), in: Capsule())
    }
}

private struct LibraryPipelineRow: View {
    let destination: LibraryPipelineDestination
    let stage: LibraryPipelineStage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(destination.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 56, alignment: .leading)

                Text(statusTitle)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(statusTint)
            }

            if let detailText {
                Text(detailText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusTitle: String {
        switch stage {
        case .notStarted: return "Not started"
        case .running: return "Running"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        }
    }

    private var statusTint: Color {
        switch stage {
        case .notStarted: return Theme.textSecondary
        case .running: return Theme.skyBlue
        case .succeeded: return Theme.success
        case .failed: return Theme.error
        }
    }

    private var detailText: String? {
        switch stage {
        case .notStarted, .running:
            return nil
        case .succeeded(let path, let date):
            return "\(path) · \(date.formatted(date: .abbreviated, time: .shortened))"
        case .failed(let message, let date):
            return "\(message) · \(date.formatted(date: .abbreviated, time: .shortened))"
        }
    }
}

private struct LibraryThumbnailPlaceholder: View {
    let item: LibraryItem
    let isLoading: Bool
    let didFail: Bool
    let retryAction: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [placeholderColor.opacity(0.9), placeholderColor.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Text(initials)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white.opacity(0.82))
            }

            if didFail {
                Button(action: retryAction) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.32), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(7)
            }
        }
    }

    private var initials: String {
        let words = LibraryDisplay.title(for: item)
            .split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" })
            .prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "V" : letters.uppercased()
    }

    private var placeholderColor: Color {
        let palette: [Color] = [
            Theme.gold, Theme.coral, Theme.taoRed, Theme.skyBlue,
            Theme.lavender, Theme.hotPink, Theme.electricLime,
            Theme.success, Theme.warning, Theme.accent,
            Theme.meshCoral, Theme.meshIndigo
        ]
        let seed = item.url.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(seed) % palette.count]
    }
}

private struct LibraryKindBadge: View {
    let kind: LibrarySourceKind

    var body: some View {
        Text(kind.label)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(kind.tint.opacity(0.85), in: Capsule())
    }
}

private struct LibrarySelectionBar: View {
    let count: Int
    let deleteAction: () -> Void
    let uploadMegaAction: () -> Void
    let uploadDriveAction: () -> Void
    let clearAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(count) selected")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            LibrarySelectionButton(title: "Upload to Mega", systemName: "cloud.fill", tint: Theme.success, action: uploadMegaAction)
            LibrarySelectionButton(title: "Upload to Drive", systemName: "externaldrive.fill", tint: Theme.skyBlue, action: uploadDriveAction)
            LibrarySelectionButton(title: "Delete", systemName: "trash", tint: Theme.error, action: deleteAction)
            LibrarySelectionButton(title: "Clear", systemName: "xmark.circle", tint: Theme.textSecondary, action: clearAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(tint: Theme.skyBlue.opacity(0.18), cornerRadius: 14)
    }
}

private struct LibrarySelectionButton: View {
    let title: String
    let systemName: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
        }
        .buttonStyle(.borderless)
    }
}

private struct LibraryEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "books.vertical")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(Theme.gold.opacity(0.5))
                .padding()
            Text("No library activity yet")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text("Extract or download a video to add it here")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary.opacity(0.65))
        }
    }
}

private struct LibraryNoResultsState: View {
    let searchText: String
    let filter: LibraryTimelineFilter
    let clearAction: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .foregroundStyle(Theme.gold.opacity(0.5))
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: clearAction) {
                Label("Clear filters", systemImage: "xmark.circle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.gold, Theme.skyBlue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.accentDim, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.skyBlue.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    private var message: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty, filter == .all {
            return "No matching library activity"
        }
        var parts: [String] = []
        if !query.isEmpty { parts.append("\"\(query)\"") }
        if filter != .all { parts.append("in \(filter.title)") }
        return "No matches for \(parts.joined(separator: " "))"
    }
}
