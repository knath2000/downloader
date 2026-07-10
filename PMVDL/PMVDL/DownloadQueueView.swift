import AppKit
import SwiftUI

@MainActor
struct DownloadQueueViewNew: View {
    @StateObject private var queue = DownloadQueue.shared
    @ObservedObject private var appState = AppStateManager.shared
    @AppStorage("seedboxWebdavPassword") private var seedboxWebdavPassword = ""

    @State private var searchText = ""
    @State private var statusFilter: DownloadStatusFilter = .all
    @State private var doneExpanded = false
    @State private var selection: Set<UUID> = []
    @State private var lastSelectedID: UUID?
    @State private var showingBulkRemoveConfirmation = false
    @State private var diagnosticItem: DownloadQueueItem?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onUpgradeRequired: () -> Void

    init(onUpgradeRequired: @escaping () -> Void = {}) {
        self.onUpgradeRequired = onUpgradeRequired
    }

    private var downloadItems: [DownloadQueueItem] {
        queue.queue.filter(\.isVisibleInDownloads)
    }

    private var visibleItems: [DownloadQueueItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return downloadItems.filter { item in
            let queryMatches = query.isEmpty || DownloadStatusFormatting.searchText(for: item).contains(query)
            return queryMatches && statusFilter.matches(item)
        }
    }

    private var sections: [DownloadQueueSection] {
        DownloadSectionKind.allCases.compactMap { kind in
            let items = visibleItems.filter { kind.contains($0) }
            guard !items.isEmpty else { return nil }
            let sorted: [DownloadQueueItem]
            if kind == .active {
                sorted = items.sorted { $0.progress > $1.progress }
            } else {
                sorted = items.sorted { $0.createdAt > $1.createdAt }
            }
            return DownloadQueueSection(kind: kind, items: sorted)
        }
    }

    private var selectedItems: [DownloadQueueItem] {
        downloadItems.filter { selection.contains($0.id) }
    }

    private var visibleRowAnimationKey: [String] {
        visibleItems.map { "\($0.id.uuidString)-\(DownloadStatusFormatting.statusLabel($0))" }
    }

