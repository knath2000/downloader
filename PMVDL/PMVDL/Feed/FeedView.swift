import AppKit
import SwiftUI

private enum FeedLayout {
    static let contentMaxWidth: CGFloat = 1760
    static let outerSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 10
    static let toolbarCornerRadius: CGFloat = 14
    static let gridBottomPadding: CGFloat = 18
    static let scrollCoordinateSpace = "FeedScrollView"
}

private struct FeedScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct FeedGridLayout: Equatable {
    let availableWidth: CGFloat

    var columnMinWidth: CGFloat {
        switch availableWidth {
        case ..<980: return 260
        case ..<1350: return 285
        case ..<1700: return 305
        default: return 320
        }
    }

    var spacing: CGFloat {
        availableWidth < 980 ? 12 : 16
    }

    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: columnMinWidth), spacing: spacing)]
    }

    var estimatedColumnCount: Int {
        max(1, Int((availableWidth + spacing) / (columnMinWidth + spacing)))
    }

    var prefetchItemThreshold: Int {
        max(estimatedColumnCount * 4, 8)
    }
}

struct DownloadedFeedMatch: Hashable, Identifiable {
    let libraryID: UUID
    let title: String
    let url: String
    let downloadedAt: Date

    var id: UUID { libraryID }

    var tooltip: String {
        "Downloaded as \(title) on \(downloadedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct DownloadedFeedIndex: Equatable {
    private let urlMatches: [String: DownloadedFeedMatch]
    private let pornHubViewkeyMatches: [String: DownloadedFeedMatch]

    init(items: [LibraryItem]) {
        var urlMatches: [String: DownloadedFeedMatch] = [:]
        var pornHubViewkeyMatches: [String: DownloadedFeedMatch] = [:]

        for item in items {
            let match = DownloadedFeedMatch(
                libraryID: item.id,
                title: LibraryDisplayTitle.title(for: item),
                url: item.url,
                downloadedAt: item.extractedAt
            )
            let normalized = Self.normalizedURL(item.url)
            if !normalized.isEmpty, urlMatches[normalized] == nil {
                urlMatches[normalized] = match
            }
            if let viewkey = Self.pornHubViewkey(item.url),
               pornHubViewkeyMatches[viewkey] == nil {
                pornHubViewkeyMatches[viewkey] = match
            }
        }

        self.urlMatches = urlMatches
        self.pornHubViewkeyMatches = pornHubViewkeyMatches
    }

    func match(for item: FeedItem) -> DownloadedFeedMatch? {
        if let viewkey = Self.pornHubViewkey(item.url),
           let match = pornHubViewkeyMatches[viewkey] {
            return match
        }
        return urlMatches[Self.normalizedURL(item.url)]
    }

    static func normalizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed) else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? trimmed
    }

    static func pornHubViewkey(_ raw: String) -> String? {
        let lower = raw.lowercased()
        guard lower.contains("pornhub.com") else { return nil }
        guard let components = URLComponents(string: raw),
              let value = components.queryItems?.first(where: { $0.name.caseInsensitiveCompare("viewkey") == .orderedSame })?.value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum FeedSelectionStore {
    static func key(for item: FeedItem) -> String {
        DownloadedFeedIndex.normalizedURL(item.url).lowercased()
    }

    static func toggled(_ item: FeedItem, in selectedItems: [String: FeedItem]) -> [String: FeedItem] {
        var next = selectedItems
        let key = key(for: item)
        if next[key] == nil {
            next[key] = item
        } else {
            next.removeValue(forKey: key)
        }
        return next
    }

    static func adding(_ items: [FeedItem], to selectedItems: [String: FeedItem]) -> [String: FeedItem] {
        var next = selectedItems
        for item in items {
            next[key(for: item)] = item
        }
        return next
    }
}

private enum LibraryDisplayTitle {
    static func title(for item: LibraryItem) -> String {
        let stripped = item.title.replacingOccurrences(
            of: #"_[0-9A-Fa-f][0-9A-Fa-f_-]{10,}.*$"#,
            with: "",
            options: .regularExpression
        )
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? item.url : trimmed
    }
}

struct FeedView: View {
    @StateObject private var model = FeedViewModel.shared
    @StateObject private var favorites = FeedFavoritesStore.shared
    @StateObject private var library = VideoLibrary.shared
    @StateObject private var pornHubSession = PornHubSessionManager.shared
    @StateObject private var epornerSession = EpornerSessionManager.shared
    @StateObject private var feedBrowser = PornHubBrowserViewModel()
    @State private var showsAdvancedFilters = false
    @State private var selectedItems: [String: FeedItem] = [:]
    @State private var isScrollingFeed = false
    @State private var scrollIdleTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSelecting: Bool { !selectedItems.isEmpty }
    private var capabilities: FeedSiteCapabilities {
        FeedSiteCapabilities.capabilities(for: model.selectedSite)
    }
    private var siteTheme: FeedSiteTheme {
        FeedSiteTheme.theme(for: model.selectedSite)
    }
    private var isBrowserBackedFeed: Bool {
        FeedBrowserSite(host: model.selectedSite) != nil
    }

    private var sortModeBinding: Binding<FeedSortMode> {
        Binding {
            model.sortMode
        } set: { value in
            model.discardPornHubReturnState()
            model.discardEpornerReturnState()
            model.sortMode = value
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = min(
                max(proxy.size.width - FeedLayout.outerSpacing * 2, 0),
                FeedLayout.contentMaxWidth
            )

            VStack(spacing: FeedLayout.outerSpacing) {
                if !isBrowserBackedFeed {
                    FeedPageHeader(
                        selectedSite: model.selectedSite,
                        visibleCount: model.filteredItems.count,
                        totalCount: model.items.count,
                        isLoading: model.isLoading,
                        theme: siteTheme,
                        refreshAction: { Task { await model.refresh() } }
                    )

                    FeedToolbar(
                        selectedSite: $model.selectedSite,
                        filters: $model.filters,
                        sortMode: sortModeBinding,
                        showsAdvancedFilters: $showsAdvancedFilters,
                        capabilities: capabilities,
                        theme: siteTheme,
                        availableStudios: model.availableStudios,
                        availableCategories: model.availableCategories,
                        availableTags: model.availableTags,
                        availableQualityLabels: model.availableQualityLabels,
                        activeChips: model.filters.activeChips,
                        removeActiveFilter: removeActiveFilter,
                        clearFilters: model.clearFilters
                    )
                }

                if let error = model.error, !model.items.isEmpty {
                    FeedInlineErrorBanner(message: error, accent: siteTheme.accent) {
                        Task { await model.refresh() }
                    }
                }

                contentArea(availableWidth: availableWidth)

                if isSelecting {
                    batchSelectionBar
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: FeedLayout.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, FeedLayout.outerSpacing)
            .padding(.top, 10)
            .background(siteTheme.backgroundTint.opacity(0.18).ignoresSafeArea())
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82), value: isSelecting)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.selectedSite)
        }
        .task {
            await model.loadInitial()
            await model.loadPornHubSubscriptionsIfNeeded()
            await model.loadEpornerSubscriptionsIfNeeded()
        }
        .onChange(of: model.filters.date) { _, _ in
            model.resetPaginationForFilter()
        }
        .onChange(of: model.filters) { _, _ in
            model.discardPornHubReturnState()
            model.discardEpornerReturnState()
        }
        .onChange(of: model.selectedSite) { _, newSite in
            applySiteCapabilities(for: newSite)
            if newSite != PornHubFeedScraper.supportedHost {
                model.clearPornHubContext()
            } else {
                feedBrowser.configure(site: .pornHub)
                feedBrowser.loadHome(feedModel: model)
                Task { await model.loadPornHubSubscriptionsIfNeeded() }
            }
            if let browserSite = FeedBrowserSite(host: newSite), newSite != PornHubFeedScraper.supportedHost {
                feedBrowser.configure(site: browserSite)
                feedBrowser.loadHome(feedModel: model)
            }
            if newSite != EpornerFeedScraper.supportedHost {
                model.clearEpornerContext()
            } else {
                Task { await model.loadEpornerSubscriptionsIfNeeded() }
            }
            Task { await model.refresh() }
        }
        .onChange(of: model.selectedPornHubSection) { _, _ in
            if model.selectedSite == PornHubFeedScraper.supportedHost {
                feedBrowser.loadHome(feedModel: model)
            }
        }
        .onChange(of: model.pornHubUploaderURL) { _, _ in
            if model.selectedSite == PornHubFeedScraper.supportedHost {
                feedBrowser.loadHome(feedModel: model)
            }
        }
        .onChange(of: model.selectedEpornerSection) { _, _ in
            if model.selectedSite == EpornerFeedScraper.supportedHost {
                feedBrowser.loadHome(feedModel: model)
            }
        }
        .onChange(of: pornHubSession.isLoggedIn) { _, isLoggedIn in
            if isLoggedIn && model.selectedSite == PornHubFeedScraper.supportedHost {
                Task { await model.loadPornHubSubscriptionsIfNeeded() }
            } else if !isLoggedIn {
                model.pornHubSubscriptions = []
                model.pornHubSubscriptionsError = nil
            }
        }
        .onChange(of: epornerSession.isLoggedIn) { _, isLoggedIn in
            if isLoggedIn && model.selectedSite == EpornerFeedScraper.supportedHost {
                Task { await model.loadEpornerSubscriptionsIfNeeded() }
            } else if !isLoggedIn {
                model.epornerSubscriptions = []
                model.epornerSubscriptionsError = nil
            }
        }
    }

    @ViewBuilder
    private func contentArea(availableWidth: CGFloat) -> some View {
        if FeedBrowserSite(host: model.selectedSite) != nil {
            feedBrowserArea(availableWidth: availableWidth)
        } else {
            let railWidth = min(max(availableWidth * 0.18, 190), 240)
            if shouldShowSubscriptionRail(availableWidth: availableWidth) {
                HStack(alignment: .top, spacing: 12) {
                    if model.selectedSite == PornHubFeedScraper.supportedHost {
                        PornHubSubscriptionRail(
                            model: model,
                            accent: siteTheme.accent
                        )
                        .frame(width: railWidth)
                        .frame(maxHeight: .infinity)
                    } else if model.selectedSite == EpornerFeedScraper.supportedHost {
                        EpornerSubscriptionRail(
                            model: model,
                            accent: siteTheme.accent
                        )
                        .frame(width: railWidth)
                        .frame(maxHeight: .infinity)
                    }

                    content(availableWidth: max(availableWidth - railWidth - 12, 0))
                }
            } else {
                content(availableWidth: availableWidth)
            }
        }
    }

    private func feedBrowserArea(availableWidth: CGFloat) -> some View {
        VStack(spacing: FeedLayout.sectionSpacing) {
            let currentItem = feedBrowser.currentFeedItem
            let downloadedIndex = DownloadedFeedIndex(items: library.items)
            let currentDownloadedMatch = currentItem.flatMap { downloadedIndex.match(for: $0) }

            if model.selectedSite == PornHubFeedScraper.supportedHost ||
                model.selectedSite == EpornerFeedScraper.supportedHost {
                inlineSubscriptionPicker
            }

            PornHubBrowserChrome(
                browser: feedBrowser,
                selectedSite: $model.selectedSite,
                accent: siteTheme.accent,
                currentPageIsFavorite: currentItem.map { favorites.contains(url: $0.url) } ?? false,
                currentPageDownloadedMatch: currentDownloadedMatch,
                goHome: { feedBrowser.loadHome(feedModel: model) },
                extractCurrentPage: extractCurrentBrowserPage,
                toggleFavoriteCurrentPage: toggleFavoriteCurrentBrowserPage
            )

            PornHubBrowserWebView(
                browser: feedBrowser,
                initialURL: feedBrowser.homeURL(feedModel: model),
                isSelected: { item in selectedItems[FeedSelectionStore.key(for: item)] != nil },
                toggleSelection: { item in toggleSelection(item) },
                onNavigationFinished: {
                    Task { @MainActor in
                        if model.selectedSite == PornHubFeedScraper.supportedHost {
                            await PornHubSessionManager.shared.syncFromWebView()
                        } else if model.selectedSite == EpornerFeedScraper.supportedHost {
                            await EpornerSessionManager.shared.syncFromWebView()
                        }
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(siteTheme.accent.opacity(0.18), lineWidth: 0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let browserSite = FeedBrowserSite(host: model.selectedSite) {
                feedBrowser.configure(site: browserSite)
            }
            if feedBrowser.currentURL == nil {
                feedBrowser.loadHome(feedModel: model)
            }
        }
    }

    private func shouldShowSubscriptionRail(availableWidth: CGFloat) -> Bool {
        let isPH = model.selectedSite == PornHubFeedScraper.supportedHost &&
            pornHubSession.isLoggedIn
        let isEP = model.selectedSite == EpornerFeedScraper.supportedHost &&
            epornerSession.isLoggedIn
        return (isPH || isEP) &&
            availableWidth >= 1040
    }

    @ViewBuilder
    private func content(availableWidth: CGFloat) -> some View {
        if let error = model.error, model.items.isEmpty {
            FeedErrorState(message: error, accent: siteTheme.accent) {
                Task { await model.refresh() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isLoading && model.items.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FeedLayout.sectionSpacing) {
                    inlineSubscriptionPicker
                    FeedSkeletonGrid(layout: FeedGridLayout(availableWidth: availableWidth), accent: siteTheme.accent)
                }
                .padding(.bottom, FeedLayout.gridBottomPadding)
            }
        } else if model.filteredItems.isEmpty {
            VStack(alignment: .leading, spacing: FeedLayout.sectionSpacing) {
                inlineSubscriptionPicker
                FeedEmptyState(
                    filters: model.filters,
                    accent: siteTheme.accent,
                    clearFilters: model.clearFilters,
                    refresh: { Task { await model.refresh() } }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                FeedAutoLoadSentinel(
                    hasMore: model.hasMore,
                    isLoading: model.isLoading,
                    currentPage: model.currentPage,
                    visibleCount: model.filteredItems.count,
                    action: { Task { await model.loadMoreMatchingCurrentFilters(pageBudget: 3) } }
                )
                .frame(width: 0, height: 0)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    let layout = FeedGridLayout(availableWidth: availableWidth)
                    let downloadedIndex = DownloadedFeedIndex(items: library.items)
                    let favoriteIDs = Set(favorites.items.map(\.id))
                    let prefetchThreshold = layout.prefetchItemThreshold
                    LazyVStack(alignment: .leading, spacing: FeedLayout.sectionSpacing, pinnedViews: [.sectionHeaders]) {
                        scrollOffsetTracker
                        inlineSubscriptionPicker

                        if capabilities.groupsByDate {
                            ForEach(model.dayBuckets) { bucket in
                                Section {
                                    feedGrid(
                                        items: bucket.items,
                                        layout: layout,
                                        downloadedIndex: downloadedIndex,
                                        favoriteIDs: favoriteIDs,
                                        prefetchThreshold: prefetchThreshold
                                    )
                                } header: {
                                    FeedDayHeader(date: bucket.date, count: bucket.items.count, accent: siteTheme.accent)
                                }
                            }
                        } else {
                            feedGrid(
                                items: model.filteredItems,
                                layout: layout,
                                downloadedIndex: downloadedIndex,
                                favoriteIDs: favoriteIDs,
                                prefetchThreshold: prefetchThreshold
                            )
                        }

                        autoLoadMoreRow
                    }
                    .padding(.bottom, FeedLayout.gridBottomPadding)
                }
                .coordinateSpace(name: FeedLayout.scrollCoordinateSpace)
                .onPreferenceChange(FeedScrollOffsetPreferenceKey.self, perform: updateScrollActivity)
                .onAppear {
                    restorePendingScrollIfNeeded(proxy, anchorID: model.pendingScrollRestoreID)
                }
                .onChange(of: model.pendingScrollRestoreID) { _, anchorID in
                    restorePendingScrollIfNeeded(proxy, anchorID: anchorID)
                }
                .onDisappear {
                    scrollIdleTask?.cancel()
                    scrollIdleTask = nil
                    isScrollingFeed = false
                }
            }
        }
    }

    private var scrollOffsetTracker: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: FeedScrollOffsetPreferenceKey.self,
                value: proxy.frame(in: .named(FeedLayout.scrollCoordinateSpace)).minY
            )
        }
        .frame(height: 0)
    }

    @ViewBuilder
    private var inlineSubscriptionPicker: some View {
        if shouldShowInlineSubscriptionPicker {
            if model.selectedSite == EpornerFeedScraper.supportedHost {
                EpornerSubscriptionsInlinePicker(model: model, accent: siteTheme.accent)
            } else {
                PornHubSubscriptionsInlinePicker(model: model, accent: siteTheme.accent)
            }
        }
    }

    private var shouldShowInlineSubscriptionPicker: Bool {
        (model.selectedSite == PornHubFeedScraper.supportedHost &&
            pornHubSession.isLoggedIn &&
            model.selectedPornHubSection == .subscriptions &&
            model.pornHubUploaderURL == nil) ||
            (model.selectedSite == EpornerFeedScraper.supportedHost &&
            epornerSession.isLoggedIn &&
            model.selectedEpornerSection == .subscriptions &&
            model.epornerUploaderURL == nil)
    }

    private var batchSelectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selectedItems.count) selected")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Button("Clear") {
                selectedItems = [:]
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                extractSelected()
            } label: {
                Label("Extract Selected", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(siteTheme.accent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassCard(tint: siteTheme.accent.opacity(0.14), cornerRadius: 14)
    }

    private func feedGrid(
        items: [FeedItem],
        layout: FeedGridLayout,
        downloadedIndex: DownloadedFeedIndex,
        favoriteIDs: Set<String>,
        prefetchThreshold: Int
    ) -> some View {
        return LazyVGrid(
            columns: layout.columns,
            alignment: .leading,
            spacing: layout.spacing
        ) {
            ForEach(items) { item in
                let downloadedMatch = downloadedIndex.match(for: item)
                FeedCardView(
                    item: item,
                    isFavorite: favoriteIDs.contains(FeedFavoriteItem.normalizedURL(item.url)),
                    downloadedMatch: downloadedMatch,
                    isScrolling: isScrollingFeed,
                    toggleFavorite: {
                        withAnimation {
                            favorites.toggle(feedItem: item)
                        }
                    },
                    extract: {
                        if isSelecting {
                            toggleSelection(item)
                        } else {
                            extract(item)
                        }
                    }
                )
                .id(item.id)
                .onAppear {
                    model.recordVisibleFeedAnchor(item.id)
                    Task {
                        await model.prefetchMoreIfNeeded(
                            appearedItemID: item.id,
                            threshold: prefetchThreshold
                        )
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        selectionBadge(for: item)
                    }
                }
                .contextMenu {
                    cardContextMenu(for: item, downloadedMatch: downloadedMatch)
                }
            }
        }
    }

    private func selectionBadge(for item: FeedItem) -> some View {
        let isSelected = selectedItems[FeedSelectionStore.key(for: item)] != nil
        return Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(isSelected ? siteTheme.accent : .white.opacity(0.7))
            .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
            .padding(10)
    }

    @ViewBuilder
    private func cardContextMenu(for item: FeedItem, downloadedMatch: DownloadedFeedMatch?) -> some View {
        let isSelected = selectedItems[FeedSelectionStore.key(for: item)] != nil
        Button(isSelected ? "Deselect" : "Select") {
            toggleSelection(item)
        }
        Button("Select All Visible") {
            selectedItems = FeedSelectionStore.adding(model.filteredItems, to: selectedItems)
        }
        if isSelecting {
            Divider()
            Button("Extract Selected (\(selectedItems.count))") {
                extractSelected()
            }
            Button("Clear Selection") {
                selectedItems = [:]
            }
        }
        Divider()
        Button("Extract") { extract(item) }
        if let downloadedMatch {
            Button("Open in Library") { openInLibrary(downloadedMatch) }
        }
        Button(favorites.contains(url: item.url) ? "Remove from Favorites" : "Add to Favorites") {
            withAnimation {
                favorites.toggle(feedItem: item)
            }
        }
        Divider()
        Button("Copy Link") { ClipboardManager.copy(item.url) }
        Button("Open in Browser") { openInBrowser(item) }
    }

    private var autoLoadMoreRow: some View {
        HStack {
            Spacer()
            if model.hasMore {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text(model.isLoading ? "Loading more videos" : "More videos available")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                Text("No more videos for this filter")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.top, 2)
        .background(
            FeedAutoLoadSentinel(
                hasMore: model.hasMore,
                isLoading: model.isLoading,
                currentPage: model.currentPage,
                visibleCount: model.filteredItems.count,
                action: { Task { await model.loadMoreMatchingCurrentFilters(pageBudget: 3) } }
            )
        )
    }

    private func removeActiveFilter(id: String) {
        model.filters.removeActiveChip(id: id)
        model.resetPaginationForFilter()
    }

    private func extract(_ item: FeedItem) {
        AppStateManager.shared.pendingExtractThumbnailURL = item.thumbnailURL
        AppStateManager.shared.pendingExtractShouldStart = true
        AppStateManager.shared.pendingExtractURL = item.url
        AppStateManager.shared.select(.home)
    }

    private func extractCurrentBrowserPage() {
        guard let item = feedBrowser.currentFeedItem else { return }
        extract(item)
    }

    private func toggleFavoriteCurrentBrowserPage() {
        guard let item = feedBrowser.currentFeedItem else { return }
        withAnimation {
            favorites.toggle(feedItem: item)
        }
    }

    private func toggleSelection(_ item: FeedItem) {
        selectedItems = FeedSelectionStore.toggled(item, in: selectedItems)
    }

    private func extractSelected() {
        let selected = Array(selectedItems.values)
        guard !selected.isEmpty else { return }

        AppStateManager.shared.pendingExtractThumbnailURL = nil
        AppStateManager.shared.pendingExtractShouldStart = true
        AppStateManager.shared.pendingExtractURL = selected.map(\.url).joined(separator: "\n")
        selectedItems = [:]
        AppStateManager.shared.select(.home)
    }

    private func openInBrowser(_ item: FeedItem) {
        guard let url = URL(string: item.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openInLibrary(_ match: DownloadedFeedMatch) {
        AppStateManager.shared.pendingLibraryItemID = match.libraryID
        AppStateManager.shared.select(.library)
    }

    private func applySiteCapabilities(for site: String) {
        let caps = FeedSiteCapabilities.capabilities(for: site)
        if site == PornHubFeedScraper.supportedHost {
            model.applyPornHubDefaultSortForCurrentContext()
        }
        if !caps.availableSortModes.contains(model.sortMode) {
            model.sortMode = caps.availableSortModes.first ?? .titleAZ
        }
        if !caps.hasRealDates && model.filters.date != .all {
            model.filters.date = .all
        }
        if !caps.hasViewCounts {
            model.filters.minViews = nil
        }
        if !caps.hasDuration {
            model.filters.minDurationSeconds = nil
            model.filters.maxDurationSeconds = nil
        }
        if !caps.hasStudios {
            model.filters.selectedStudios = []
        }
        if !caps.hasQualityLabels {
            model.filters.selectedQualityLabels = []
        }
    }

    private func updateScrollActivity(_ offset: CGFloat) {
        scrollIdleTask?.cancel()
        if !isScrollingFeed {
            isScrollingFeed = true
        }
        scrollIdleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            isScrollingFeed = false
        }
    }

    private func restorePendingScrollIfNeeded(_ proxy: ScrollViewProxy, anchorID: String?) {
        guard let anchorID else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(anchorID, anchor: .top)
            model.clearPendingScrollRestoreID(anchorID)
        }
    }
}

private struct FeedAutoLoadSentinel: View {
    let hasMore: Bool
    let isLoading: Bool
    let currentPage: Int
    let visibleCount: Int
    let action: () -> Void

    @State private var lastTriggeredToken: String?

    private var token: String {
        "\(currentPage)-\(visibleCount)-\(hasMore)"
    }

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear(perform: triggerIfNeeded)
            .onChange(of: token) { _, _ in
                triggerIfNeeded()
            }
            .onChange(of: isLoading) { _, loading in
                guard !loading else { return }
                triggerIfNeeded()
            }
    }

    private func triggerIfNeeded() {
        guard hasMore, !isLoading, lastTriggeredToken != token else { return }
        lastTriggeredToken = token
        action()
    }
}

private struct FeedPageHeader: View {
    let selectedSite: String
    let visibleCount: Int
    let totalCount: Int
    let isLoading: Bool
    let theme: FeedSiteTheme
    let refreshAction: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(theme.accent)
                .frame(width: 4, height: 36)

            Image(systemName: theme.icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.accent)
                .frame(width: 34, height: 34)
                .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.accent.opacity(0.24), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 3) {
                logo
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            FeedCountBadge(count: visibleCount, total: totalCount, accent: theme.accent)

            Button(action: refreshAction) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent)
            .controlSize(.small)
            .disabled(isLoading)
            .keyboardShortcut("r", modifiers: [.command])
            .help("Refresh feed")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCard(tint: theme.accent.opacity(0.10), cornerRadius: FeedLayout.toolbarCornerRadius)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: selectedSite)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Feed, \(subtitle)"))
    }

    @ViewBuilder
    private var logo: some View {
        if let logoText = theme.logoText {
            HStack(spacing: 0) {
                Text(logoText.prefix)
                    .font(.system(.title3, design: .default).weight(.heavy))
                    .foregroundStyle(theme.accent)
                Text(logoText.suffix)
                    .font(.system(.title3, design: .default).weight(.heavy))
                    .foregroundStyle(Theme.textPrimary)
            }
        } else {
            Text(theme.displayName)
                .font(.system(.title3, design: .rounded).weight(.black))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var subtitle: String {
        let countText = totalCount == visibleCount ? "\(totalCount) loaded" : "\(visibleCount) visible of \(totalCount) loaded"
        return "\(theme.displayName) - \(countText)"
    }
}

private struct FeedToolbar: View {
    @Binding var selectedSite: String
    @Binding var filters: FeedFilterState
    @Binding var sortMode: FeedSortMode
    @Binding var showsAdvancedFilters: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let capabilities: FeedSiteCapabilities
    let theme: FeedSiteTheme
    let availableStudios: [String]
    let availableCategories: [String]
    let availableTags: [String]
    let availableQualityLabels: [String]
    let activeChips: [FeedActiveFilterChip]
    let removeActiveFilter: (String) -> Void
    let clearFilters: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 7) {
                ViewThatFits(in: .horizontal) {
                    wideControls
                    compactControls
                }

                if !activeChips.isEmpty {
                    FeedActiveFiltersRow(
                        chips: activeChips,
                        accent: theme.accent,
                        remove: removeActiveFilter,
                        clearAll: clearFilters
                    )
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }

                if showsAdvancedFilters {
                    FeedAdvancedFilterPanel(
                        filters: $filters,
                        capabilities: capabilities,
                        accent: theme.accent,
                        availableStudios: availableStudios,
                        availableCategories: availableCategories,
                        availableTags: availableTags,
                        availableQualityLabels: availableQualityLabels
                    )
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }

            Button("Focus Search") {
                searchFocused = true
            }
            .keyboardShortcut("f", modifiers: [.command])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassCard(tint: theme.accent.opacity(0.10), cornerRadius: 16)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: selectedSite)
        .onExitCommand {
            if searchFocused {
                filters.query = ""
                searchFocused = false
            } else if showsAdvancedFilters {
                showsAdvancedFilters = false
            }
        }
    }

    private var wideControls: some View {
        HStack(spacing: 8) {
            sitePicker
                .layoutPriority(2)
            searchField
                .layoutPriority(5)
            datePicker
            sortPicker
            filterToggle
            clearButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                sitePicker
                datePicker
                sortPicker
                Spacer(minLength: 0)
                filterToggle
                clearButton
            }
            searchField
        }
    }

    private var sitePicker: some View {
        FeedMenuPicker(title: "Site", accent: theme.accent) {
            Picker("Site", selection: $selectedSite) {
                Text(AllPornStreamFeedScraper.supportedHost).tag(AllPornStreamFeedScraper.supportedHost)
                Text(RentryFeedScraper.supportedHost).tag(RentryFeedScraper.supportedHost)
                Text(HQPornerFeedScraper.supportedHost).tag(HQPornerFeedScraper.supportedHost)
                Text(PornHubFeedScraper.supportedHost).tag(PornHubFeedScraper.supportedHost)
                Text(EpornerFeedScraper.supportedHost).tag(EpornerFeedScraper.supportedHost)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 214)
        }
        .accessibilityLabel(Text("Feed source"))
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
            TextField("Search title, studio, tag", text: $filters.query)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
            if !filters.query.isEmpty {
                Button {
                    filters.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 300, idealWidth: 460, maxWidth: .infinity, minHeight: 34, maxHeight: 34)
        .background(theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.accent.opacity(0.20), lineWidth: 0.5))
        .accessibilityLabel(Text("Search feed"))
    }

    @ViewBuilder
    private var datePicker: some View {
        if capabilities.hasRealDates {
            FeedMenuPicker(title: "Date", accent: theme.accent) {
                Picker("Date", selection: $filters.date) {
                    ForEach(FeedDateFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 134)
            }
            .accessibilityLabel(Text("Date filter"))
        }
    }

    private var sortPicker: some View {
        FeedMenuPicker(title: "Sort", accent: theme.accent) {
            Picker("Sort", selection: $sortMode) {
                ForEach(capabilities.availableSortModes) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 174)
        }
        .accessibilityLabel(Text("Sort feed"))
    }

    private var filterToggle: some View {
        Button {
            showsAdvancedFilters.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: showsAdvancedFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                Text(filters.activeCount == 0 ? "Filters" : "Filters \(filters.activeCount)")
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(theme.accent.opacity(showsAdvancedFilters ? 0.20 : 0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.accent.opacity(showsAdvancedFilters ? 0.34 : 0.20), lineWidth: 0.5))
        .help("Show advanced feed filters")
        .accessibilityLabel(Text(showsAdvancedFilters ? "Hide advanced filters" : "Show advanced filters"))
    }

    @ViewBuilder
    private var clearButton: some View {
        if !filters.isDefault {
            Button("Clear", action: clearFilters)
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.accent.opacity(0.20), lineWidth: 0.5))
                .help("Clear feed filters")
        }
    }
}

