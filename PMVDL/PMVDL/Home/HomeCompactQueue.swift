import AppKit
import SwiftUI

struct HomeQueueCounts: Equatable {
    let total: Int
    let remaining: Int
    let active: Int
    let queued: Int
    let paused: Int
    let completed: Int
    let failed: Int
    let activeEntry: Int
    let aggregateProgress: Double
    let activeProgress: Double

    init(items: [DownloadQueueItem]) {
        total = items.count
        activeEntry = items.filter { $0.status != .completed }.count
        active = items.filter { Self.isActive($0.status) }.count
        queued = items.filter { $0.status == .pending || $0.status == .waiting }.count
        paused = items.filter { $0.status == .paused }.count
        completed = items.filter { $0.status == .completed }.count
        failed = items.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
        remaining = active + queued + paused
        let unfinished = items.filter { $0.status != .completed }
        if unfinished.isEmpty {
            aggregateProgress = completed > 0 ? 1 : 0
        } else {
            aggregateProgress = unfinished.map { min(max($0.progress / 100, 0), 1) }.reduce(0, +) / Double(unfinished.count)
        }
        let activeItems = items.filter { Self.isActive($0.status) }
        if activeItems.isEmpty {
            activeProgress = 0
        } else {
            activeProgress = activeItems.map { min(max($0.progress / 100, 0), 1) }.reduce(0, +) / Double(activeItems.count)
        }
    }

    var summaryText: String {
        var pieces = [Self.countText(remaining, singular: "remaining", plural: "remaining")]
        if active > 0 {
            pieces.append(Self.countText(active, singular: "active", plural: "active"))
        }
        if queued > 0 {
            pieces.append(Self.countText(queued, singular: "queued", plural: "queued"))
        }
        if paused > 0 {
            pieces.append(Self.countText(paused, singular: "paused", plural: "paused"))
        }
        return pieces.joined(separator: " · ")
    }

    var queuedSummaryText: String {
        var pieces = [Self.countText(queued, singular: "queued", plural: "queued")]
        if paused > 0 {
            pieces.append(Self.countText(paused, singular: "paused", plural: "paused"))
        }
        if failed > 0 {
            pieces.append(Self.countText(failed, singular: "failed", plural: "failed"))
        }
        return pieces.joined(separator: " · ")
    }

    static func isActive(_ status: QueueStatus) -> Bool {
        switch status {
        case .downloading, .verifying, .uploading, .processing:
            return true
        case .pending, .waiting, .completed, .paused, .failed:
            return false
        }
    }

