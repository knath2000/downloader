import AppKit
import SwiftUI

@MainActor
struct LibraryView: View {
    @StateObject private var library = VideoLibrary.shared
    @StateObject private var history = HistoryManager.shared
    @StateObject private var thumbnailStore = LibraryThumbnailStore()
    let onUpgradeRequired: () -> Void

    @State private var searchText = ""
    @State private var timelineFilter: LibraryTimelineFilter = .all
    @State private var selectedEntryID: String?
    @State private var selection: Set<UUID> = []
    @State private var showingBulkDeleteConfirmation = false
    @State private var pendingDeleteItem: LibraryItem?
    @FocusState private var searchFocused: Bool

    init(onUpgradeRequired: @escaping () -> Void = {}) {
        self.onUpgradeRequired = onUpgradeRequired
    }

    private var timelineEntries: [LibraryTimelineEntry] {
        LibraryTimelineBuilder.entries(
            libraryItems: library.items,
            historyItems: history.items,
            completedUploads: history.completedUploads
        )
    }

    private var filteredEntries: [LibraryTimelineEntry] {
        LibraryTimelineBuilder.filteredEntries(
            timelineEntries,
            query: searchText,
            filter: timelineFilter
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
        filteredEntries.compactMap { entry in
            if case .video(let item) = entry { return item }
            return nil
        }
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
        VStack(spacing: 12) {
            LibraryToolbar(
                searchText: $searchText,
                timelineFilter: $timelineFilter,
                visibleCount: filteredEntries.count,
                totalCount: timelineEntries.count,
                counts: LibraryTimelineFilterCounts(entries: timelineEntries),
                isRefreshing: thumbnailStore.isRefreshing,
                canRefreshThumbnails: !visibleVideoItems.isEmpty,
                searchFocused: $searchFocused,
                refreshAction: regenerateAllThumbnails
            )

            content
        }
        .safeAreaInset(edge: .bottom) {
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
            }
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
        .onExitCommand {
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
        .onDeleteCommand {
            if !selection.isEmpty {
                showingBulkDeleteConfirmation = true
            } else if let selectedEntry, case .video(let item) = selectedEntry {
                pendingDeleteItem = item
            }
        }
        .onChange(of: filteredEntryIDs) { _, _ in
            syncSelectedEntry()
        }
        .onAppear {
            syncSelectedEntry()
        }
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    @ViewBuilder
    private var content: some View {
        if timelineEntries.isEmpty {
            LibraryEmptyState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredEntries.isEmpty {
            LibraryNoResultsState(
                searchText: searchText,
                filter: timelineFilter,
                clearAction: clearFilters
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                let isWide = proxy.size.width >= 900
                let panelWidth = min(max(proxy.size.width * 0.34, 320), 410)

                if isWide {
                    HStack(alignment: .top, spacing: 12) {
                        timelineScroll(inlineDetail: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if let selectedEntry {
                            ScrollView {
                                detailPanel(for: selectedEntry)
                            }
                            .frame(width: panelWidth)
                            .frame(maxHeight: .infinity)
                        }
                    }
                } else {
                    timelineScroll(inlineDetail: true)
                }
            }
        }
    }

    private func timelineScroll(inlineDetail: Bool) -> some View {
        ScrollView {
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
                                processVideo: process,
                                requestDeleteVideo: { pendingDeleteItem = $0 },
                                selectEntry: selectEntry,
                                toggleVideoSelection: toggleVideoSelection,
                                extractAgain: reExtract,
                                removeLink: { history.remove($0) },
                                removeUpload: { history.removeCompletedUpload($0) }
                            )
                            .task(id: entry.thumbnailIdentity) {
                                if case .video(let item) = entry {
                                    await thumbnailStore.load(item: item)
                                }
                            }

                            if inlineDetail, selectedEntry?.id == entry.id {
                                detailPanel(for: entry)
                                    .padding(.top, 2)
                                    .padding(.bottom, 6)
                            }
                        }
                    } header: {
                        LibraryDayHeader(date: bucket.date, count: bucket.entries.count)
                    }
                }
            }
            .padding(.top, 2)
            .padding(.bottom, selection.isEmpty ? 18 : 76)
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
            processVideo: process,
            requestDeleteVideo: { pendingDeleteItem = $0 },
            extractAgain: reExtract,
            removeLink: { history.remove($0) },
            removeUpload: { history.removeCompletedUpload($0) },
            openURL: openURLString
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
        guard case .video(let item) = entry else { return nil }
        return thumbnailStore.image(for: item)
    }

    private func isThumbnailLoading(_ entry: LibraryTimelineEntry) -> Bool {
        guard case .video(let item) = entry else { return false }
        return thumbnailStore.isLoading(item)
    }

    private func thumbnailFailed(_ entry: LibraryTimelineEntry) -> Bool {
        guard case .video(let item) = entry else { return false }
        return thumbnailStore.didFail(item)
    }

    private func isBulkSelected(_ entry: LibraryTimelineEntry) -> Bool {
        guard case .video(let item) = entry else { return false }
        return selection.contains(item.id)
    }

    private func selectEntry(_ entry: LibraryTimelineEntry) {
        selectedEntryID = entry.id
    }

    private func toggleVideoSelection(_ entry: LibraryTimelineEntry) {
        selection = LibraryTimelineBuilder.videoSelection(selection, toggling: entry)
    }

    private func syncSelectedEntry() {
        selectedEntryID = LibraryTimelineBuilder.selectedEntryID(currentID: selectedEntryID, in: filteredEntries)
    }

    private func deleteSelectedItems() {
        let items = selectedItems
        withAnimation {
            for item in items {
                library.remove(item)
            }
            selection.removeAll()
        }
    }

    private func openPreferredMedia(for item: LibraryItem) {
        let candidate = item.mp4Url ?? item.hlsUrls.first(where: { $0.kind != .pageUrl })?.url ?? item.url
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
        AppStateManager.shared.pendingExtractURL = item.url
        AppStateManager.shared.select(.home)
    }

    private func reExtract(_ item: HistoryItem) {
        AppStateManager.shared.pendingExtractURL = item.url
        AppStateManager.shared.select(.home)
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
        AppStateManager.shared.select(.downloads)
    }

    private func process(_ item: LibraryItem, preset: VideoProcessingPreset) {
        VideoProcessingLauncher.run(
            preset: preset,
            inputPath: localProcessingPath(for: item),
            displayName: LibraryDisplay.title(for: item),
            onUpgradeRequired: onUpgradeRequired
        )
    }

    private func localProcessingPath(for item: LibraryItem) -> String? {
        item.remotePaths[CloudTarget.local.rawValue] ?? item.mp4Url
    }
}

private struct LibraryToolbar: View {
    @Binding var searchText: String
    @Binding var timelineFilter: LibraryTimelineFilter