private struct FeedActiveFiltersRow: View {
    let chips: [FeedActiveFilterChip]
    let accent: Color
    let remove: (String) -> Void
    let clearAll: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Text("Active")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)

                ForEach(chips) { chip in
                    Button {
                        remove(chip.id)
                    } label: {
                        HStack(spacing: 5) {
                            Text(chip.title)
                                .lineLimit(1)
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .heavy))
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(accent.opacity(0.16), in: Capsule())
                        .overlay(Capsule().strokeBorder(accent.opacity(0.22), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Remove filter: \(chip.title)"))
                }

                Button("Clear all", action: clearAll)
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct FeedMenuPicker<Content: View>: View {
    let title: String
    let accent: Color
    let content: Content

    init(title: String, accent: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            content
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(accent.opacity(0.20), lineWidth: 0.5))
        .tint(accent)
    }
}

private struct FeedAdvancedFilterPanel: View {
    @Binding var filters: FeedFilterState

    let capabilities: FeedSiteCapabilities
    let accent: Color
    let availableStudios: [String]
    let availableCategories: [String]
    let availableTags: [String]
    let availableQualityLabels: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                Text("Advanced filters")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    metricsSection
                    sourceSection
                    discoverySection
                }
                VStack(alignment: .leading, spacing: 14) {
                    metricsSection
                    sourceSection
                    discoverySection
                }
            }
        }
        .padding(10)
        .background(Theme.surface1.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(accent.opacity(0.16), lineWidth: 0.8))
    }

    @ViewBuilder
    private var metricsSection: some View {
        if capabilities.hasViewCounts || capabilities.hasDuration {
            FeedFilterSection("Metrics", icon: "gauge.with.dots.needle.bottom.50percent") {
                HStack(spacing: 10) {
                    if capabilities.hasViewCounts {
                        FeedMenuPicker(title: "Views", accent: accent) {
                            Picker("Views", selection: minViewsBinding) {
                                Text("Any").tag(0)
                                Text("1K+").tag(1_000)
                                Text("10K+").tag(10_000)
                                Text("100K+").tag(100_000)
                                Text("1M+").tag(1_000_000)
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 92)
                        }
                    }

                    if capabilities.hasDuration {
                        FeedMenuPicker(title: "Duration", accent: accent) {
                            Picker("Duration", selection: durationBinding) {
                                Text("Any").tag("any")
                                Text("< 10m").tag("short")
                                Text("10-30m").tag("medium")
                                Text("30m+").tag("long")
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 96)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        let showQuality = capabilities.hasQualityLabels && !availableQualityLabels.isEmpty
        let showStudios = capabilities.hasStudios && !availableStudios.isEmpty
        if showQuality || showStudios {
            FeedFilterSection("Source metadata", icon: "tag.fill") {
                if showQuality {
                    filterRow(title: "Quality", values: availableQualityLabels, selection: $filters.selectedQualityLabels)
                }
                if showStudios {
                    filterRow(title: "Studio", values: availableStudios, selection: $filters.selectedStudios, limit: 14)
                }
            }
        }
    }

    @ViewBuilder
    private var discoverySection: some View {
        if !availableCategories.isEmpty || !availableTags.isEmpty {
            FeedFilterSection("Discovery", icon: "sparkle.magnifyingglass") {
                filterRow(title: "Category", values: availableCategories, selection: $filters.selectedCategories, limit: 16)
                filterRow(title: "Tags", values: availableTags, selection: $filters.selectedTags, limit: 20)
                if !filters.selectedTags.isEmpty {
                    Toggle("Require all selected tags", isOn: $filters.requireAllTags)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var minViewsBinding: Binding<Int> {
        Binding(
            get: { filters.minViews ?? 0 },
            set: { filters.minViews = $0 == 0 ? nil : $0 }
        )
    }

    private var durationBinding: Binding<String> {
        Binding(
            get: {
                if filters.maxDurationSeconds == 599 { return "short" }
                if filters.minDurationSeconds == 600 && filters.maxDurationSeconds == 1800 { return "medium" }
                if filters.minDurationSeconds == 1800 { return "long" }
                return "any"
            },
            set: { value in
                switch value {
                case "short":
                    filters.minDurationSeconds = nil
                    filters.maxDurationSeconds = 599
                case "medium":
                    filters.minDurationSeconds = 600
                    filters.maxDurationSeconds = 1800
                case "long":
                    filters.minDurationSeconds = 1800
                    filters.maxDurationSeconds = nil
                default:
                    filters.minDurationSeconds = nil
                    filters.maxDurationSeconds = nil
                }
            }
        )
    }

    @ViewBuilder
    private func filterRow(title: String, values: [String], selection: Binding<Set<String>>, limit: Int = 12) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(values.prefix(limit)), id: \.self) { value in
                            FeedFilterChip(
                                title: value,
                                isSelected: selection.wrappedValue.contains(value),
                                accent: accent
                            ) {
                                var next = selection.wrappedValue
                                if next.contains(value) {
                                    next.remove(value)
                                } else {
                                    next.insert(value)
                                }
                                selection.wrappedValue = next
                            }
                        }

                        if values.count > limit {
                            Text("+\(values.count - limit) more")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Theme.surface2.opacity(0.45), in: Capsule())
                        }
                    }
                }
            }
        }
    }
}

private struct FeedFilterSection<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
            content
        }
        .frame(minWidth: 230, alignment: .topLeading)
    }
}