    var body: some View {
        VStack(spacing: 12) {
            DownloadsToolbar(
                searchText: $searchText,
                statusFilter: $statusFilter,
                visibleCount: visibleItems.count,
                totalCount: downloadItems.count,
                counts: DownloadStatusFilterCounts(items: downloadItems),
                searchFocused: $searchFocused,
                pauseAll: pauseAll,
                resumeAll: resumeAll,
                retryAllFailed: retryAllFailed,
                clearDone: clearDone,
                clearFailed: clearFailed
            )

            content
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: downloadItems.isEmpty)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                DownloadSelectionBar(
                    count: selection.count,
                    retryAction: retrySelected,
                    pauseAction: pauseSelected,
                    resumeAction: resumeSelected,
                    removeAction: { showingBulkRemoveConfirmation = true },
                    clearAction: { selection.removeAll() }
                )
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
        }
        .confirmationDialog(
            "Remove selected downloads?",
            isPresented: $showingBulkRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove \(selection.count) Items", role: .destructive) {
                removeSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected queue rows. Running work is cancelled.")
        }
        .sheet(item: $diagnosticItem) { item in
            DownloadDiagnosticSheet(item: item)
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
                showingBulkRemoveConfirmation = true
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
        if downloadItems.isEmpty {
            DownloadsEmptyState {
                AppStateManager.shared.select(.home)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        } else if visibleItems.isEmpty {
            DownloadsNoResultsState(
                filter: statusFilter,
                completedCount: downloadItems.filter { $0.status == .completed }.count,
                showDone: {
                    statusFilter = .done
                    doneExpanded = true
                },
                clearFilters: clearFilters
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            if section.kind != .done || doneExpanded || statusFilter == .done {
                                ForEach(section.items) { item in
                                    DownloadQueueRow(
                                        item: item,
                                        isSelected: selection.contains(item.id),
                                        queueIndex: queueIndex(for: item),
                                        queueCount: downloadItems.count,
                                        onRemove: { queue.remove(item) },
                                        onPause: { queue.pause(item) },
                                        onResume: { resume(item) },
                                        onRetry: { retry(item) },
                                        onStartNow: { startNow(item) },
                                        onMoveToFront: { moveToFront(item) },
                                        onShowInFinder: { showInFinder(item) },
                                        onShowSource: { showSource(item) },
                                        onCopyError: { copyError(item) },
                                        onDiagnose: { diagnosticItem = item },
                                        onToggleSelection: { toggleSelection(for: item) }
                                    )
                                    .transition(rowTransition)
                                }
                            }
                        } header: {
                            DownloadSectionHeader(
                                kind: section.kind,
                                count: section.items.count,
                                isCollapsed: section.kind == .done && !doneExpanded && statusFilter != .done,
                                toggle: {
                                    if section.kind == .done {
                                        doneExpanded.toggle()
                                    }
                                }
                            )
                        }
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, selection.isEmpty ? 18 : 76)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: visibleRowAnimationKey)
            }
        }
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .move(edge: .top).combined(with: .opacity),
            removal: .opacity
        )
    }

    private func clearFilters() {
        searchText = ""
        statusFilter = .all
    }

    private func pauseAll() {
        visibleItems
            .filter(canPause(_:))
            .forEach { queue.pause($0) }
    }

    private func resumeAll() {
        visibleItems
            .filter { $0.status == .paused }
            .forEach { resume($0) }
    }

    private func retryAllFailed() {
        visibleItems
            .filter { $0.canRetry }
            .forEach { retry($0) }
    }

    private func clearDone() {
        downloadItems
            .filter { $0.status == .completed }
            .forEach { queue.remove($0) }
    }

    private func clearFailed() {
        downloadItems
            .filter {
                if case .failed = $0.status { return true }
                return false
            }
            .forEach { queue.remove($0) }
    }

    private func canPause(_ item: DownloadQueueItem) -> Bool {
        switch item.status {
        case .pending, .downloading, .verifying, .uploading:
            return true
        case .processing, .paused, .completed, .failed:
            return false
        }
    }

    private func retry(_ item: DownloadQueueItem) {
        guard case .failed = item.status,
              let payload = item.retryPayload else { return }
        Task { @MainActor in
            guard ProFeatureGate.canDownloadAudio || !payload.resolution.isAudio else {
                onUpgradeRequired()
                return
            }
            guard await LicenseManager.shared.preflight() else {
                onUpgradeRequired()
                return
            }
            DownloadJobRunner.shared.startRetry(
                queueId: item.id,
                payload: payload,
                seedboxWebdavPassword: seedboxWebdavPassword
            )
        }
    }

    private func resume(_ item: DownloadQueueItem) {
        guard item.status == .paused,
              let payload = item.retryPayload else { return }
        guard ProFeatureGate.canDownloadAudio || !payload.resolution.isAudio else {
            onUpgradeRequired()
            return
        }
        DownloadJobRunner.shared.startResume(
            queueId: item.id,
            payload: payload,
            seedboxWebdavPassword: seedboxWebdavPassword
        )
    }

    private func toggleSelection(for item: DownloadQueueItem) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift),
           let lastSelectedID,
           let start = visibleItems.firstIndex(where: { $0.id == lastSelectedID }),
           let end = visibleItems.firstIndex(where: { $0.id == item.id }) {
            let range = min(start, end)...max(start, end)
            selection.formUnion(visibleItems[range].map(\.id))
        } else if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
        lastSelectedID = item.id
    }

    private func retrySelected() {
        selectedItems.filter(\.canRetry).forEach { retry($0) }
    }

    private func pauseSelected() {
        selectedItems
            .filter(canPause(_:))
            .forEach { queue.pause($0) }
    }

    private func resumeSelected() {
        selectedItems
            .filter { $0.status == .paused }
            .forEach { resume($0) }
    }

    private func removeSelected() {
        selectedItems.forEach { queue.remove($0) }
        selection.removeAll()
    }

    private func moveToFront(_ item: DownloadQueueItem) {
        while let idx = queue.queue.firstIndex(where: { $0.id == item.id }), idx > 0 {
            queue.moveUp(queue.queue[idx])
        }
    }

    private func startNow(_ item: DownloadQueueItem) {
        guard queue.startNow(item, seedboxWebdavPassword: seedboxWebdavPassword) else { return }
    }

    private func queueIndex(for item: DownloadQueueItem) -> Int? {
        downloadItems.firstIndex(where: { $0.id == item.id }).map { $0 + 1 }
    }

    private func showInFinder(_ item: DownloadQueueItem) {
        if let finalPath = item.finalPath {
            let url = URL(fileURLWithPath: finalPath)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return
            }
        }
        NSWorkspace.shared.open(DownloadPaths.downloadDir)
    }

    private func showSource(_ item: DownloadQueueItem) {
        appState.openFeedSource(for: item)
    }

    private func copyError(_ item: DownloadQueueItem) {
        if case .failed(let reason) = item.status {
            ClipboardManager.copy(reason.isEmpty ? item.statusMessage ?? "Download failed" : reason)
        }
    }
}

