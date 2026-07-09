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

    init(items: [DownloadQueueItem]) {
        total = items.count
        activeEntry = items.filter { $0.status != .completed }.count
        active = items.filter { Self.isActive($0.status) }.count
        queued = items.filter { $0.status == .pending }.count
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

    private static func isActive(_ status: QueueStatus) -> Bool {
        switch status {
        case .downloading, .verifying, .uploading, .processing:
            return true
        case .pending, .completed, .paused, .failed:
            return false
        }
    }

    private static func countText(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

enum HomeCompactQueueDisplayMode: Equatable {
    case activeQueue
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
        items.filter { $0.status != .completed }
    }

    private var visibleActiveItems: [DownloadQueueItem] {
        isModal ? activeItems : (showAllActive ? activeItems : Array(activeItems.prefix(activeVisibleLimit)))
    }

    private var completedItems: [DownloadQueueItem] {
        items.filter { $0.status == .completed }
    }

    private var resumableItems: [DownloadQueueItem] {
        activeItems.filter { $0.status == .paused && $0.retryPayload != nil }
    }

    private var counts: HomeQueueCounts {
        HomeQueueCounts(items: items)
    }

    private var isModal: Bool {
        displayMode == .activeModal || displayMode == .completedModal
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
        displayMode == .completedModal ? "Completed Downloads" : "Active Downloads"
    }

    private var modalSubtitle: String {
        if displayMode == .completedModal {
            return completedItems.count == 1 ? "1 completed item ready for review." : "\(completedItems.count) completed items ready for review."
        }
        return counts.summaryText
    }

    private var modalTint: Color {
        displayMode == .completedModal ? Theme.success : Theme.skyBlue
    }

    private var modalHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: displayMode == .completedModal ? "checkmark.circle.fill" : "arrow.down.circle.fill")
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
                queueMetric(title: "Queued", value: counts.queued, tint: Theme.skyBlue)
                queueMetric(title: "Paused", value: counts.paused, tint: Theme.warning)
                if counts.failed > 0 {
                    queueMetric(title: "Failed", value: counts.failed, tint: Theme.error)
                }
            }

            Button(action: closeModal) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Theme.surface2.opacity(0.72), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
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

                Button("Clear All") {
                    clearCompleted()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(completedItems.isEmpty)
            } else {
                HomeQueueProgressBar(progress: counts.aggregateProgress, tint: Theme.electricLime, height: 7)
                    .frame(maxWidth: 320)

                Text(counts.summaryText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)

                Spacer(minLength: 8)

                if counts.paused > 0 {
                    Button {
                        resumeAll()
                    } label: {
                        Label("Resume All", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Theme.electricLime)
                    .disabled(resumableItems.isEmpty)
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

                    if !completedItems.isEmpty {
                        completedHeader

                        ForEach(completedItems) { item in
                            queueRow(item)
                        }
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

    private func queueRow(_ item: DownloadQueueItem, isHistory: Bool = false) -> some View {
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

                                Text("\(items.count)")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(Theme.surface0)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.electricLime, in: Capsule())
                                    .contentTransition(.numericText())
                            }

                            Text(counts.summaryText)
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
                queueMetric(title: "Queued", value: counts.queued, tint: Theme.skyBlue)
                if counts.failed > 0 {
                    queueMetric(title: "Failed", value: counts.failed, tint: Theme.error)
                }

                if counts.paused > 0 {
                    Button {
                        resumeAll()
                    } label: {
                        Label("Resume All", systemImage: "play.fill")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Theme.electricLime)
                    .disabled(resumableItems.isEmpty)
                    .help(resumableItems.isEmpty ? "Paused downloads cannot be resumed" : "Resume all paused downloads")
                }

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

            HomeQueueProgressBar(progress: counts.aggregateProgress, tint: Theme.electricLime, height: 5)
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
        for item in resumableItems {
            guard let payload = item.retryPayload else { continue }
            guard ProFeatureGate.canDownloadAudio || !payload.resolution.isAudio else {
                blockedByPro = true
                continue
            }
            DownloadJobRunner.shared.startResume(
                queueId: item.id,
                payload: payload,
                seedboxWebdavPassword: seedboxWebdavPassword
            )
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
        guard let url = URL(string: item.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyError(_ item: DownloadQueueItem) {
        if case .failed(let reason) = item.status {
            ClipboardManager.copy(reason.isEmpty ? item.statusMessage ?? "Download failed" : reason)
        }
    }

}

private struct HomeCompactQueueRow: View, Equatable {
    let item: DownloadQueueItem
    let isHistory: Bool
    let isModalPresentation: Bool
    let pause: () -> Void
    let resume: () -> Void
    let retry: () -> Void
    let startNow: () -> Void
    let remove: () -> Void
    let moveToFront: () -> Void
    let showInFinder: () -> Void
    let showSource: () -> Void
    let copyError: () -> Void
    let onUpgradeRequired: () -> Void

    static func == (lhs: HomeCompactQueueRow, rhs: HomeCompactQueueRow) -> Bool {
        lhs.item == rhs.item && lhs.isHistory == rhs.isHistory && lhs.isModalPresentation == rhs.isModalPresentation
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var tint: Color {
        if isHistory && item.status == .completed {
            return Theme.success
        }
        return DownloadStatusFormatting.statusTint(item)
    }

    private var details: HomeQueueRowDetails {
        HomeQueueRowDetails(item: item)
    }

    private var canStartNow: Bool {
        DownloadQueueManualStartPolicy.canStartNow(item, isPro: ProFeatureGate.isPro)
    }

    private var rowCornerRadius: CGFloat {
        isModalPresentation ? 14 : 8
    }

    private var thumbnailSize: CGSize {
        isModalPresentation ? CGSize(width: 82, height: 58) : CGSize(width: 56, height: 38)
    }

    private var titleFontSize: CGFloat {
        isModalPresentation ? 14 : 13
    }

    private var bodySpacing: CGFloat {
        isModalPresentation ? 8 : 5
    }

    private var progressHeight: CGFloat {
        if isModalPresentation { return isHistory ? 5 : 6 }
        return isHistory ? 3 : 4
    }

    var body: some View {
        VStack(spacing: isModalPresentation ? 12 : 8) {
            HStack(spacing: isModalPresentation ? 14 : 10) {
                HomeCompactQueueThumbnail(item: item, tint: tint, size: thumbnailSize)

                VStack(alignment: .leading, spacing: bodySpacing) {
                    Text(item.displayTitle ?? item.filename)
                        .font(.system(size: titleFontSize, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: 6) {
                        HomeCompactQueueStageChip(title: details.stage, tint: tint)

                        Text(details.location)
                            .font(.system(size: isModalPresentation ? 11 : 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let failure = details.failureMessage {
                        Text(failure)
                            .font(.system(size: isModalPresentation ? 11 : 10, weight: .semibold))
                            .foregroundStyle(Theme.error)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    } else if !details.detailLine.isEmpty {
                        Text(details.detailLine)
                            .font(.system(size: isModalPresentation ? 11 : 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                Text(String(format: "%.1f%%", item.progress))
                    .font(.system(size: isModalPresentation ? 13 : 12, weight: .black, design: .monospaced))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .frame(width: isModalPresentation ? 68 : 58, alignment: .trailing)

                HStack(spacing: isModalPresentation ? 8 : 6) {
                    primaryActionButton

                    HomeCompactQueueIconButton(
                        systemName: "xmark",
                        tint: Theme.textSecondary,
                        help: "Remove",
                        size: isModalPresentation ? 30 : 24,
                        action: remove
                    )
                }
                .opacity(rowControlOpacity)
            }

            HomeQueueProgressBar(progress: min(max(item.progress / 100, 0), 1), tint: progressTint, height: progressHeight)
        }
        .padding(.horizontal, isModalPresentation ? 16 : 10)
        .padding(.vertical, isModalPresentation ? 14 : 9)
        .background(rowBackground)
        .overlay(rowBorder)
        .shadow(color: .black.opacity(isModalPresentation ? 0.26 : 0), radius: isModalPresentation ? 10 : 0, x: 0, y: isModalPresentation ? 5 : 0)
        .help(details.helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .contextMenu { contextMenu }
        .onHover { isHovered = $0 }
    }

    private var rowControlOpacity: Double {
        if isHovered || isFailed || item.status == .paused { return 1 }
        if item.status == .completed { return isHistory ? 0.78 : 0.88 }
        return 0.94
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch item.status {
        case .failed:
            HomeCompactQueueIconButton(
                systemName: "arrow.clockwise",
                tint: Theme.error,
                help: "Retry",
                isDisabled: item.retryPayload == nil,
                size: isModalPresentation ? 30 : 24,
                action: retry
            )
        case .paused:
            HomeCompactQueueIconButton(
                systemName: "play.fill",
                tint: Theme.electricLime,
                help: "Resume",
                isDisabled: item.retryPayload == nil,
                size: isModalPresentation ? 30 : 24,
                action: resume
            )
        case .pending, .downloading, .verifying, .uploading:
            HomeCompactQueueIconButton(
                systemName: "pause.fill",
                tint: Theme.textSecondary,
                help: "Pause",
                size: isModalPresentation ? 30 : 24,
                action: pause
            )
        case .processing, .completed:
            Color.clear
                .frame(width: isModalPresentation ? 30 : 24, height: isModalPresentation ? 30 : 24)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if item.canRetry {
            Button("Retry") { retry() }
        }
        if canStartNow {
            Button("Start Now") { startNow() }
        }
        Button("Show Source") { showSource() }
        Button("Show in Finder") { showInFinder() }
        if !item.status.isTerminal && item.status != .processing {
            Button("Move to Front") { moveToFront() }
        }
        if case .failed = item.status {
            Button("Copy Error") { copyError() }
        }
        Divider()
        Button("Remove", role: .destructive) { remove() }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: rowCornerRadius)
            .fill(isHistory ? Theme.surface1.opacity(isModalPresentation ? 0.40 : 0.20) : Theme.surface1.opacity(isModalPresentation ? 0.46 : 0.30))
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: rowCornerRadius)
            .stroke(borderTint, lineWidth: isModalPresentation ? 1 : (isFailed ? 1 : 0.5))
    }

    private var borderTint: Color {
        if isFailed {
            return Theme.error.opacity(0.55)
        }
        return tint.opacity(isModalPresentation ? (isHistory ? 0.24 : 0.28) : (isHistory ? 0.11 : 0.16))
    }

    private var progressTint: Color {
        if isHistory && item.status == .completed {
            return Theme.success
        }
        return isFailed ? Theme.error : tint
    }

    private var isFailed: Bool {
        if case .failed = item.status { return true }
        return false
    }

    private var accessibilityLabel: String {
        details.accessibilityLabel
    }
}

private struct HomeQueueRowDetails: Equatable {
    let stage: String
    let location: String
    let detailLine: String
    let failureMessage: String?
    let helpText: String
    let accessibilityLabel: String

    init(item: DownloadQueueItem) {
        stage = DownloadStatusFormatting.stageLabel(for: item)
        location = DownloadStatusFormatting.transferLocation(for: item)
        detailLine = DownloadStatusFormatting.homeDetailLine(for: item)
        failureMessage = DownloadStatusFormatting.failureMessage(for: item)

        var helpParts = [stage, location]
        if !detailLine.isEmpty {
            helpParts.append(detailLine)
        }
        if let failureMessage, !helpParts.contains(failureMessage) {
            helpParts.append(failureMessage)
        }
        helpText = helpParts.joined(separator: "\n")

        var accessibilityParts = [
            item.displayTitle ?? item.filename,
            stage,
            location,
            "\(Int(item.progress)) percent"
        ]
        if !detailLine.isEmpty {
            accessibilityParts.append(detailLine)
        }
        if let failureMessage, !accessibilityParts.contains(failureMessage) {
            accessibilityParts.append(failureMessage)
        }
        accessibilityLabel = accessibilityParts.joined(separator: ", ")
    }
}

private struct HomeCompactQueueStageChip: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.2), lineWidth: 0.5))
    }
}

private struct HomeCompactQueueThumbnail: View {
    let item: DownloadQueueItem
    let tint: Color
    let size: CGSize

    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var didFail = false

    private var resolution: DownloadResolution? {
        item.retryPayload?.resolution
    }

    private var thumbnailURL: String? {
        guard let value = resolution?.source.thumbnail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if URL(string: value)?.scheme != nil { return value }
        guard let base = thumbnailReferer.flatMap(URL.init(string:)) else { return nil }
        return URL(string: value, relativeTo: base)?.absoluteString
    }

    private var requestHeaders: [String: String]? {
        if let headers = resolution?.headers { return headers }
        guard let resolution else { return nil }
        return resolution.source.headers(forQualityURL: resolution.finalUrl)
    }

    private var thumbnailReferer: String? {
        headerValue("Referer")
            ?? resolution?.sourcePageUrl
            ?? resolution?.result.url
            ?? resolution?.source.hls.first?.sourcePageUrl
    }

    private var remoteFrameURL: String? {
        let candidates = [
            resolution?.finalUrl,
            resolution?.requestedUrl,
            item.url,
            resolution?.source.mp4,
            resolution?.source.hls.first(where: { $0.kind == .direct })?.url
        ]
        return candidates.compactMap { value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  !url.absoluteString.localizedCaseInsensitiveContains(".m3u8") else { return nil }
            return value
        }.first
    }

    private var localFinalPath: String? {
        guard let finalPath = item.finalPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !finalPath.isEmpty,
              finalPath.hasPrefix("/"),
              FileManager.default.fileExists(atPath: finalPath) else { return nil }
        return finalPath
    }

    private var loadIdentity: String {
        [
            item.id.uuidString,
            thumbnailURL ?? "",
            remoteFrameURL ?? "",
            localFinalPath ?? ""
        ].joined(separator: "|")
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            thumbnailSurface
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: size.height > 40 ? 8 : 6))

            Image(systemName: DownloadStatusFormatting.statusIcon(item))
                .font(.system(size: size.height > 40 ? 10 : 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(size.height > 40 ? 3 : 2)
                .background(tint.opacity(0.85), in: Circle())
                .offset(x: 4, y: 4)
        }
        .task(id: loadIdentity) {
            await load()
        }
    }

    @ViewBuilder
    private var thumbnailSurface: some View {
        ZStack {
            Rectangle()
                .fill(Theme.surface1)

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if isLoading && !didFail {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint.opacity(0.58))
            }
        }
    }

    private func load() async {
        await MainActor.run {
            image = nil
            didFail = false
            isLoading = true
        }

        let loaded = await resolveImage()

        await MainActor.run {
            image = loaded
            didFail = loaded == nil
            isLoading = false
        }
    }

    private func resolveImage() async -> NSImage? {
        if let thumbnailURL {
            if let cached = await ThumbnailCache.shared.cachedImage(forIdentity: thumbnailURL) {
                return cached
            }

            do {
                return try await ThumbnailCache.downloadAndCacheImage(
                    fromImageURL: thumbnailURL,
                    cacheIdentity: thumbnailURL,
                    referer: thumbnailReferer
                )
            } catch {}
        }

        for identity in cacheIdentities where identity != thumbnailURL {
            if let cached = await ThumbnailCache.shared.cachedImage(forIdentity: identity) {
                return cached
            }
        }

        if let localFinalPath {
            let identity = remoteFrameURL ?? item.url
            if let generated = await ThumbnailCache.generateAndCacheImage(fromLocalFile: localFinalPath, forRemoteUrl: identity) {
                return generated
            }
        }

        if let remoteFrameURL {
            do {
                return try await ThumbnailCache.generateAndCache(
                    fromRemoteURL: remoteFrameURL,
                    headers: requestHeaders
                )
            } catch {}
        }

        return nil
    }

    private var cacheIdentities: [String] {
        var values: [String] = []
        func append(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  !values.contains(value) else { return }
            values.append(value)
        }

        append(thumbnailURL)
        append(remoteFrameURL)
        append(resolution?.requestedUrl)
        append(item.url)
        append(localFinalPath)
        if let localFinalPath {
            append(URL(fileURLWithPath: localFinalPath).absoluteString)
        }
        return values
    }

    private func headerValue(_ name: String) -> String? {
        requestHeaders?.first { field, _ in
            field.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

private struct HomeQueueProgressBar: View {
    let progress: Double
    let tint: Color
    var height: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Theme.surface2.opacity(0.38))

                RoundedRectangle(cornerRadius: height / 2)
                    .fill(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.68)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

private struct HomeCompactQueueIconButton: View {
    let systemName: String
    let tint: Color
    let help: String
    var isDisabled = false
    var size: CGFloat = 24
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size > 24 ? 11 : 10, weight: .bold))
                .foregroundStyle(isDisabled ? Theme.textSecondary.opacity(0.45) : tint)
                .frame(width: size, height: size)
                .background(tint.opacity(isDisabled ? 0.04 : 0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}