    let visibleCount: Int
    let totalCount: Int
    let counts: LibraryTimelineFilterCounts
    let isRefreshing: Bool
    let canRefreshThumbnails: Bool
    let searchFocused: FocusState<Bool>.Binding
    let refreshAction: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                LibrarySearchField(text: $searchText, searchFocused: searchFocused)
                LibraryFilterChips(selection: $timelineFilter, counts: counts)
                Spacer(minLength: 10)
                LibrarySummaryText(visibleCount: visibleCount, totalCount: totalCount)
                refreshButton
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    LibrarySearchField(text: $searchText, searchFocused: searchFocused)
                    Spacer(minLength: 10)
                    LibrarySummaryText(visibleCount: visibleCount, totalCount: totalCount)
                    refreshButton
                }
                HStack(spacing: 10) {
                    LibraryFilterChips(selection: $timelineFilter, counts: counts)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard(tint: Theme.skyBlue.opacity(0.1), cornerRadius: 8)
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
            .foregroundStyle(isRefreshing || !canRefreshThumbnails ? Theme.textSecondary.opacity(0.55) : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.accentDim.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.skyBlue.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing || !canRefreshThumbnails)
        .help(canRefreshThumbnails ? "Refresh thumbnails for visible videos" : "No visible videos to refresh")
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
            TextField("Search title, provider, URL, or destination", text: $text)
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
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.accentDim.opacity(0.4), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.skyBlue.opacity(0.25), lineWidth: 0.5))
        .frame(maxWidth: 300)
    }
}