private struct DownloadsToolbar: View {
    @Binding var searchText: String
    @Binding var statusFilter: DownloadStatusFilter

    let visibleCount: Int
    let totalCount: Int
    let counts: DownloadStatusFilterCounts
    let searchFocused: FocusState<Bool>.Binding
    let pauseAll: () -> Void
    let resumeAll: () -> Void
    let retryAllFailed: () -> Void
    let clearDone: () -> Void
    let clearFailed: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchField
                statusChips
                Spacer(minLength: 10)
                actionMenu
                countBadge
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    searchField
                    Spacer(minLength: 10)
                    actionMenu
                    countBadge
                }
                statusChips
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(tint: Theme.electricLime.opacity(0.15), cornerRadius: 14)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField("Search title or source", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
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
        .overlay(Capsule().strokeBorder(Theme.electricLime.opacity(0.25), lineWidth: 0.5))
        .frame(maxWidth: 280)
    }

    private var statusChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(DownloadStatusFilter.allCases) { filter in
                    DownloadFilterChip(
                        title: filter.title,
                        count: counts.count(for: filter),
                        tint: filter.tint,
                        isSelected: statusFilter == filter
                    ) {
                        statusFilter = filter
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: 520)
    }

    private var actionMenu: some View {
        Menu {
            Button("Pause All", action: pauseAll)
            Button("Resume All", action: resumeAll)
            Divider()
            Button("Retry All Failed", action: retryAllFailed)
            Divider()
            Button("Clear Done", action: clearDone)
            Button("Clear Failed", role: .destructive, action: clearFailed)
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.accentDim.opacity(0.35), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.electricLime.opacity(0.22), lineWidth: 0.5))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var countBadge: some View {
        Text(visibleCount == totalCount ? "\(totalCount)" : "\(visibleCount) / \(totalCount)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.electricLime)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.electricLime.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.electricLime.opacity(0.25), lineWidth: 0.5))
    }
}

private struct DownloadFilterChip: View {
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

private struct DownloadSectionHeader: View {
    let kind: DownloadSectionKind
    let count: Int
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(kind.tint)
                        .frame(width: 7, height: 7)
                    Text(kind.title)
                        .font(.system(size: 11, weight: .bold))
                    Text("\(count)")
                        .font(.system(size: 9, weight: .black))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(kind.tint.opacity(0.18), in: Capsule())
                    if kind == .done {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundStyle(kind.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surface0.opacity(0.86), in: Capsule())
                .overlay(Capsule().strokeBorder(kind.tint.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(kind != .done)

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

private struct DownloadQueueRow: View {
    let item: DownloadQueueItem
    let isSelected: Bool
    let queueIndex: Int?
    let queueCount: Int
    let onRemove: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onRetry: () -> Void
    let onStartNow: () -> Void
    let onMoveToFront: () -> Void
    let onShowInFinder: () -> Void
    let onShowSource: () -> Void
    let onCopyError: () -> Void
    let onDiagnose: () -> Void
    let onToggleSelection: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        DownloadStatusFormatting.statusTint(item)
    }

    private var canStartNow: Bool {
        DownloadQueueManualStartPolicy.canStartNow(item, isPro: ProFeatureGate.isPro)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leadingRail
            statusIcon

            VStack(alignment: .leading, spacing: 7) {
                header
                chips
                DownloadPipelineBar(item: item)
                metricsLine
                if case .failed(let reason) = item.status {
                    failedMessage(reason)
                }
                actions
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(tint: tint.opacity(0.18), cornerRadius: 14)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(borderColor, lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                onToggleSelection()
            }
        }
        .contextMenu { contextMenu }
        .help(item.url)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .animation(reduceMotion ? nil : .default, value: item.status)
    }

    private var leadingRail: some View {
        Image(systemName: item.status.isTerminal ? "circle" : "line.3.horizontal")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(item.status.isTerminal ? Theme.textSecondary.opacity(0.35) : Theme.textSecondary)
            .frame(width: 18, height: 24)
            .help(queueIndex.map { "Queue position \($0) of \(queueCount)." } ?? "Queue item")
    }

    private var statusIcon: some View {
        Image(systemName: DownloadStatusFormatting.statusIcon(item))
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 24)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.displayTitle ?? item.filename)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            DownloadPrimaryMetric(item: item, queueIndex: queueIndex, queueCount: queueCount)
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            DownloadSourceChip(label: DownloadStatusFormatting.sourceLabel(for: item))
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
            DownloadDestinationChip(target: item.targetCloud)
            Text(item.quality)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.accentDim.opacity(0.28), in: Capsule())
            Spacer(minLength: 0)
        }
    }

