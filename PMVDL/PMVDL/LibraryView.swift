import AppKit
import SwiftUI

@MainActor
struct LibraryView: View {
    @StateObject private var library = VideoLibrary.shared
    @StateObject private var thumbnailStore = LibraryThumbnailStore()
    let onUpgradeRequired: () -> Void

    @State private var searchText = ""
    @State private var kindFilter: LibraryKindFilter = .all
    @State private var sortMode: LibrarySortMode = .newest
    @State private var selection: Set<UUID> = []
    @State private var showingBulkDeleteConfirmation = false
    @State private var pendingDeleteItem: LibraryItem?
    @FocusState private var searchFocused: Bool

    init(onUpgradeRequired: @escaping () -> Void = {}) {
        self.onUpgradeRequired = onUpgradeRequired
    }

    private var filteredItems: [LibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = library.items.filter { item in
            let queryMatches = query.isEmpty || LibraryDisplay.searchText(for: item).contains(query)
            return queryMatches && kindFilter.matches(item)
        }

        switch sortMode {
        case .newest:
            return filtered.sorted { $0.extractedAt > $1.extractedAt }
        case .oldest:
            return filtered.sorted { $0.extractedAt < $1.extractedAt }
        case .titleAscending:
            return filtered.sorted {
                LibraryDisplay.title(for: $0).localizedCaseInsensitiveCompare(LibraryDisplay.title(for: $1)) == .orderedAscending
            }
        case .titleDescending:
            return filtered.sorted {
                LibraryDisplay.title(for: $0).localizedCaseInsensitiveCompare(LibraryDisplay.title(for: $1)) == .orderedDescending
            }
        }
    }

    private var dayBuckets: [LibraryDayBucket] {
        Dictionary(grouping: filteredItems) { item in
            Calendar.current.startOfDay(for: item.extractedAt)
        }
        .map { date, items in
            LibraryDayBucket(date: date, items: items)
        }
        .sorted { $0.date > $1.date }
    }

    private var selectedItems: [LibraryItem] {
        library.items.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 12) {
            LibraryToolbar(
                searchText: $searchText,
                kindFilter: $kindFilter,
                sortMode: $sortMode,
                visibleCount: filteredItems.count,
                totalCount: library.items.count,
                counts: LibraryKindFilterCounts(items: library.items),
                isRefreshing: thumbnailStore.isRefreshing,
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
            }
        }
        .onDeleteCommand {
            if !selection.isEmpty {
                showingBulkDeleteConfirmation = true
            }
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
        if library.items.isEmpty {
            LibraryEmptyState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredItems.isEmpty {
            LibraryNoResultsState(
                searchText: searchText,
                filter: kindFilter,
                clearAction: clearFilters
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    ForEach(dayBuckets) { bucket in
                        Section {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 240), spacing: 14)],
                                alignment: .leading,
                                spacing: 14
                            ) {
                                ForEach(bucket.items) { item in
                                    LibraryCardView(
                                        item: item,
                                        thumbnail: thumbnailStore.image(for: item),
                                        isThumbnailLoading: thumbnailStore.isLoading(item),
                                        thumbnailFailed: thumbnailStore.didFail(item),
                                        isSelected: selection.contains(item.id),
                                        refreshThumbnail: {
                                            Task { await thumbnailStore.load(item: item, force: true) }
                                        },
                                        openMedia: { openPreferredMedia(for: item) },
                                        openSource: { openSource(for: item) },
                                        reExtract: { reExtract(item) },
                                        upload: { target in uploadItems([item], to: target) },
                                        process: { preset in process(item, preset: preset) },
                                        requestDelete: { pendingDeleteItem = item },
                                        toggleSelection: { toggleSelection(for: item) }
                                    )
                                    .task(id: thumbnailTaskID(for: item)) {
                                        await thumbnailStore.load(item: item)
                                    }
                                }
                            }
                        } header: {
                            LibraryDayHeader(date: bucket.date, count: bucket.items.count)
                        }
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, selection.isEmpty ? 18 : 76)
            }
        }
    }

    private func regenerateAllThumbnails() {
        Task {
            await thumbnailStore.refresh(items: filteredItems.isEmpty ? library.items : filteredItems, force: true)
        }
    }

    private func thumbnailTaskID(for item: LibraryItem) -> String {
        item.thumbnailURL ?? item.mp4Url ?? item.hlsUrls.first?.url ?? item.url
    }

    private func clearFilters() {
        searchText = ""
        kindFilter = .all
        sortMode = .newest
    }

    private func toggleSelection(for item: LibraryItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
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
    @Binding var kindFilter: LibraryKindFilter
    @Binding var sortMode: LibrarySortMode

    let visibleCount: Int
    let totalCount: Int
    let counts: LibraryKindFilterCounts
    let isRefreshing: Bool
    let searchFocused: FocusState<Bool>.Binding
    let refreshAction: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                LibrarySearchField(text: $searchText, searchFocused: searchFocused)
                LibraryFilterChips(selection: $kindFilter, counts: counts)
                Spacer(minLength: 10)
                LibrarySortMenu(selection: $sortMode)
                LibraryCountBadge(visibleCount: visibleCount, totalCount: totalCount)
                refreshButton
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    LibrarySearchField(text: $searchText, searchFocused: searchFocused)
                    Spacer(minLength: 10)
                    LibraryCountBadge(visibleCount: visibleCount, totalCount: totalCount)
                    refreshButton
                }
                HStack(spacing: 10) {
                    LibraryFilterChips(selection: $kindFilter, counts: counts)
                    Spacer(minLength: 10)
                    LibrarySortMenu(selection: $sortMode)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(tint: Theme.skyBlue.opacity(0.15), cornerRadius: 14)
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
            .foregroundStyle(isRefreshing || totalCount == 0 ? Theme.textSecondary.opacity(0.55) : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.accentDim.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.skyBlue.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing || totalCount == 0)
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
            TextField("Search title, source, or domain", text: $text)
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
        .frame(maxWidth: 320)
    }
}