    private static func countText(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

enum HomeCompactQueueDisplayMode: Equatable {
    case activeQueue
    case queuedModal
    case completedSummary
    case activeModal
    case completedModal
}

struct HomeCompactQueue: View {
    @StateObject private var queue = DownloadQueue.shared
    @ObservedObject private var appState = AppStateManager.shared
    @State private var isExpanded = true
    @State private var showCompletedDetails = false
    @State private var showAllActive = false
    @State private var copiedSourceURLs = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let displayMode: HomeCompactQueueDisplayMode
    let seedboxWebdavPassword: String
    let onUpgradeRequired: () -> Void
    var onClose: (() -> Void)? = nil
    var isEmbedded = false
    private let activeVisibleLimit = 5

    private var items: [DownloadQueueItem] {
        queue.queue.filter(\.isVisibleInDownloads)
    }

    private var activeItems: [DownloadQueueItem] {
        items
            .filter { HomeQueueCounts.isActive($0.status) }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.createdAt < $1.createdAt
            }
    }

    private var queuedItems: [DownloadQueueItem] {
        items.filter {
            switch $0.status {
            case .pending, .waiting, .paused, .failed:
                return true
            case .downloading, .verifying, .uploading, .processing, .completed:
                return false
            }
        }
    }

    private var visibleActiveItems: [DownloadQueueItem] {
        isModal ? activeItems : (showAllActive ? activeItems : Array(activeItems.prefix(activeVisibleLimit)))
    }

    private var completedItems: [DownloadQueueItem] {
        items.filter { $0.status == .completed }
    }

    private var modalSourceURLs: [String] {
        let modalItems = displayMode == .completedModal ? completedItems : queuedItems
        return modalItems.compactMap(\.sourcePageURL).reduce(into: [String]()) { urls, url in
            if !urls.contains(url) {
                urls.append(url)
            }
        }
    }

    private var restartableItems: [DownloadQueueItem] {
        queuedItems.filter { $0.retryPayload != nil }
    }

    private var counts: HomeQueueCounts {
        HomeQueueCounts(items: items)
    }

    private var isModal: Bool {
        displayMode == .activeModal || displayMode == .queuedModal || displayMode == .completedModal
    }

    var body: some View {
        if !items.isEmpty {
            if isModal {
                modalContent
                    .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: items.map(\.id))
            } else if isEmbedded {
                content
                    .padding(12)
                    .background(Theme.surface0.opacity(0.42), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Theme.success.opacity(0.18), lineWidth: 1)
                    )
                    .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: isExpanded)
                    .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: showCompletedDetails)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: items.map(\.id))
            } else {
                content
                    .padding(14)
                    .glassCard(tint: cardTint, cornerRadius: HomeLayoutMetrics.cardCornerRadius)
                    .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: isExpanded)
                    .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: showCompletedDetails)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: items.map(\.id))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if displayMode == .completedSummary && activeItems.isEmpty {
            completedSummary
        } else {
            activeQueue
        }
    }

    private var cardTint: Color {
        (displayMode == .completedSummary || displayMode == .completedModal) && activeItems.isEmpty
            ? Theme.success.opacity(0.08)
            : Theme.electricLime.opacity(0.09)
    }

    private var modalContent: some View {
        VStack(spacing: 14) {
            modalHeader
            modalRows
            modalFooter
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var modalTitle: String {
        switch displayMode {
        case .completedModal:
            return "Completed Downloads"
        case .queuedModal:
            return "Queued Downloads"
        case .activeQueue, .completedSummary, .activeModal:
            return "Active Downloads"
        }
    }

    private var modalSubtitle: String {
        if displayMode == .completedModal {
            return completedItems.count == 1 ? "1 completed item ready for review." : "\(completedItems.count) completed items ready for review."
        }
        if displayMode == .queuedModal {
            return counts.queuedSummaryText
        }
        return activeItems.count == 1 ? "1 transfer in progress." : "\(activeItems.count) transfers in progress."
    }

    private var modalTint: Color {
        switch displayMode {
        case .completedModal:
            return Theme.success
        case .queuedModal:
            return Theme.warning
        case .activeQueue, .completedSummary, .activeModal:
            return Theme.skyBlue
        }
    }

    private var modalHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: displayMode == .completedModal ? "checkmark.circle.fill" : displayMode == .queuedModal ? "clock.fill" : "arrow.down.circle.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(modalTint)
                .frame(width: 42, height: 42)
                .background(modalTint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(modalTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(modalSubtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if displayMode == .activeModal {
                queueMetric(title: "Active", value: counts.active, tint: Theme.electricLime)
            } else if displayMode == .queuedModal {
                queueMetric(title: "Queued", value: counts.queued, tint: Theme.skyBlue)
                queueMetric(title: "Paused", value: counts.paused, tint: Theme.warning)
                if counts.failed > 0 {
                    queueMetric(title: "Failed", value: counts.failed, tint: Theme.error)
                }
            }

        }
        .padding(12)
        .background(Theme.surfaceGlass.opacity(0.46), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.borderSubtle, lineWidth: 1)
        )
    }

    private var modalRows: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if displayMode == .completedModal {
                    if completedItems.isEmpty {
                        modalEmptyState(title: "No completed downloads", icon: "checkmark.circle")
                    } else {
                        ForEach(completedItems) { item in
                            queueRow(item, isHistory: true)
                        }
                    }
                } else if displayMode == .queuedModal {
                    if queuedItems.isEmpty {
                        modalEmptyState(title: "No queued downloads", icon: "clock")
                    } else {
                        ForEach(queuedItems) { item in
                            queueRow(item)
                        }
                    }
                } else if activeItems.isEmpty {
                    modalEmptyState(title: "No active downloads", icon: "arrow.down.circle")
                } else {
                    ForEach(activeItems) { item in
                        queueRow(item)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 8)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.surface0.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Theme.borderSubtle.opacity(0.75), lineWidth: 0.8)
        )
        .scrollIndicators(.visible)
    }

    private func modalEmptyState(title: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(modalTint)
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(Theme.surface0.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.borderSubtle, lineWidth: 1)
        )
    }

    private var modalFooter: some View {
        HStack(spacing: 12) {
            if displayMode == .completedModal {
                Button {
                    AppStateManager.shared.select(.library)
                    closeModal()
                } label: {
                    Label("Open Library", systemImage: "books.vertical.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Theme.success)

                Spacer(minLength: 8)

                copyURLsButton

                Button("Clear All") {
                    clearCompleted()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(completedItems.isEmpty)
            } else {
                HomeQueueProgressBar(progress: displayMode == .queuedModal ? 0 : counts.activeProgress, tint: modalTint, height: 7)
                    .frame(maxWidth: 320)

                Text(displayMode == .queuedModal ? counts.queuedSummaryText : modalSubtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)

                Spacer(minLength: 8)

                if displayMode == .queuedModal {
                    copyURLsButton

                    if counts.queued > 0 {
                        Button {
                            queue.pauseQueued()
                        } label: {
                            Label("Pause All", systemImage: "pause.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Theme.warning)
                    }
                }

                if !restartableItems.isEmpty {
                    Button {
                        resumeAll()
                    } label: {
                        Label("Start All", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(modalTint)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surface0.opacity(0.48), in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(Theme.borderSubtle, lineWidth: 1)
        )
    }

    private var copyURLsButton: some View {
        Button {
            ClipboardManager.copy(modalSourceURLs.joined(separator: "\n"))
            copiedSourceURLs = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                copiedSourceURLs = false
            }
        } label: {
            Label(copiedSourceURLs ? "Copied" : "Copy URLs", systemImage: copiedSourceURLs ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(modalSourceURLs.isEmpty)
        .help("Copy original video page URLs")
    }

    private func closeModal() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private var activeQueue: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(visibleActiveItems) { item in
                        queueRow(item)
                    }

                    if activeItems.count > activeVisibleLimit {
                        activeOverflowButton
                    }

                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var completedSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.success)
                    .frame(width: 36, height: 36)
                    .background(Theme.success.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Downloads Complete")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(completedItems.count == 1 ? "1 completed" : "\(completedItems.count) completed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer(minLength: 12)

                Button {
                    AppStateManager.shared.select(.library)
                } label: {
                    Label("Open Library", systemImage: "books.vertical.fill")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Theme.success)

                Button(showCompletedDetails ? "Hide Details" : "Show Details") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        showCompletedDetails.toggle()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.textSecondary)

                Button("Clear All") {
                    clearCompleted()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.success)
                .help("Clear completed downloads")
            }

            if showCompletedDetails {
                VStack(spacing: 8) {
                    ForEach(completedItems) { item in
                        queueRow(item, isHistory: true)
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func queueRow(_ item: DownloadQueueItem, isHistory: Bool = false) -> some View {
        if displayMode == .completedModal {
            HomeCompletedQueueRow(
                item: item,
                openLibrary: { openLibrary(item) },
                showInFinder: { showInFinder(item) },
                showSource: { showSource(item) },
                remove: { queue.remove(item) }
            )
        } else {
            HomeCompactQueueRow(
                item: item,
                isHistory: isHistory,
                isModalPresentation: isModal,
                pause: { queue.pause(item) },
                resume: { resume(item) },
                retry: { retry(item) },
                startNow: { startNow(item) },
                remove: { queue.remove(item) },
                moveToFront: { moveToFront(item) },
                showInFinder: { showInFinder(item) },
                showSource: { showSource(item) },
                copyError: { copyError(item) },
                onUpgradeRequired: onUpgradeRequired
            )
            .equatable()
        }
    }

    private func openLibrary(_ item: DownloadQueueItem) {
        let sourceURLs = [
            item.retryPayload?.resolution.result.url,
            item.url
        ].compactMap { $0 }
        if let libraryItem = VideoLibrary.shared.items.first(where: { sourceURLs.contains($0.url) }) {
            appState.pendingLibraryItemID = libraryItem.id
        }
        appState.select(.library)
        closeModal()
    }

    private var activeOverflowButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                showAllActive.toggle()
            }
        } label: {
            Text(showAllActive ? "Show fewer active downloads" : "Show all \(activeItems.count) active downloads")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.electricLime)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    toggleExpanded()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.electricLime)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 7) {
                                Text("Active Downloads")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Theme.textPrimary)

                                Text("\(activeItems.count)")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(Theme.surface0)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.electricLime, in: Capsule())
                                    .contentTransition(.numericText())
                            }

                            Text(activeItems.count == 1 ? "1 transfer in progress" : "\(activeItems.count) transfers in progress")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(isExpanded ? "Collapse downloads" : "Expand downloads"))

                Spacer(minLength: 8)

                queueMetric(title: "Active", value: counts.active, tint: Theme.electricLime)
                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(isExpanded ? "Collapse downloads" : "Expand downloads"))
            }

            HomeQueueProgressBar(progress: counts.activeProgress, tint: Theme.electricLime, height: 5)
                .accessibilityLabel(Text("Overall download progress"))
        }
    }

    private func queueMetric(title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 13, weight: .black, design: .rounded))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
        }
        .frame(minWidth: 42, alignment: .trailing)
    }

    private var completedHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.success)

            Text(completedItems.count == 1 ? "1 completed" : "\(completedItems.count) completed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)

            Spacer()

            Button("Clear All") {
                clearCompleted()
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.success)
            .help("Clear completed downloads")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func clearCompleted() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            completedItems.forEach { queue.remove($0) }
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

    private func resumeAll() {
        var blockedByPro = false
        for item in restartableItems {
            guard let payload = item.retryPayload else { continue }
            guard ProFeatureGate.canDownloadAudio || !payload.resolution.isAudio else {
                blockedByPro = true
                continue
            }
            switch item.status {
            case .failed:
                DownloadJobRunner.shared.startRetry(
                    queueId: item.id,
                    payload: payload,
                    seedboxWebdavPassword: seedboxWebdavPassword
                )
            case .paused:
                DownloadJobRunner.shared.startResume(
                    queueId: item.id,
                    payload: payload,
                    seedboxWebdavPassword: seedboxWebdavPassword
                )
            case .pending:
                DownloadJobRunner.shared.startQueuedWithFreshSource(
                    queueId: item.id,
                    payload: payload,
                    seedboxWebdavPassword: seedboxWebdavPassword
                )
            case .waiting, .downloading, .verifying, .uploading, .processing, .completed:
                continue
            }
        }
        if blockedByPro {
            onUpgradeRequired()
        }
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.78)) {
            isExpanded.toggle()
        }
    }

    private func retry(_ item: DownloadQueueItem) {
        if item.itemKind == .extraction {
            appState.pendingExtractShouldStart = true
            appState.pendingExtractURL = item.url
            appState.select(.home)
            queue.remove(item)
            closeModal()
            return
        }
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

    private func moveToFront(_ item: DownloadQueueItem) {
        while let idx = queue.queue.firstIndex(where: { $0.id == item.id }), idx > 0 {
            queue.moveUp(queue.queue[idx])
        }
    }

    private func startNow(_ item: DownloadQueueItem) {
        guard queue.startNow(item, seedboxWebdavPassword: seedboxWebdavPassword) else { return }
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
        if appState.pendingFeedNavigation != nil {
            closeModal()
        }
    }

    private func copyError(_ item: DownloadQueueItem) {
        if case .failed(let reason) = item.status {
            ClipboardManager.copy(reason.isEmpty ? item.statusMessage ?? "Download failed" : reason)
        }
    }

}