private struct FeedFilterChip: View {
    let title: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? .white : Theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(isSelected ? accent.opacity(0.70) : accent.opacity(0.10), in: Capsule())
                .overlay(Capsule().strokeBorder(accent.opacity(isSelected ? 0.35 : 0.16), lineWidth: 0.5))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}

private struct FeedCountBadge: View {
    let count: Int
    let total: Int
    let accent: Color

    var body: some View {
        Text(total == count ? "\(count)" : "\(count) / \(total)")
            .font(.caption.weight(.bold))
            .foregroundStyle(accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(accent.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
            .accessibilityLabel(Text("\(count) visible out of \(total) loaded videos"))
    }
}

private struct FeedDayHeader: View {
    let date: Date
    let count: Int
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            Label(FeedDisplay.dayLabel(for: date), systemImage: "calendar")
                .font(.caption.weight(.bold))
            Text("\(count) videos")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            Rectangle()
                .fill(accent.opacity(0.18))
                .frame(height: 1)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.vertical, 4)
        .background(Theme.surface0.opacity(0.94))
    }
}

private struct FeedSkeletonGrid: View {
    let layout: FeedGridLayout
    let accent: Color

    var body: some View {
        LazyVGrid(columns: layout.columns, alignment: .leading, spacing: layout.spacing) {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(.white.opacity(0.08))
                        .aspectRatio(16 / 9, contentMode: .fit)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white.opacity(0.08))
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white.opacity(0.05))
                        .frame(width: 120, height: 10)
                }
                .padding(10)
                .glassCard(tint: accent.opacity(0.08), cornerRadius: 16)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel(Text("Loading feed videos"))
    }
}