private struct LibraryFilterChips: View {
    @Binding var selection: LibraryKindFilter
    let counts: LibraryKindFilterCounts

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LibraryKindFilter.allCases) { filter in
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

private struct LibrarySortMenu: View {
    @Binding var selection: LibrarySortMode

    var body: some View {
        Menu {
            Picker("Sort", selection: $selection) {
                ForEach(LibrarySortMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                Text(selection.title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.accentDim.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.skyBlue.opacity(0.22), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct LibraryCountBadge: View {
    let visibleCount: Int
    let totalCount: Int

    var body: some View {
        Text(visibleCount == totalCount ? "\(totalCount)" : "\(visibleCount) / \(totalCount)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.skyBlue)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.skyBlue.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.skyBlue.opacity(0.25), lineWidth: 0.5))
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
            ForEach(VideoProcessingPreset.allCases) { preset in
                Button {
                    process(preset)
                } label: {
                    Label(preset.title, systemImage: preset.systemImage)
                }
            }
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
            Text("No videos in library yet")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text("Extract a video URL to add items here")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary.opacity(0.65))
        }
    }
}

private struct LibraryNoResultsState: View {
    let searchText: String
    let filter: LibraryKindFilter
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
            return "No matching videos"
        }
        var parts: [String] = []
        if !query.isEmpty { parts.append("\"\(query)\"") }
        if filter != .all { parts.append("in \(filter.title)") }
        return "No matches for \(parts.joined(separator: " "))"
    }
}

private enum LibraryKindFilter: String, CaseIterable, Identifiable {
    case all
    case mp4
    case hls
    case uploaded
    case localOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "All"
        case .mp4: return "MP4"
        case .hls: return "HLS"
        case .uploaded: return "Uploaded"
        case .localOnly: return "Local only"
        }
    }

    var tint: Color {
        switch self {
        case .all: return Theme.gold
        case .mp4: return Theme.gold
        case .hls: return Theme.taoRed
        case .uploaded: return Theme.success
        case .localOnly: return Theme.skyBlue
        }
    }

    func matches(_ item: LibraryItem) -> Bool {
        switch self {
        case .all:
            return true
        case .mp4:
            return item.mp4Url != nil && item.hlsUrls.isEmpty
        case .hls:
            return !item.hlsUrls.isEmpty
        case .uploaded:
            return !item.remotePaths.isEmpty
        case .localOnly:
            return item.remotePaths.isEmpty
        }
    }
}

private struct LibraryKindFilterCounts {
    let items: [LibraryItem]

    func count(for filter: LibraryKindFilter) -> Int {
        items.filter(filter.matches(_:)).count
    }
}

private enum LibrarySortMode: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case titleAscending
    case titleDescending

    var id: Self { self }

    var title: String {
        switch self {
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .titleAscending: return "A-Z"
        case .titleDescending: return "Z-A"
        }
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

private struct LibraryDayBucket: Identifiable {
    let date: Date
    let items: [LibraryItem]

    var id: Date { date }
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
        let clouds = item.remotePaths.keys.joined(separator: " ")
        return "\(displayTitle(item.title)) \(item.title) \(item.url) \(domain(for: item.url)) \(LibrarySourceKind.kind(for: item).label) \(clouds)".lowercased()
    }
}

private enum LibraryDateFormatter {
    static func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
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