private struct LibraryFilterChips: View {
    @Binding var selection: LibraryTimelineFilter
    let counts: LibraryTimelineFilterCounts

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LibraryTimelineFilter.allCases) { filter in
                    LibraryFilterChip(
                        title: filter.title,
                        count: counts.count(for: filter),
                        tint: filter.tint,
                        isSelected: selection == filter
                    ) {
                        selection = filter
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: 460)
    }
}

private struct LibraryFilterChip: View {
    let title: String
    let count: Int
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
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

private struct LibrarySummaryText: View {
    let visibleCount: Int
    let totalCount: Int

    var body: some View {
        Text(summary)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    private var summary: String {
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
            .background(Theme.surface0.opacity(0.86), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.skyBlue.opacity(0.25), lineWidth: 0.5))

            Spacer()
        }
        .padding(.vertical, 4)
        .background(
            LinearGradient(
                colors: [Theme.meshMidnight.opacity(0.9), Theme.meshMidnight.opacity(0.0)],
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
    let processVideo: (LibraryItem, VideoProcessingPreset) -> Void
    let requestDeleteVideo: (LibraryItem) -> Void
    let selectEntry: (LibraryTimelineEntry) -> Void
    let toggleVideoSelection: (LibraryTimelineEntry) -> Void
    let extractAgain: (HistoryItem) -> Void
    let removeLink: (HistoryItem) -> Void
    let removeUpload: (CompletedUploadItem) -> Void

    @State private var isHovering = false

    private var rowTint: Color {
        switch entry {
        case .video(let item):
            if !item.remotePaths.isEmpty { return Theme.success }
            return LibrarySourceKind.kind(for: item).tint
        case .link(let item):
            return LibraryTimelineProviderTint.color(for: item.provider)
        case .upload(let item):
            return LibraryTimelineDestinationFormatter.color(for: item.destination)
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
        .glassCard(tint: rowTint.opacity(isPreviewSelected ? 0.14 : 0.08), cornerRadius: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPreviewSelected ? Theme.skyBlue.opacity(0.75) : rowTint.opacity(0.12), lineWidth: isPreviewSelected ? 1.5 : 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .onTapGesture { handleTap() }
        .help(entry.url)
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
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
                .frame(width: 78, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if isBulkSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.gold)
                        .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
                        .padding(5)
                }
            }
        case .link:
            timelineIconTile(systemName: "play.rectangle.fill", tint: rowTint)
        case .upload:
            timelineIconTile(systemName: "checkmark.icloud.fill", tint: rowTint)
        }
    }

    private func timelineIconTile(systemName: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.surface2.opacity(0.9))
            .frame(width: 78, height: 44)
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
                ForEach(LibraryDisplay.cloudBadges(for: item), id: \.id) { badge in
                    LibraryCloudBadge(badge: badge)
                }
            case .link(let item):
                LibraryTimelineProviderPill(provider: item.provider)
            case .upload(let item):
                LibraryTimelineProviderPill(provider: item.provider)
                LibraryTimelineDestinationChip(destination: item.destination)
            }