    private var metricsLine: some View {
        let line = DownloadStatusFormatting.metricsLine(for: item)
        return Text(line)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func failedMessage(_ reason: String) -> some View {
        Text(reason.isEmpty ? item.statusMessage ?? "Download failed" : reason)
            .font(.system(size: 11))
            .foregroundStyle(Theme.error)
            .lineLimit(2)
            .truncationMode(.tail)
            .help(reason)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.error.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            switch item.status {
            case .pending:
                if canStartNow {
                    DownloadRowButton("Start Now", systemImage: "bolt.fill", tint: Theme.gold, isProminent: true, action: onStartNow)
                } else {
                    DownloadRowButton("Move Front", systemImage: "forward.fill", tint: Theme.lavender, action: onMoveToFront)
                }
                DownloadRowButton("Cancel", systemImage: "xmark", tint: Theme.textSecondary, action: onRemove)
            case .downloading, .verifying, .uploading:
                DownloadRowButton("Pause", systemImage: "pause.fill", tint: Theme.textSecondary, action: onPause)
                DownloadRowButton("Open Folder", systemImage: "folder", tint: Theme.textSecondary, action: onShowInFinder)
            case .processing:
                DownloadRowButton("Cancel", systemImage: "xmark", tint: Theme.textSecondary, action: onRemove)
                DownloadRowButton("Open Folder", systemImage: "folder", tint: Theme.textSecondary, action: onShowInFinder)
            case .paused:
                DownloadRowButton("Resume", systemImage: "play.fill", tint: Theme.electricLime, action: onResume)
                    .disabled(item.retryPayload == nil)
                DownloadRowButton("Open Folder", systemImage: "folder", tint: Theme.textSecondary, action: onShowInFinder)
            case .failed:
                DownloadRowButton("Retry", systemImage: "arrow.clockwise", tint: Theme.gold, isProminent: true, action: onRetry)
                    .disabled(item.retryPayload == nil)
                DownloadRowButton("Copy Error", systemImage: "doc.on.doc", tint: Theme.textSecondary, action: onCopyError)
                DownloadRowButton("Show Source", systemImage: "safari", tint: Theme.textSecondary, action: onShowSource)
                DownloadRowButton("Diagnose", systemImage: "stethoscope", tint: Theme.skyBlue, action: onDiagnose)
            case .completed:
                DownloadRowButton("Show in Finder", systemImage: "folder", tint: Theme.textSecondary, action: onShowInFinder)
                DownloadRowButton("Open Library", systemImage: "books.vertical", tint: Theme.skyBlue) {
                    AppStateManager.shared.select(.library)
                }
            }

            Spacer()
            DownloadRowButton("Remove", systemImage: "trash", tint: Theme.error, action: onRemove)
        }
    }

    private var borderColor: Color {
        if isSelected { return Theme.gold.opacity(0.85) }
        if case .failed = item.status { return Theme.error.opacity(0.45) }
        return .white.opacity(0.08)
    }

    @ViewBuilder
    private var contextMenu: some View {
        if item.canRetry {
            Button("Retry") { onRetry() }
        }
        if canStartNow {
            Button("Start Now") { onStartNow() }
        }
        Button("Show Source") { onShowSource() }
        Button("Show in Finder") { onShowInFinder() }
        if !item.status.isTerminal && item.status != .processing {
            Button("Move to Front") { onMoveToFront() }
        }
        Divider()
        Button("Remove", role: .destructive) { onRemove() }
    }

    private var accessibilityLabel: String {
        "\(item.displayTitle ?? item.filename), \(DownloadStatusFormatting.statusLabel(item)), \(Int(item.progress)) percent, source \(DownloadStatusFormatting.sourceLabel(for: item)), destination \(item.targetCloud.displayName)"
    }
}

