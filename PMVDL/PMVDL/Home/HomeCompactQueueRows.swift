import AppKit
import SwiftUI

struct HomeCompletedQueueRow: View {
    let item: DownloadQueueItem
    let openLibrary: () -> Void
    let showInFinder: () -> Void
    let showSource: () -> Void
    let remove: () -> Void

    @State private var isHovered = false

    private let tint = Theme.success

    private var title: String {
        item.displayTitle ?? item.filename
    }

    private var destination: String {
        item.targetCloud.displayName
    }

    private var path: String {
        item.finalPath ?? item.retryPayload?.resolution.result.url ?? item.url
    }

    private var contextActions: [AppContextMenuAction] {
        var actions = [
            AppContextMenuAction("Open in Library", systemImage: "books.vertical.fill", action: openLibrary),
            AppContextMenuAction("Show in Finder", systemImage: "folder", action: showInFinder),
            AppContextMenuAction("Show Source", systemImage: "safari", action: showSource),
            AppContextMenuAction("Remove", systemImage: "trash", role: .destructive, action: remove)
        ]
        if let sourcePageURL = item.sourcePageURL {
            actions.insert(AppContextMenuAction("Copy Source URL", systemImage: "doc.on.doc", action: { ClipboardManager.copy(sourcePageURL) }), at: 3)
        }
        return actions
    }

    var body: some View {
        HStack(spacing: 12) {
            HomeCompactQueueThumbnail(item: item, tint: tint, size: CGSize(width: 64, height: 44))

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 7) {
                    Label("Completed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(tint)
                    Text(destination)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                if isHovered {
                    Text(path)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary.opacity(0.86))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .transition(.opacity)
                }
            }

            Spacer(minLength: 8)

            if isHovered {
                HStack(spacing: 5) {
                    HomeCompactQueueIconButton(systemName: "books.vertical.fill", tint: Theme.skyBlue, help: "Open in Library", action: openLibrary)
                    HomeCompactQueueIconButton(systemName: "folder", tint: Theme.textSecondary, help: "Show in Finder", action: showInFinder)
                    HomeCompactQueueIconButton(systemName: "trash", tint: Theme.error, help: "Remove", action: remove)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.surface1.opacity(isHovered ? 0.42 : 0.24), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(isHovered ? 0.30 : 0.14), lineWidth: 0.8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { openLibrary() }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
        .appContextMenu(title: title, subtitle: path, accent: tint, actions: contextActions)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(title), completed, destination \(destination)"))
        .accessibilityAction(named: Text("Open in Library"), openLibrary)
        .accessibilityAction(named: Text("Show in Finder"), showInFinder)
        .accessibilityAction(named: Text("Remove"), remove)
    }
}

struct HomeCompactQueueRow: View, Equatable {
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

    private var canRetry: Bool {
        item.canRetry || item.itemKind == .extraction
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
        .appContextMenu(title: item.displayTitle ?? item.filename, subtitle: details.location, accent: tint, actions: contextActions)
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
                isDisabled: !canRetry,
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
        case .pending, .waiting, .downloading, .verifying, .uploading:
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

    private var contextActions: [AppContextMenuAction] {
        var actions = [AppContextMenuAction]()
        if canRetry {
            actions.append(AppContextMenuAction("Retry", systemImage: "arrow.clockwise", action: retry))
        }
        if canStartNow {
            actions.append(AppContextMenuAction("Start Now", systemImage: "bolt.fill", action: startNow))
        }
        actions.append(AppContextMenuAction("Show Source", systemImage: "safari", action: showSource))
        if let sourcePageURL = item.sourcePageURL {
            actions.append(AppContextMenuAction("Copy Source URL", systemImage: "doc.on.doc", action: { ClipboardManager.copy(sourcePageURL) }))
        }
        actions.append(AppContextMenuAction("Show in Finder", systemImage: "folder", action: showInFinder))
        if !item.status.isTerminal && item.status != .processing {
            actions.append(AppContextMenuAction("Move to Front", systemImage: "forward.fill", action: moveToFront))
        }
        if case .failed = item.status {
            actions.append(AppContextMenuAction("Copy Error", systemImage: "doc.on.doc", action: copyError))
        }
        actions.append(AppContextMenuAction("Remove", systemImage: "trash", role: .destructive, action: remove))
        return actions
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

struct HomeQueueRowDetails: Equatable {
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

struct HomeCompactQueueStageChip: View {
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

struct HomeCompactQueueThumbnail: View {
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

struct HomeQueueProgressBar: View {
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

struct HomeCompactQueueIconButton: View {
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