            Text(entry.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        switch entry {
        case .video(let item):
            Text(LibraryTimelineURLFormatter.prettyURL(item.url))
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
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            switch entry {
            case .video(let item):
                LibraryTimelineIconButton(systemName: "play.fill", help: "Open media") {
                    openMedia(item)
                }
                LibraryTimelineIconButton(systemName: "safari", help: "Open source page") {
                    openSource(item)
                }
                LibraryTimelineIconButton(systemName: "arrow.clockwise", help: "Re-extract") {
                    reExtractVideo(item)
                }
                Menu {
                    Button("Mega") { uploadVideo(item, .mega) }
                    Button("Google Drive") { uploadVideo(item, .gdrive) }
                } label: {
                    LibraryTimelineMenuLabel(systemName: "arrow.up.circle", help: "Upload")
                }
                .menuStyle(.borderlessButton)
                .help("Upload")
                Menu {
                    VideoProcessingMenuItems { preset in
                        processVideo(item, preset)
                    }
                } label: {
                    LibraryTimelineMenuLabel(systemName: "wand.and.stars", help: "Pro Processing")
                }
                .menuStyle(.borderlessButton)
                .help("Pro Processing")
            case .link(let item):
                LibraryTimelineIconButton(systemName: "arrow.clockwise", help: "Extract again") {
                    extractAgain(item)
                }
                LibraryTimelineIconButton(systemName: "doc.on.doc", help: "Copy link") {
                    ClipboardManager.copy(item.url)
                }
                LibraryTimelineIconButton(systemName: "safari", help: "Open link") {
                    openURL(item.url)
                }
                LibraryTimelineIconButton(systemName: "trash", help: "Remove") {
                    removeLink(item)
                }
            case .upload(let item):
                LibraryTimelineIconButton(systemName: "arrow.up.right.square", help: "Copy remote path") {
                    ClipboardManager.copy(item.remotePath)
                }
                LibraryTimelineIconButton(systemName: "doc.on.doc", help: "Copy source link") {
                    ClipboardManager.copy(item.url)
                }
                LibraryTimelineIconButton(systemName: "safari", help: "Open source") {
                    openURL(item.url)
                }
                LibraryTimelineIconButton(systemName: "trash", help: "Remove") {
                    removeUpload(item)
                }
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        switch entry {
        case .video(let item):
            Button("Open Source Page") { openSource(item) }
            Button("Open Media") { openMedia(item) }
            Button("Re-extract") { reExtractVideo(item) }
            Menu("Pro Processing") {
                VideoProcessingMenuItems { preset in
                    processVideo(item, preset)
                }
            }
            Divider()
            Button("Upload to Mega") { uploadVideo(item, .mega) }
            Button("Upload to Google Drive") { uploadVideo(item, .gdrive) }
            Divider()
            Button("Refresh Thumbnail") { refreshThumbnail(item) }
            Button("Copy Page URL") { ClipboardManager.copy(item.url) }
            if let mp4 = item.mp4Url {
                Button("Copy MP4 Link") { ClipboardManager.copy(mp4) }
            }
            Divider()
            Button("Delete from Library", role: .destructive) { requestDeleteVideo(item) }
        case .link(let item):
            Button("Extract Again") { extractAgain(item) }
            Button("Copy Link") { ClipboardManager.copy(item.url) }
            Button("Open Link") { openURL(item.url) }
            Divider()
            Button("Remove", role: .destructive) { removeLink(item) }
        case .upload(let item):
            Button("Copy Remote Path") { ClipboardManager.copy(item.remotePath) }
            Button("Copy Source Link") { ClipboardManager.copy(item.url) }
            Button("Open Source Link") { openURL(item.url) }
            Divider()
            Button("Remove", role: .destructive) { removeUpload(item) }
        }
    }

    private var accessibilityLabel: String {
        let date = entry.timestamp.formatted(date: .abbreviated, time: .omitted)
        let time = LibraryDateFormatter.timeLabel(for: entry.timestamp)
        switch entry {
        case .video(let item):
            let uploaded = LibraryDisplay.cloudBadges(for: item).map(\.title).joined(separator: ", ")
            let status = uploaded.isEmpty ? "local only" : uploaded
            return "Library video, \(entry.title), \(time), \(date), \(status)"
        case .link(let item):
            return "\(LibraryTimelineProviderTint.displayName(for: item.provider)) link, \(entry.title), \(time), \(date)"
        case .upload(let item):
            return "\(LibraryTimelineDestinationFormatter.shortName(for: item.destination)) upload, \(entry.title), \(time), \(date)"
        }
    }

    private func handleTap() {
        selectEntry(entry)
        if NSEvent.modifierFlags.contains(.command) {
            toggleVideoSelection(entry)
        }
    }

    private func openURL(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
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
    let processVideo: (LibraryItem, VideoProcessingPreset) -> Void
    let requestDeleteVideo: (LibraryItem) -> Void
    let extractAgain: (HistoryItem) -> Void
    let removeLink: (HistoryItem) -> Void
    let removeUpload: (CompletedUploadItem) -> Void
    let openURL: (String) -> Void

    private var tint: Color {
        switch entry {
        case .video(let item):
            if !item.remotePaths.isEmpty { return Theme.success }
            return LibrarySourceKind.kind(for: item).tint
        case .link(let item):
            return LibraryTimelineProviderTint.color(for: item.provider)
        case .upload(let item):
            return LibraryTimelineDestinationFormatter.color(for: item.destination)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            panelContent
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassCard(tint: tint.opacity(0.1), cornerRadius: 8)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch entry {
        case .video(let item):
            videoPanel(item)
        case .link(let item):
            linkPanel(item)
        case .upload(let item):
            uploadPanel(item)
        }
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

                LibraryKindBadge(kind: LibrarySourceKind.kind(for: item))
                    .padding(8)
            }

            titleBlock(title: LibraryDisplay.title(for: item), subtitle: LibraryDisplay.domain(for: item.url))

            if LibraryDisplay.cloudBadges(for: item).isEmpty {
                LibraryDetailChip(title: "Local only", tint: Theme.textSecondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(LibraryDisplay.cloudBadges(for: item), id: \.id) { badge in
                        LibraryCloudBadge(badge: badge)
                    }
                }
            }

            metadataRows {
                LibraryDetailMetadataRow(label: "Source", value: item.url, systemName: "link")
                LibraryDetailMetadataRow(label: "Extracted", value: item.extractedAt.formatted(date: .abbreviated, time: .shortened), systemName: "calendar")
                LibraryDetailMetadataRow(label: "Media", value: LibrarySourceKind.kind(for: item).label, systemName: "film")
                ForEach(item.remotePaths.keys.sorted(), id: \.self) { key in
                    if let value = item.remotePaths[key] {
                        LibraryDetailMetadataRow(label: LibraryTimelineDestinationFormatter.shortName(for: key), value: value, systemName: "externaldrive.fill")
                    }
                }
            }

            actionGroup {
                LibraryDetailActionButton(title: "Open Media", systemName: "play.fill", tint: Theme.skyBlue) { openMedia(item) }
                LibraryDetailActionButton(title: "Open Source", systemName: "safari", tint: Theme.textSecondary) { openSource(item) }
                LibraryDetailActionButton(title: "Re-extract", systemName: "arrow.clockwise", tint: Theme.lavender) { reExtractVideo(item) }
                Menu {
                    Button("Mega") { uploadVideo(item, .mega) }
                    Button("Google Drive") { uploadVideo(item, .gdrive) }
                } label: {
                    LibraryDetailActionLabel(title: "Upload", systemName: "arrow.up.circle", tint: Theme.success)
                }
                .menuStyle(.borderlessButton)
                Menu {
                    VideoProcessingMenuItems { preset in
                        processVideo(item, preset)
                    }
                } label: {
                    LibraryDetailActionLabel(title: "Pro Processing", systemName: "wand.and.stars", tint: Theme.gold)
                }
                .menuStyle(.borderlessButton)
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
                .minimumScaleFactor(0.8)

            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
    }
}

private struct LibraryDetailChip: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
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
        .help(title)
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

private struct LibraryCardView: View {
    let item: LibraryItem
    let thumbnail: NSImage?
    let isThumbnailLoading: Bool
    let thumbnailFailed: Bool
    let isSelected: Bool
    let refreshThumbnail: () -> Void
    let openMedia: () -> Void
    let openSource: () -> Void
    let reExtract: () -> Void
    let upload: (CloudTarget) -> Void
    let process: (VideoProcessingPreset) -> Void
    let requestDelete: () -> Void
    let toggleSelection: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var sourceKind: LibrarySourceKind {
        LibrarySourceKind.kind(for: item)
    }

    private var cardTint: Color {
        if !item.remotePaths.isEmpty {
            return sourceKind == .hls ? Theme.lavender : Theme.skyBlue
        }
        return sourceKind.tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnailArea

            VStack(alignment: .leading, spacing: 4) {
                Text(LibraryDisplay.title(for: item))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .help(item.title)

                HStack(spacing: 6) {
                    Text(LibraryDisplay.domain(for: item.url))
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    ForEach(LibraryDisplay.cloudBadges(for: item), id: \.id) { badge in
                        LibraryCloudBadge(badge: badge)
                    }
                }
            }
        }
        .padding(8)
        .glassCard(tint: cardTint.opacity(0.18), cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Theme.gold.opacity(0.85) : .clear, lineWidth: 2)
        )
        .overlay(alignment: .topLeading) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.gold)
                    .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 1)
                    .padding(12)
            }
        }
        .scaleEffect(isHovered && !reduceMotion ? 1.015 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovered = $0 }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                toggleSelection()
            } else {
                openSource()
            }
        }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var thumbnailArea: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.surface2)

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    LibraryThumbnailPlaceholder(
                        item: item,
                        isLoading: isThumbnailLoading,
                        didFail: thumbnailFailed,
                        retryAction: refreshThumbnail
                    )
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            LibraryKindBadge(kind: sourceKind)
                .padding(7)

            if isHovered {
                LibraryHoverOverlay(
                    openMedia: openMedia,
                    openSource: openSource,
                    reExtract: reExtract,
                    upload: upload,
                    delete: requestDelete
                )
                .transition(.opacity.combined(with: reduceMotion ? .identity : .move(edge: .bottom)))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .help(item.url)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open Source Page") { openSource() }
        Button("Open Media") { openMedia() }
        Button("Re-extract") { reExtract() }
        Menu("Pro Processing") {
            VideoProcessingMenuItems(process: process)
        }
        Divider()
        Button("Upload to Mega") { upload(.mega) }
        Button("Upload to Google Drive") { upload(.gdrive) }
        Divider()
        Button("Refresh Thumbnail") { refreshThumbnail() }
        Button("Copy Page URL") { ClipboardManager.copy(item.url) }
        if let mp4 = item.mp4Url {
            Button("Copy MP4 Link") { ClipboardManager.copy(mp4) }
        }
        Divider()
        Button("Delete from Library", role: .destructive) { requestDelete() }
    }

    private var accessibilityLabel: String {
        let uploaded = LibraryDisplay.cloudBadges(for: item).map(\.title).joined(separator: ", ")
        let status = uploaded.isEmpty ? "local only" : "uploaded to \(uploaded)"
        return "\(LibraryDisplay.title(for: item)), \(sourceKind.label), \(item.extractedAt.formatted(date: .abbreviated, time: .shortened)), \(status)"
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
                .help("Retry thumbnail")
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
            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
    }
}

