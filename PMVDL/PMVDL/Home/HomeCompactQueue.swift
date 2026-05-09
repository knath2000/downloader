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

    init(items: [DownloadQueueItem]) {
        total = items.count
        active = items.filter { Self.isActive($0.status) }.count
        queued = items.filter { $0.status == .pending }.count
        paused = items.filter { $0.status == .paused }.count
        completed = items.filter { $0.status == .completed }.count
        failed = items.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
        remaining = active + queued + paused
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

struct HomeCompactQueue: View {
    @StateObject private var queue = DownloadQueue.shared
    @State private var isExpanded = true
    @State private var showAllActive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let seedboxWebdavPassword: String
    let onUpgradeRequired: () -> Void
    private let activeVisibleLimit = 5

    private var items: [DownloadQueueItem] {
        queue.queue.filter(\.isVisibleInDownloads)
    }

    private var activeItems: [DownloadQueueItem] {
        items.filter { $0.status != .completed }
    }

    private var visibleActiveItems: [DownloadQueueItem] {
        showAllActive ? activeItems : Array(activeItems.prefix(activeVisibleLimit))
    }

    private var completedItems: [DownloadQueueItem] {
        items.filter { $0.status == .completed }
    }

    private var counts: HomeQueueCounts {
        HomeQueueCounts(items: items)
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header

                if isExpanded {
                    VStack(spacing: 6) {
                        ForEach(visibleActiveItems) { item in
                            HomeCompactQueueRow(
                                item: item,
                                pause: { queue.pause(item) },
                                resume: { resume(item) },
                                retry: { retry(item) },
                                remove: { queue.remove(item) },
                                moveToFront: { moveToFront(item) },
                                showInFinder: { showInFinder(item) },
                                showSource: { showSource(item) },
                                copyError: { copyError(item) },
                                process: { process(item, preset: $0) },
                                onUpgradeRequired: onUpgradeRequired
                            )
                        }

                        if activeItems.count > activeVisibleLimit {
                            activeOverflowButton
                        }

                        if !completedItems.isEmpty {
                            completedHeader

                            ForEach(completedItems) { item in
                                HomeCompactQueueRow(
                                    item: item,
                                    pause: {},
                                    resume: {},
                                    retry: {},
                                    remove: { queue.remove(item) },
                                    moveToFront: { moveToFront(item) },
                                    showInFinder: { showInFinder(item) },
                                    showSource: { showSource(item) },
                                    copyError: { copyError(item) },
                                    process: { process(item, preset: $0) },
                                    onUpgradeRequired: onUpgradeRequired
                                )
                            }
                        }
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(12)
            .glassCard(tint: Theme.electricLime.opacity(0.08), cornerRadius: HomeLayoutMetrics.cardCornerRadius)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: isExpanded)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: items.map(\.id))
        }
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
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.78)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.electricLime)

                Text("Downloads")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)

                Text("\(items.count)")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Theme.surface0)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.electricLime, in: Capsule())
                    .contentTransition(.numericText())

                Text(counts.summaryText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isExpanded ? "Collapse downloads" : "Expand downloads"))
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
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    completedItems.forEach { queue.remove($0) }
                }
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.success)
            .help("Clear completed downloads")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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

    private func process(_ item: DownloadQueueItem, preset: VideoProcessingPreset) {
        VideoProcessingLauncher.run(
            preset: preset,
            inputPath: item.finalPath,
            displayName: item.displayTitle ?? item.filename,
            onUpgradeRequired: onUpgradeRequired
        )
    }
}

private struct HomeCompactQueueRow: View {
    let item: DownloadQueueItem
    let pause: () -> Void
    let resume: () -> Void
    let retry: () -> Void
    let remove: () -> Void
    let moveToFront: () -> Void
    let showInFinder: () -> Void
    let showSource: () -> Void
    let copyError: () -> Void
    let process: (VideoProcessingPreset) -> Void
    let onUpgradeRequired: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        DownloadStatusFormatting.statusTint(item)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                HomeCompactQueueThumbnail(item: item, tint: tint)

                Text(item.displayTitle ?? item.filename)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Text(String(format: "%.1f%%", item.progress))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .frame(width: 52, alignment: .trailing)

                primaryActionButton

                HomeCompactQueueIconButton(
                    systemName: "xmark",
                    tint: Theme.textSecondary,
                    help: "Remove",
                    action: remove
                )
            }

            GradientProgressBar(progress: min(max(item.progress / 100, 0), 1), height: 4, isAnimated: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(rowBackground)
        .overlay(rowBorder)
        .help(DownloadStatusFormatting.metricsLine(for: item))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
        .contextMenu { contextMenu }
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
                action: retry
            )
        case .paused:
            HomeCompactQueueIconButton(
                systemName: "play.fill",
                tint: Theme.electricLime,
                help: "Resume",
                isDisabled: item.retryPayload == nil,
                action: resume
            )
        case .pending, .downloading, .verifying, .uploading:
            HomeCompactQueueIconButton(
                systemName: "pause.fill",
                tint: Theme.textSecondary,
                help: "Pause",
                action: pause
            )
        case .processing, .completed:
            Color.clear
                .frame(width: 24, height: 24)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if item.canRetry {
            Button("Retry") { retry() }
        }
        Button("Show Source") { showSource() }
        Button("Show in Finder") { showInFinder() }
        if item.status == .completed {
            VideoProcessingMenuItems(process: process)
        }
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
        RoundedRectangle(cornerRadius: 8)
            .fill(Theme.surface1.opacity(0.28))
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(borderTint, lineWidth: isFailed ? 1 : 0.5)
    }

    private var borderTint: Color {
        isFailed ? Theme.error.opacity(0.55) : tint.opacity(0.16)
    }

    private var isFailed: Bool {
        if case .failed = item.status { return true }
        return false
    }

    private var accessibilityLabel: String {
        "\(item.displayTitle ?? item.filename), \(DownloadStatusFormatting.statusLabel(item)), \(Int(item.progress)) percent"
    }
}

private struct HomeCompactQueueThumbnail: View {
    let item: DownloadQueueItem
    let tint: Color

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
                .frame(width: 48, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            Image(systemName: DownloadStatusFormatting.statusIcon(item))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(2)
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

private struct HomeCompactQueueIconButton: View {
    let systemName: String
    let tint: Color
    let help: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isDisabled ? Theme.textSecondary.opacity(0.45) : tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(isDisabled ? 0.04 : 0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}