private struct DownloadPrimaryMetric: View {
    let item: DownloadQueueItem
    let queueIndex: Int?
    let queueCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            if item.status == .verifying || (item.status == .processing && item.progress <= 0) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.62)
            }
            Text(metric)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(DownloadStatusFormatting.statusTint(item))
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: metric)
        }
    }

    private var metric: String {
        switch item.status {
        case .downloading:
            return DownloadStatusFormatting.eta(for: item) ?? String(format: "%.1f%%", item.progress)
        case .verifying:
            return "Verifying"
        case .uploading:
            return "cloud \(DownloadStatusFormatting.eta(for: item) ?? String(format: "%.1f%%", item.progress))"
        case .processing:
            return String(format: "%.1f%%", item.progress)
        case .completed:
            return "Done"
        case .failed:
            return "Failed at \(DownloadStatusFormatting.phaseLabel(for: item))"
        case .paused:
            return "Paused"
        case .pending:
            return queueIndex.map { "#\($0) of \(queueCount)" } ?? "Queued"
        }
    }
}

private struct DownloadSourceChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(DownloadProviderTint.color(for: label).opacity(0.85), in: Capsule())
    }
}

private struct DownloadDestinationChip: View {
    let target: CloudTarget

    var body: some View {
        Label(DownloadStatusFormatting.destinationLabel(for: target), systemImage: target.icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(destinationTint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(destinationTint.opacity(0.16), in: Capsule())
    }

    private var destinationTint: Color {
        switch target {
        case .local: return Theme.textSecondary
        case .mega: return Theme.success
        case .gdrive: return Theme.skyBlue
        case .seedbox: return Theme.lavender
        }
    }
}

private struct DownloadRowButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isProminent = false
    let action: () -> Void

    init(_ title: String, systemImage: String, tint: Color, isProminent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.isProminent = isProminent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isProminent ? Theme.surface0 : tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isProminent ? tint.opacity(0.9) : tint.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct DownloadPipelineBar: View {
    let item: DownloadQueueItem

    private var phases: [DownloadPipelinePhase] {
        if item.isProcessingJob {
            return [.process]
        }
        if item.targetCloud == .local {
            return [.download, .verify]
        }
        return [.download, .verify, .upload]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(phases) { phase in
                    DownloadPipelineSegment(
                        phase: phase,
                        fill: fill(for: phase),
                        isActive: activePhase == phase,
                        isIndeterminate: item.status == .verifying && phase == .verify,
                        tint: tint(for: phase)
                    )
                }
            }
            .frame(height: 7)

            HStack(spacing: 5) {
                ForEach(phases) { phase in
                    Text(phase.title)
                        .font(.system(size: 10, weight: activePhase == phase ? .bold : .medium))
                        .foregroundStyle(activePhase == phase ? tint(for: phase) : Theme.textSecondary.opacity(0.75))
                    if phase != phases.last {
                        Text("->")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textSecondary.opacity(0.55))
                    }
                }
            }
        }
    }

    private var activePhase: DownloadPipelinePhase? {
        switch item.status {
        case .processing:
            return .process
        case .downloading, .pending, .paused:
            return .download
        case .verifying:
            return .verify
        case .uploading:
            return .upload
        case .completed, .failed:
            return nil
        }
    }

    private func fill(for phase: DownloadPipelinePhase) -> Double {
        if item.isProcessingJob {
            switch item.status {
            case .processing:
                return phase == .process ? item.progress / 100 : 0
            case .completed:
                return 1
            case .failed:
                return phase == .process ? max(item.progress / 100, 0.08) : 0
            default:
                return 0
            }
        }
        switch item.status {
        case .pending:
            return 0
        case .downloading:
            return phase == .download ? item.progress / 100 : 0
        case .verifying:
            return phase == .download ? 1 : (phase == .verify ? 0.72 : 0)
        case .uploading:
            if phase == .download || phase == .verify { return 1 }
            return phase == .upload ? item.progress / 100 : 0
        case .processing:
            return 0
        case .completed:
            return 1
        case .paused:
            return phase == .download ? item.progress / 100 : 0
        case .failed:
            return phase == .download ? max(item.progress / 100, 0.08) : 0
        }
    }

    private func tint(for phase: DownloadPipelinePhase) -> Color {
        switch phase {
        case .download: return Theme.gold
        case .verify: return Theme.skyBlue
        case .upload: return Theme.electricLime
        case .process: return Theme.coral
        }
    }
}