private struct FeedEmptyState: View {
    let filters: FeedFilterState
    let accent: Color
    let clearFilters: () -> Void
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(accent.opacity(0.62))
            Text(emptyMessage)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(emptyDetail)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 8) {
                if filters.isDefault {
                    Button("Refresh", action: refresh)
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                        .controlSize(.small)
                } else {
                    Button("Clear Filters", action: clearFilters)
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                        .controlSize(.small)
                }
            }
        }
    }

    private var emptyMessage: String {
        if filters.isDefault {
            return "No feed items loaded."
        }
        return "No matches for these filters."
    }

    private var emptyDetail: String {
        if !filters.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No loaded videos match \"\(filters.query)\" in the current source."
        }
        return "Try clearing filters, changing the date range, or refreshing the source."
    }
}

private struct FeedErrorState: View {
    let message: String
    let accent: Color
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.error.opacity(0.72))
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.small)
        }
    }
}

private struct FeedInlineErrorBanner: View {
    let message: String
    let accent: Color
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.error)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .tint(accent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.error.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.error.opacity(0.20), lineWidth: 0.5))
    }
}

private enum FeedSiteDisplay {
    static func name(for site: String) -> String {
        switch site {
        case AllPornStreamFeedScraper.supportedHost:
            return "AllPornStream"
        case RentryFeedScraper.supportedHost:
            return "OnlyFan420"
        case HQPornerFeedScraper.supportedHost:
            return "HQPorner"
        case PornHubFeedScraper.supportedHost:
            return "PornHub"
        case EpornerFeedScraper.supportedHost:
            return "Eporner"
        default:
            return site
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
        }
    }
}

