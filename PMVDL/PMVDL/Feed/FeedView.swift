import AppKit
import SwiftUI

private enum FeedLayout {
    static let contentMaxWidth: CGFloat = 1760
    static let outerSpacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 14
    static let toolbarCornerRadius: CGFloat = 18
    static let gridBottomPadding: CGFloat = 18
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
        availableWidth < 980 ? 12 : 18
    }

    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: columnMinWidth), spacing: spacing)]
    }
}

struct FeedView: View {
    @StateObject private var model = FeedViewModel.shared
    @StateObject private var favorites = FeedFavoritesStore.shared
    @StateObject private var profileVM = ProfileViewModel.shared
    @State private var showsAdvancedFilters = false
    @State private var selectedItemIDs: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSelecting: Bool { !selectedItemIDs.isEmpty }
    private var capabilities: FeedSiteCapabilities {
        FeedSiteCapabilities.capabilities(for: model.selectedSite)
    }
    private var siteTheme: FeedSiteTheme {
        FeedSiteTheme.theme(for: model.selectedSite)
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = min(
                max(proxy.size.width - FeedLayout.outerSpacing * 2, 0),
                FeedLayout.contentMaxWidth
            )

            VStack(spacing: FeedLayout.outerSpacing) {
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
                    sortMode: $model.sortMode,
                    showsAdvancedFilters: $showsAdvancedFilters,
                    capabilities: capabilities,
                    theme: siteTheme,
                    availableStudios: model.availableStudios,
                    availableCategories: model.availableCategories,
                    availableTags: model.availableTags,
                    availableQualityLabels: model.availableQualityLabels,
                    clearFilters: model.clearFilters
                )

                if model.selectedSite == PornHubFeedScraper.supportedHost {
                    PornHubSectionPicker(model: model, accent: siteTheme.accent)
                    PornHubLoginBanner {
                        Task { await model.refresh() }
                    }
                }

                if model.sortMode == .profileCurated,
                   case .idle = profileVM.state {
                    profileCuratedNoBanner
                }

                if !model.filters.activeChips.isEmpty {
                    FeedActiveFiltersRow(
                        chips: model.filters.activeChips,
                        accent: siteTheme.accent,
                        remove: removeActiveFilter,
                        clearAll: model.clearFilters
                    )
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }

                if let error = model.error, !model.items.isEmpty {
                    FeedInlineErrorBanner(message: error, accent: siteTheme.accent) {
                        Task { await model.refresh() }
                    }
                }

                content(availableWidth: availableWidth)

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
        }
        .onChange(of: model.filters.date) { _, _ in
            model.resetPaginationForFilter()
        }
        .onChange(of: model.selectedSite) { _, newSite in
            applySiteCapabilities(for: newSite)
            selectedItemIDs = []
            if newSite != PornHubFeedScraper.supportedHost {
                model.pornHubUploaderURL = nil
                model.pornHubUploaderName = nil
            }
            Task { await model.refresh() }
        }
        .onChange(of: model.selectedPornHubSection) { _, _ in
            selectedItemIDs = []
        }
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
                FeedSkeletonGrid(layout: FeedGridLayout(availableWidth: availableWidth), accent: siteTheme.accent)
                    .padding(.bottom, FeedLayout.gridBottomPadding)
            }
        } else if model.filteredItems.isEmpty {
            FeedEmptyState(
                filters: model.filters,
                hasMore: model.hasMore,
                accent: siteTheme.accent,
                clearFilters: model.clearFilters,
                loadMore: { Task { await model.loadMore() } },
                refresh: { Task { await model.refresh() } }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                let layout = FeedGridLayout(availableWidth: availableWidth)
                LazyVStack(alignment: .leading, spacing: FeedLayout.sectionSpacing, pinnedViews: [.sectionHeaders]) {
                    if capabilities.groupsByDate {
                        ForEach(model.dayBuckets) { bucket in
                            Section {
                                feedGrid(items: bucket.items, layout: layout)
                            } header: {
                                FeedDayHeader(date: bucket.date, count: bucket.items.count, accent: siteTheme.accent)
                            }
                        }
                    } else {
                        feedGrid(items: model.filteredItems, layout: layout)
                    }

                    loadMoreRow
                }
                .padding(.bottom, FeedLayout.gridBottomPadding)
            }
        }
    }

    private var profileCuratedNoBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(Theme.gold)
            Text("No profile generated yet. Go to Profile tab to generate one.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("Go to Profile") {
                AppStateManager.shared.select(.profile)
            }
            .buttonStyle(.bordered)
            .tint(Theme.gold)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassCard(tint: Theme.gold.opacity(0.12), cornerRadius: 14)
    }

    private var batchSelectionBar: some View {
        HStack(spacing: 12) {
            Text("\(selectedItemIDs.count) selected")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            Button("Clear") {
                selectedItemIDs = []
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

    private func feedGrid(items: [FeedItem], layout: FeedGridLayout) -> some View {
        let profileMatchReasons = model.sortMode == .profileCurated ? model.profileMatchReasons : [:]

        return LazyVGrid(
            columns: layout.columns,
            alignment: .leading,
            spacing: layout.spacing
        ) {
            ForEach(items) { item in
                FeedCardView(
                    item: item,
                    isFavorite: favorites.contains(url: item.url),
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
                    },
                    profileMatch: profileMatchReasons[item.id]
                )
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        selectionBadge(for: item)
                    }
                }
                .contextMenu {
                    cardContextMenu(for: item)
                }
            }
        }
    }

    private func selectionBadge(for item: FeedItem) -> some View {
        Image(systemName: selectedItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(selectedItemIDs.contains(item.id) ? siteTheme.accent : .white.opacity(0.7))
            .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
            .padding(10)
    }

    @ViewBuilder
    private func cardContextMenu(for item: FeedItem) -> some View {
        Button(selectedItemIDs.contains(item.id) ? "Deselect" : "Select") {
            toggleSelection(item)
        }
        Button("Select All Visible") {
            selectedItemIDs = Set(model.filteredItems.map(\.id))
        }
        if isSelecting {
            Divider()
            Button("Extract Selected (\(selectedItemIDs.count))") {
                extractSelected()
            }
            Button("Clear Selection") {
                selectedItemIDs = []
            }
        }
        Divider()
        Button("Extract") { extract(item) }
        Button(favorites.contains(url: item.url) ? "Remove from Favorites" : "Add to Favorites") {
            withAnimation {
                favorites.toggle(feedItem: item)
            }
        }
        Divider()
        Button("Copy Link") { ClipboardManager.copy(item.url) }
        Button("Open in Browser") { openInBrowser(item) }
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            if model.hasMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    if model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    } else {
                        Label("Load More", systemImage: "plus")
                    }
                }
                .buttonStyle(.bordered)
                .tint(siteTheme.accent)
                .controlSize(.small)
                .disabled(model.isLoading)
            } else {
                Text("No more videos for this filter")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.top, 2)
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

    private func toggleSelection(_ item: FeedItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    private func extractSelected() {
        let selected = model.filteredItems.filter { selectedItemIDs.contains($0.id) }
        guard !selected.isEmpty else { return }

        AppStateManager.shared.pendingExtractThumbnailURL = nil
        AppStateManager.shared.pendingExtractShouldStart = true
        AppStateManager.shared.pendingExtractURL = selected.map(\.url).joined(separator: "\n")
        selectedItemIDs = []
        AppStateManager.shared.select(.home)
    }

    private func openInBrowser(_ item: FeedItem) {
        guard let url = URL(string: item.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func applySiteCapabilities(for site: String) {
        let caps = FeedSiteCapabilities.capabilities(for: site)
        if site == PornHubFeedScraper.supportedHost {
            model.sortMode = .newest
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
                .frame(width: 36, height: 36)
                .background(theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.accent.opacity(0.24), lineWidth: 0.5))

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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
    let clearFilters: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    horizontal
                    vertical
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    private var horizontal: some View {
        HStack(spacing: 10) {
            sitePicker
                .layoutPriority(2)
            searchField
                .layoutPriority(3)
            datePicker
            sortPicker
            filterToggle
            clearButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var vertical: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sitePicker
                filterToggle
                clearButton
            }
            HStack(spacing: 8) {
                searchField
                datePicker
                sortPicker
            }
        }
    }

    private var sitePicker: some View {
        FeedMenuPicker(title: "Site", accent: theme.accent) {
            Picker("Site", selection: $selectedSite) {
                Text(AllPornStreamFeedScraper.supportedHost).tag(AllPornStreamFeedScraper.supportedHost)
                Text(RentryFeedScraper.supportedHost).tag(RentryFeedScraper.supportedHost)
                Text(HQPornerFeedScraper.supportedHost).tag(HQPornerFeedScraper.supportedHost)
                Text(PornHubFeedScraper.supportedHost).tag(PornHubFeedScraper.supportedHost)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 210)
        }
        .accessibilityLabel(Text("Feed source"))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
            TextField("Search title, studio, tag", text: $filters.query)
                .textFieldStyle(.plain)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.accent.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.20), lineWidth: 0.5))
        .frame(minWidth: 220, idealWidth: 270, maxWidth: 320)
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
                .frame(width: 132)
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
            .frame(width: 154)
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
        }
        .buttonStyle(.bordered)
        .tint(theme.accent)
        .controlSize(.small)
        .help("Show advanced feed filters")
        .accessibilityLabel(Text(showsAdvancedFilters ? "Hide advanced filters" : "Show advanced filters"))
    }

    @ViewBuilder
    private var clearButton: some View {
        if !filters.isDefault {
            Button("Clear", action: clearFilters)
                .buttonStyle(.bordered)
                .tint(theme.accent)
                .controlSize(.small)
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
            content
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(accent.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(accent.opacity(0.20), lineWidth: 0.5))
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                Text("Advanced filters")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Narrow by metrics, source metadata, and discovery tags.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
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
        .padding(12)
        .background(Theme.surface1.opacity(0.34), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.16), lineWidth: 0.8))
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
    let hasMore: Bool
    let accent: Color
    let clearFilters: () -> Void
    let loadMore: () -> Void
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

                if hasMore {
                    Button("Load More", action: loadMore)
                        .buttonStyle(.bordered)
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
            return "No videos match \"\(filters.query)\" in the current source."
        }
        return "Try clearing filters, changing the date range, or loading more from the source."
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
        default:
            return site
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
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