private struct DownloadPipelineSegment: View {
    let phase: DownloadPipelinePhase
    let fill: Double
    let isActive: Bool
    let isIndeterminate: Bool
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.accentDim.opacity(0.18))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(tint.opacity(isActive ? 0.95 : 0.72))
                        .frame(width: max(0, geo.size.width * min(max(fill, 0), 1)))
                }
                .overlay {
                    if isIndeterminate && !reduceMotion {
                        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.42), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: geo.size.width * 0.42)
                            .offset(x: CGFloat(phase) * geo.size.width * 1.6 - geo.size.width * 0.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(tint.opacity(0.20), lineWidth: 0.5))
        }
    }
}

private struct DownloadSelectionBar: View {
    let count: Int
    let retryAction: () -> Void
    let pauseAction: () -> Void
    let resumeAction: () -> Void
    let removeAction: () -> Void
    let clearAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(count) selected")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            DownloadSelectionButton(title: "Retry", systemImage: "arrow.clockwise", tint: Theme.gold, action: retryAction)
            DownloadSelectionButton(title: "Pause", systemImage: "pause.fill", tint: Theme.textSecondary, action: pauseAction)
            DownloadSelectionButton(title: "Resume", systemImage: "play.fill", tint: Theme.electricLime, action: resumeAction)
            DownloadSelectionButton(title: "Remove", systemImage: "trash", tint: Theme.error, action: removeAction)
            DownloadSelectionButton(title: "Clear", systemImage: "xmark.circle", tint: Theme.textSecondary, action: clearAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard(tint: Theme.electricLime.opacity(0.18), cornerRadius: 14)
    }
}

private struct DownloadSelectionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
        }
        .buttonStyle(.borderless)
    }
}

private struct DownloadsEmptyState: View {
    let startAction: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(Theme.gold.opacity(0.5))
                .padding()
            Text("No downloads")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Button(action: startAction) {
                Label("Start a download", systemImage: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.gold, Theme.electricLime], startPoint: .leading, endPoint: .trailing)
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.accentDim, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.electricLime.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct DownloadsNoResultsState: View {
    let filter: DownloadStatusFilter
    let completedCount: Int
    let showDone: () -> Void
    let clearFilters: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .foregroundStyle(Theme.gold.opacity(0.5))
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                Button("Clear filters", action: clearFilters)
                    .buttonStyle(.borderless)
                if completedCount > 0 {
                    Button("Show Done", action: showDone)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var message: String {
        if filter == .active {
            return "No active downloads. \(completedCount) completed today."
        }
        return "No downloads match the current filter."
    }
}

private struct DownloadDiagnosticSheet: View {
    let item: DownloadQueueItem
    @ObservedObject private var appState = AppStateManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Download Diagnostics")
                        .font(.headline)
                    Spacer()
                    Button("Done") { dismiss() }
                }

                diagnosticRow("Title", item.displayTitle ?? item.filename)
                diagnosticRow("Source", item.url)
                diagnosticRow("Target", item.targetCloud.displayName)
                diagnosticRow("Stage", DownloadStatusFormatting.phaseLabel(for: item))
                diagnosticRow("Progress", String(format: "%.1f%%", item.progress))
                if let finalPath = item.finalPath {
                    diagnosticRow("Final Path", finalPath)
                }
                if case .failed(let reason) = item.status {
                    diagnosticRow("Error", reason.isEmpty ? item.statusMessage ?? "Failed" : reason)
                }

                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .frame(
            minWidth: 520,
            idealWidth: AppShellSurfaceMetrics.detailModalWidth(for: appState.windowSize),
            maxWidth: AppShellSurfaceMetrics.detailModalWidth(for: appState.windowSize),
            minHeight: 360,
            idealHeight: AppShellSurfaceMetrics.detailModalHeight(for: appState.windowSize),
            maxHeight: AppShellSurfaceMetrics.detailModalHeight(for: appState.windowSize)
        )
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}

private enum DownloadStatusFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case queued
    case paused
    case failed
    case done

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .queued: return "Queued"
        case .paused: return "Paused"
        case .failed: return "Failed"
        case .done: return "Done"
        }
    }

    var tint: Color {
        switch self {
        case .all: return Theme.electricLime
        case .active: return Theme.gold
        case .queued: return Theme.lavender
        case .paused: return Theme.textSecondary
        case .failed: return Theme.error
        case .done: return Theme.success
        }
    }

    func matches(_ item: DownloadQueueItem) -> Bool {
        switch self {
        case .all:
            return true
        case .active:
            return DownloadSectionKind.active.contains(item)
        case .queued:
            return DownloadSectionKind.queued.contains(item)
        case .paused:
            return DownloadSectionKind.paused.contains(item)
        case .failed:
            return DownloadSectionKind.failed.contains(item)
        case .done:
            return DownloadSectionKind.done.contains(item)
        }
    }
}