private struct LibraryCloudBadge: View {
    let badge: LibraryCloudBadgeModel

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

private struct LibraryHoverOverlay: View {
    let openMedia: () -> Void
    let openSource: () -> Void
    let reExtract: () -> Void
    let upload: (CloudTarget) -> Void
    let delete: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                LibraryOverlayButton(systemName: "play.fill", help: "Open media", action: openMedia)
                LibraryOverlayButton(systemName: "safari", help: "Open source page", action: openSource)
                Menu {
                    Button("Mega") { upload(.mega) }
                    Button("Google Drive") { upload(.gdrive) }
                } label: {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(.black.opacity(0.32), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .help("Upload")
                LibraryOverlayButton(systemName: "arrow.clockwise", help: "Re-extract", action: reExtract)
                LibraryOverlayButton(systemName: "trash", help: "Delete", action: delete)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.0), .black.opacity(0.62)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }
}

private struct LibraryOverlayButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.32), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
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

enum LibraryTimelineFilter: String, CaseIterable, Identifiable {
    case all
    case videos
    case links
    case uploads

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "All"
        case .videos: return "Videos"
        case .links: return "Links"
        case .uploads: return "Uploads"
        }
    }

    var tint: Color {
        switch self {
        case .all: return Theme.gold
        case .videos: return Theme.skyBlue
        case .links: return Theme.lavender
        case .uploads: return Theme.success
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
        }
    }
}