private struct PornHubSubscriptionRail: View {
    @ObservedObject var model: FeedViewModel

    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                Text("Subscriptions")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    Task { await model.refreshPornHubSubscriptions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .disabled(model.isLoadingPornHubSubscriptions)
                .help("Refresh subscriptions")
            }

            allSubscriptionsButton

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if model.isLoadingPornHubSubscriptions {
                        subscriptionLoadingRow
                    } else if model.pornHubSubscriptions.isEmpty {
                        subscriptionEmptyRow
                    } else {
                        ForEach(model.pornHubSubscriptions) { subscription in
                            subscriptionButton(subscription)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .glassCard(tint: accent.opacity(0.08), cornerRadius: 16)
        .task {
            await model.loadPornHubSubscriptionsIfNeeded()
        }
    }

    private var allSubscriptionsButton: some View {
        let isSelected = model.pornHubUploaderURL == nil && model.selectedPornHubSection == .subscriptions
        return Button {
            Task {
                if model.pornHubUploaderURL != nil {
                    await model.pornHubUploaderBack()
                } else {
                    await model.selectPornHubSection(.subscriptions)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("All")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: isSelected ? .bold : .semibold))
            .foregroundStyle(isSelected ? accent : Theme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(isSelected ? accent.opacity(0.18) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var subscriptionLoadingRow: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.62)
            Text("Loading")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    private var subscriptionEmptyRow: some View {
        Text(model.pornHubSubscriptionsError ?? "None found")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(2)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
    }

    private func subscriptionButton(_ subscription: PornHubSubscription) -> some View {
        let isSelected = model.pornHubUploaderURL?.lowercased() == subscription.url.lowercased()
        return Button {
            Task {
                await model.navigateToPornHubUploader(url: subscription.url, name: subscription.name)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(subscription.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: isSelected ? .bold : .regular))
            .foregroundStyle(isSelected ? accent : Theme.textPrimary.opacity(0.84))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(isSelected ? accent.opacity(0.18) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? accent.opacity(0.28) : .white.opacity(0.05), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(subscription.name)
    }
}

private struct PornHubSubscriptionsInlinePicker: View {
    @ObservedObject var model: FeedViewModel

    let accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.isLoadingPornHubSubscriptions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .padding(.horizontal, 8)
                } else if model.pornHubSubscriptions.isEmpty {
                    Text(model.pornHubSubscriptionsError ?? "No subscriptions found")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 2)
                } else {
                    ForEach(model.pornHubSubscriptions) { subscription in
                        Button {
                            Task {
                                await model.navigateToPornHubUploader(url: subscription.url, name: subscription.name)
                            }
                        } label: {
                            Text(subscription.name)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.06), in: Capsule())
                                .overlay(Capsule().strokeBorder(accent.opacity(0.18), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help(subscription.name)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await model.loadPornHubSubscriptionsIfNeeded()
        }
    }
}

private struct PornHubSectionPicker: View {
    @ObservedObject var model: FeedViewModel
    @StateObject private var session = PornHubSessionManager.shared

    let accent: Color

    @ViewBuilder
    var body: some View {
        if let uploaderName = model.pornHubUploaderName {
            HStack(spacing: 10) {
                Button {
                    Task { await model.pornHubUploaderBack() }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)

                Text(uploaderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PornHubSection.allCases) { section in
                        sectionButton(section)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func sectionButton(_ section: PornHubSection) -> some View {
        let isSelected = model.selectedPornHubSection == section
        let needsLogin = section.requiresLogin && !session.isLoggedIn

        return Button {
            Task { await model.selectPornHubSection(section) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: needsLogin ? "lock.fill" : section.icon)
                    .font(.system(size: 11, weight: .bold))
                Text(section.title)
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? accent.opacity(0.22) : Color.white.opacity(0.06), in: Capsule())
            .foregroundStyle(isSelected ? accent : .white.opacity(needsLogin ? 0.50 : 0.65))
            .overlay(Capsule().strokeBorder(isSelected ? accent.opacity(0.32) : .white.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(needsLogin ? "Log in to use \(section.title)" : section.title)
    }
}

private struct PornHubLoginBanner: View {
    @StateObject private var session = PornHubSessionManager.shared
    @State private var showLogin = false

    let refresh: () -> Void

    var body: some View {
        Group {
            if !session.isLoggedIn {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(hex: "#FF9000"))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not logged in to PornHub")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Log in to access Subscriptions, Liked, Favorites and Playlists.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Log In") {
                        showLogin = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "#FF9000"))
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassCard(tint: Color(hex: "#FF9000").opacity(0.12), cornerRadius: 14)
            }
        }
        .sheet(isPresented: $showLogin) {
            PornHubLoginView()
        }
        .onChange(of: session.isLoggedIn) { _, loggedIn in
            if loggedIn {
                refresh()
            }
        }
    }
}

private struct EpornerSectionPicker: View {
    @ObservedObject var model: FeedViewModel
    @StateObject private var session = EpornerSessionManager.shared

    let accent: Color

    @ViewBuilder
    var body: some View {
        if let uploaderName = model.epornerUploaderName {
            HStack(spacing: 10) {
                Button {
                    Task { await model.epornerUploaderBack() }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)

                Text(uploaderName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EpornerSection.allCases) { section in
                        sectionButton(section)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func sectionButton(_ section: EpornerSection) -> some View {
        let isSelected = model.selectedEpornerSection == section
        let needsLogin = section.requiresLogin && !session.isLoggedIn

        return Button {
            Task { await model.selectEpornerSection(section) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: needsLogin ? "lock.fill" : section.icon)
                    .font(.system(size: 11, weight: .bold))
                Text(section.title)
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? accent.opacity(0.22) : Color.white.opacity(0.06), in: Capsule())
            .foregroundStyle(isSelected ? accent : .white.opacity(needsLogin ? 0.50 : 0.65))
            .overlay(Capsule().strokeBorder(isSelected ? accent.opacity(0.32) : .white.opacity(0.08), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(needsLogin ? "Log in to use \(section.title)" : section.title)
    }
}

private struct EpornerLoginBanner: View {
    @StateObject private var session = EpornerSessionManager.shared
    @State private var showLogin = false

    let accent: Color
    let refresh: () -> Void

    var body: some View {
        Group {
            if !session.isLoggedIn {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not logged in to Eporner")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Log in to access Subscriptions, Liked, Favorites, Watch Later, and History.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Log In") {
                        showLogin = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassCard(tint: accent.opacity(0.12), cornerRadius: 14)
            }
        }
        .sheet(isPresented: $showLogin) {
            EpornerLoginView()
        }
        .onChange(of: session.isLoggedIn) { _, loggedIn in
            if loggedIn {
                refresh()
            }
        }
    }
}

private struct EpornerSubscriptionRail: View {
    @ObservedObject var model: FeedViewModel

    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                Text("Subscriptions")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    Task { await model.refreshEpornerSubscriptions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .disabled(model.isLoadingEpornerSubscriptions)
                .help("Refresh subscriptions")
            }

            allSubscriptionsButton

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if model.isLoadingEpornerSubscriptions {
                        subscriptionLoadingRow
                    } else if model.epornerSubscriptions.isEmpty {
                        subscriptionEmptyRow
                    } else {
                        ForEach(model.epornerSubscriptions) { subscription in
                            subscriptionButton(subscription)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .glassCard(tint: accent.opacity(0.08), cornerRadius: 16)
        .task {
            await model.loadEpornerSubscriptionsIfNeeded()
        }
    }

    private var allSubscriptionsButton: some View {
        let isSelected = model.epornerUploaderURL == nil && model.selectedEpornerSection == .subscriptions
        return Button {
            Task {
                if model.epornerUploaderURL != nil {
                    await model.epornerUploaderBack()
                } else {
                    await model.selectEpornerSection(.subscriptions)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("All")
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: isSelected ? .bold : .semibold))
            .foregroundStyle(isSelected ? accent : Theme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(isSelected ? accent.opacity(0.18) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var subscriptionLoadingRow: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.62)
            Text("Loading")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    private var subscriptionEmptyRow: some View {
        Text(model.epornerSubscriptionsError ?? "None found")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(2)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
    }

    private func subscriptionButton(_ subscription: PornHubSubscription) -> some View {
        let isSelected = model.epornerUploaderURL?.lowercased() == subscription.url.lowercased()
        return Button {
            Task {
                await model.navigateToEpornerUploader(url: subscription.url, name: subscription.name)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(subscription.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: isSelected ? .bold : .regular))
            .foregroundStyle(isSelected ? accent : Theme.textPrimary.opacity(0.84))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(isSelected ? accent.opacity(0.18) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? accent.opacity(0.28) : .white.opacity(0.05), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(subscription.name)
    }
}

private struct EpornerSubscriptionsInlinePicker: View {
    @ObservedObject var model: FeedViewModel

    let accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.isLoadingEpornerSubscriptions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .padding(.horizontal, 8)
                } else if model.epornerSubscriptions.isEmpty {
                    Text(model.epornerSubscriptionsError ?? "No subscriptions found")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 2)
                } else {
                    ForEach(model.epornerSubscriptions) { subscription in
                        Button {
                            Task {
                                await model.navigateToEpornerUploader(url: subscription.url, name: subscription.name)
                            }
                        } label: {
                            Text(subscription.name)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.06), in: Capsule())
                                .overlay(Capsule().strokeBorder(accent.opacity(0.18), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help(subscription.name)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await model.loadEpornerSubscriptionsIfNeeded()
        }
    }
}