private struct DownloadStatusFilterCounts {
    let items: [DownloadQueueItem]

    func count(for filter: DownloadStatusFilter) -> Int {
        items.filter(filter.matches(_:)).count
    }
}

private enum DownloadSectionKind: String, CaseIterable, Identifiable {
    case active
    case queued
    case paused
    case failed
    case done

    var id: Self { self }

    var title: String {
        switch self {
        case .active: return "Active"
        case .queued: return "Queued"
        case .paused: return "Paused"
        case .failed: return "Failed"
        case .done: return "Done"
        }
    }

    var tint: Color {
        switch self {
        case .active: return Theme.gold
        case .queued: return Theme.lavender
        case .paused: return Theme.textSecondary
        case .failed: return Theme.error
        case .done: return Theme.success
        }
    }

    func contains(_ item: DownloadQueueItem) -> Bool {
        switch self {
        case .active:
            switch item.status {
            case .downloading, .verifying, .uploading, .processing:
                return true
            default:
                return false
            }
        case .queued:
            return item.status == .pending
        case .paused:
            return item.status == .paused
        case .failed:
            if case .failed = item.status { return true }
            return false
        case .done:
            return item.status == .completed
        }
    }
}

private struct DownloadQueueSection: Identifiable {
    let kind: DownloadSectionKind
    let items: [DownloadQueueItem]

    var id: DownloadSectionKind { kind }
}

private enum DownloadPipelinePhase: String, Identifiable {
    case download
    case verify
    case upload
    case process

    var id: Self { self }

    var title: String {
        switch self {
        case .download: return "Download"
        case .verify: return "Verify"
        case .upload: return "Upload"
        case .process: return "Process"
        }
    }
}

enum DownloadStatusFormatting {
    static func stageLabel(for item: DownloadQueueItem) -> String {
        statusLabel(item)
    }

    static func statusTint(_ item: DownloadQueueItem) -> Color {
        switch item.status {
        case .downloading: return Theme.gold
        case .verifying: return Theme.skyBlue
        case .uploading: return Theme.electricLime
        case .processing: return Theme.coral
        case .completed: return Theme.success
        case .paused: return Theme.textSecondary
        case .pending: return Theme.lavender
        case .failed: return Theme.error
        }
    }