struct LibraryTimelineFilterCounts {
    let entries: [LibraryTimelineEntry]

    func count(for filter: LibraryTimelineFilter) -> Int {
        entries.filter(filter.matches(_:)).count
    }
}

enum LibraryTimelineEntry: Identifiable {
    case video(LibraryItem)
    case link(HistoryItem)
    case upload(CompletedUploadItem)

    var id: String {
        switch self {
        case .video(let item): return "video-\(item.id.uuidString)"
        case .link(let item): return "link-\(item.id.uuidString)"
        case .upload(let item): return "upload-\(item.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .video(let item): return LibraryDisplay.title(for: item)
        case .link(let item): return item.title
        case .upload(let item): return item.title
        }
    }

    var url: String {
        switch self {
        case .video(let item): return item.url
        case .link(let item): return item.url
        case .upload(let item): return item.url
        }
    }

    var timestamp: Date {
        switch self {
        case .video(let item): return item.extractedAt
        case .link(let item): return item.recordedAt
        case .upload(let item): return item.completedAt
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
        completedUploads: [CompletedUploadItem]
    ) -> [LibraryTimelineEntry] {
        let libraryURLs = Set(libraryItems.map { normalizedURL($0.url) }.filter { !$0.isEmpty })
        let videos = libraryItems.map(LibraryTimelineEntry.video)
        let links = historyItems
            .filter { !libraryURLs.contains(normalizedURL($0.url)) }
            .map(LibraryTimelineEntry.link)
        let uploads = completedUploads.map(LibraryTimelineEntry.upload)

        return (videos + links + uploads).sorted {
            if $0.timestamp == $1.timestamp { return $0.id < $1.id }
            return $0.timestamp > $1.timestamp
        }
    }

    static func filteredEntries(
        _ entries: [LibraryTimelineEntry],
        query: String,
        filter: LibraryTimelineFilter
    ) -> [LibraryTimelineEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            let queryMatches = normalizedQuery.isEmpty || searchText(for: entry).contains(normalizedQuery)
            return queryMatches && filter.matches(entry)
        }
    }