    static func statusIcon(_ item: DownloadQueueItem) -> String {
        switch item.status {
        case .pending: return "clock.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .verifying: return "checkmark.shield.fill"
        case .uploading: return "arrow.up.circle.fill"
        case .processing: return "wand.and.stars"
        case .completed: return "checkmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    static func statusLabel(_ item: DownloadQueueItem) -> String {
        switch item.status {
        case .pending: return "Queued"
        case .downloading: return "Downloading"
        case .verifying: return "Verifying"
        case .uploading: return "Uploading"
        case .processing: return "Processing"
        case .completed: return "Completed"
        case .paused: return "Paused"
        case .failed: return "Failed"
        }
    }

    static func phaseLabel(for item: DownloadQueueItem) -> String {
        if item.isProcessingJob {
            switch item.status {
            case .completed:
                return "Done"
            default:
                return "Process"
            }
        }
        switch item.status {
        case .pending, .downloading, .paused:
            return "Download"
        case .verifying:
            return "Verify"
        case .uploading:
            return "Upload"
        case .processing:
            return "Process"
        case .completed:
            return "Done"
        case .failed:
            if item.uploadStarted == true { return "Upload" }
            if item.progress >= 95 { return "Verify" }
            return "Download"
        }
    }

    static func sourceLabel(for item: DownloadQueueItem) -> String {
        if item.isProcessingJob {
            return "Local File"
        }
        guard let host = URL(string: item.url)?.host?.replacingOccurrences(of: "www.", with: "") else {
            return item.quality
        }
        if host.contains("mega") { return "Mega" }
        if host.contains("drive") { return "Drive" }
        return host
    }

    static func destinationLabel(for target: CloudTarget) -> String {
        switch target {
        case .local: return "Local"
        case .mega: return "up Mega"
        case .gdrive: return "up Drive"
        case .seedbox: return "Seedbox"
        }
    }

    static func transferLocation(for item: DownloadQueueItem) -> String {
        if let finalPath = item.finalPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !finalPath.isEmpty {
            return finalPath
        }

        if item.isProcessingJob {
            return item.partialLocalPath ?? DownloadPaths.downloadDir.path
        }

        if item.targetCloud == .local {
            return item.partialLocalPath ?? DownloadPaths.downloadDir.path
        }

        guard let payload = item.retryPayload else {
            return destinationLabel(for: item.targetCloud)
        }

        switch item.targetCloud {
        case .local:
            return item.partialLocalPath ?? DownloadPaths.downloadDir.path
        case .mega:
            return payload.context.megaRemotePath
        case .gdrive:
            let base = payload.context.gdriveRemotePath
            return "\(payload.context.gdriveRemoteName):\(base)"
        case .seedbox:
            if payload.context.seedboxTransferMode == "webdav" {
                let path = payload.context.seedboxRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
                if path.isEmpty || path == "/" {
                    return payload.context.seedboxWebdavURL
                }
                return "\(payload.context.seedboxWebdavURL) \(path)"
            }
            let path = payload.context.seedboxRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty || path == "/" {
                return payload.context.seedboxRemoteName
            }
            return "\(payload.context.seedboxRemoteName):\(path)"
        }
    }

    static func failureMessage(for item: DownloadQueueItem) -> String? {
        if case .failed(let reason) = item.status {
            let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedReason.isEmpty {
                return trimmedReason
            }
        }

        let trimmedMessage = item.statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedMessage.isEmpty ? nil : trimmedMessage
    }

    static func homeDetailLine(for item: DownloadQueueItem) -> String {
        var parts: [String] = []

        let metrics = metricsLine(for: item)
        if !metrics.isEmpty {
            parts.append(metrics)
        }

        if case .failed = item.status,
           let failure = failureMessage(for: item),
           failure != item.statusMessage {
            parts.append(failure)
        }

        return parts.joined(separator: " · ")
    }

    static func searchText(for item: DownloadQueueItem) -> String {
        "\(item.displayTitle ?? "") \(item.filename) \(item.url) \(item.quality) \(sourceLabel(for: item)) \(item.targetCloud.displayName) \(item.statusMessage ?? "")".lowercased()
    }

    static func metricsLine(for item: DownloadQueueItem) -> String {
        var parts: [String] = []
        if let downloaded = item.bytesDownloaded,
           let total = item.totalBytes,
           total > 0 {
            parts.append("\(formatBytes(downloaded)) of \(formatBytes(total))")
        } else if let downloaded = item.bytesDownloaded {
            parts.append(formatBytes(downloaded))
        }
        if let rate = item.bytesPerSecond, rate > 0 {
            parts.append("\(formatBytes(Int64(rate)))/s")
        }
        if let eta = eta(for: item) {
            parts.append(eta)
        }
        parts.append(String(format: "%.1f%%", item.progress))
        if let message = item.statusMessage, !message.isEmpty {
            parts.append(message)
        }
        return parts.joined(separator: " · ")
    }

    static func eta(for item: DownloadQueueItem) -> String? {
        guard let downloaded = item.bytesDownloaded,
              let total = item.totalBytes,
              let rate = item.bytesPerSecond,
              total > downloaded,
              rate > 0 else {
            return nil
        }
        let seconds = Double(total - downloaded) / rate
        return "\(formatDuration(seconds)) left"
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(bytes)
        var index = 0
        while size >= 1024, index < units.count - 1 {
            size /= 1024
            index += 1
        }
        if index == 0 {
            return "\(Int(size)) \(units[index])"
        }
        return String(format: "%.1f %@", size, units[index])
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value < 60 {
            return "\(value)s"
        }
        if value < 3600 {
            return String(format: "%dm %02ds", value / 60, value % 60)
        }
        return String(format: "%dh %02dm", value / 3600, (value % 3600) / 60)
    }
}

private enum DownloadProviderTint {
    static func color(for label: String) -> Color {
        let lower = label.lowercased()
        if lower.contains("pornhub") { return Theme.coral }
        if lower.contains("streamtape") { return Theme.skyBlue }
        if lower.contains("pmvhaven") || lower.contains("video site") { return Theme.gold }
        if lower.contains("lulu") { return Theme.hotPink }
        if lower.contains("dood") || lower.contains("playmogo") { return Theme.taoRed }
        if lower.contains("vidara") { return Theme.electricLime }
        if lower.contains("seedbox") { return Theme.lavender }
        return Theme.textSecondary
    }
}