    static func selectedEntryID(currentID: String?, in entries: [LibraryTimelineEntry]) -> String? {
        if let currentID, entries.contains(where: { $0.id == currentID }) {
            return currentID
        }
        return entries.first?.id
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

    static func searchText(for entry: LibraryTimelineEntry) -> String {
        switch entry {
        case .video(let item):
            return LibraryDisplay.searchText(for: item)
        case .link(let item):
            return "\(item.title) \(item.provider) \(item.url) \(LibraryDisplay.domain(for: item.url))".lowercased()
        case .upload(let item):
            return "\(item.title) \(item.provider) \(item.destination) \(item.remotePath) \(item.url) \(LibraryDisplay.domain(for: item.url))".lowercased()
        }
    }

    static func normalizedURL(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum LibrarySourceKind: Equatable {
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

private struct LibraryCloudBadgeModel {
    let id: String
    let title: String
    let tint: Color
}

private enum LibraryDisplay {
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

    static func cloudBadges(for item: LibraryItem) -> [LibraryCloudBadgeModel] {
        item.remotePaths.keys.sorted().map { key in
            switch key.lowercased() {
            case "mega":
                return LibraryCloudBadgeModel(id: key, title: "up Mega", tint: Theme.success)
            case "gdrive":
                return LibraryCloudBadgeModel(id: key, title: "up Drive", tint: Theme.skyBlue)
            case "seedbox":
                return LibraryCloudBadgeModel(id: key, title: "up Seedbox", tint: Theme.lavender)
            default:
                return LibraryCloudBadgeModel(id: key, title: "up \(key)", tint: Theme.textSecondary)
            }
        }
    }

    static func searchText(for item: LibraryItem) -> String {
        let clouds = item.remotePaths.flatMap { key, value in [key, value] }.joined(separator: " ")
        return "\(displayTitle(item.title)) \(item.title) \(item.url) \(domain(for: item.url)) \(LibrarySourceKind.kind(for: item).label) \(clouds)".lowercased()
    }
}

private enum LibraryTimelineProviderTint {
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
        case "generic":
            return "Generic"
        default:
            let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Unknown" : trimmed
        }
    }
}

private enum LibraryTimelineURLFormatter {
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

private enum LibraryTimelineDestinationFormatter {
    static func shortName(for destination: String) -> String {
        let lower = destination.lowercased()
        if lower.contains("mega") { return "MEGA" }
        if lower.contains("drive") || lower.contains("gdrive") { return "Drive" }
        if lower.contains("seedbox") { return "Seedbox" }
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
        return Theme.textSecondary
    }
}

private enum LibraryDateFormatter {
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

private enum LibraryDownloadContext {
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
            seedboxWebdavPassword: defaults.string(forKey: "seedboxWebdavPassword") ?? ""
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
