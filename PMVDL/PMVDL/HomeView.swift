import SwiftUI
import AppKit

struct HomeView: View {
    @ObservedObject var appState: AppStateManager
    @ObservedObject private var tracker = ActiveWorkTracker.shared
    @State private var urlText: String = ""
    @State private var results: [ExtractResult] = []
    @State private var isLoading = false
    @State private var loadProgress = ""
    @State private var showingStatusPopover = false
    @State private var showResultsSheet = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var megaRemotePath: String
    var gdriveRemoteName: String
    var gdriveRemotePath: String
    var seedboxTransferMode: String
    var seedboxRemoteName: String
    var seedboxRemotePath: String
    var seedboxWebdavURL: String
    var seedboxWebdavUser: String
    var seedboxWebdavPassword: String
    let onUpgradeRequired: () -> Void

    var urlLines: [String] {
        inputModel.validURLs
    }

    var batchTargetLinks: [String] {
        batchTargetJobs.map(\.url)
    }

    private var inputModel: HomeURLInputModel {
        HomeURLInputModel(rawText: urlText)
    }

    @State private var batchTarget: CloudTarget = .local

    private struct BatchDownloadJob {
        let url: String
        let title: String?
        let displayName: String
        let uploadFileName: String
    }

    private func preferredBatchTarget(for source: VideoSource) -> VideoSource.Quality? {
        if let mp4 = source.mp4 {
            return VideoSource.Quality(label: "Video", url: mp4, kind: .direct, headers: source.headers)
        }
        return source.hls.first { $0.kind != .pageUrl }
    }

    private var batchTargetJobs: [BatchDownloadJob] {
        results.compactMap { result in
            guard let source = result.source,
                  let target = preferredBatchTarget(for: source) else {
                return nil
            }
            if let state = state(for: target.url, target: batchTarget) {
                switch state {
                case .uploading, .done:
                    return nil
                case .failed:
                    break
                }
            }
            let title = source.title
            return BatchDownloadJob(
                url: target.url,
                title: title,
                displayName: title ?? fileName(of: target.url),
                uploadFileName: VideoFileNaming.mp4FileName(title: title, fallback: fileName(of: target.url))
            )
        }
    }

    // Category rail items — quick-paste shortcuts for common platforms
    private let categoryItems: [CategoryIconRail.Item] = [
        .init(id: "youtube",     icon: "play.rectangle.fill",       label: "YouTube",    color: Theme.taoRed),
        .init(id: "tiktok",      icon: "music.note",                label: "TikTok",     color: Theme.hotPink),
        .init(id: "twitter",     icon: "bird.fill",                 label: "Twitter/X",  color: Theme.skyBlue),
        .init(id: "vimeo",       icon: "film.fill",                 label: "Vimeo",      color: Theme.skyBlue),
        .init(id: "twitch",      icon: "gamecontroller.fill",       label: "Twitch",     color: Theme.lavender),
        .init(id: "reddit",      icon: "bubble.left.and.bubble.right.fill", label: "Reddit", color: Theme.coral),
        .init(id: "mega",        icon: "cloud.fill",                label: "Mega",       color: Theme.hotPink),
        .init(id: "other",       icon: "link",                      label: "Any URL",    color: Theme.amber),
    ]

    var body: some View {
        ScrollView {
            mainColumn
            .frame(maxWidth: HomeLayoutMetrics.pageMaxWidth, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(HomeLayoutMetrics.pagePadding)
        }
        .sheet(isPresented: $showResultsSheet) {
            resultsSheet
        }
        .onAppear {
            if let pending = appState.pendingExtractURL {
                consumePendingExtractURL(pending)
            } else if let clip = ClipboardManager.currentURL,
                      ClipboardManager.isLikelyVideoURL(clip) {
                urlText = clip
            }
        }
        .onChange(of: appState.pendingExtractURL) { _, newValue in
            if let url = newValue {
                consumePendingExtractURL(url)
            }
        }
    }

    private func consumePendingExtractURL(_ url: String) {
        let shouldStart = appState.pendingExtractShouldStart
        let feedThumbnail = appState.pendingExtractThumbnailURL
        urlText = url
        appState.pendingExtractURL = nil
        appState.pendingExtractShouldStart = false
        appState.pendingExtractThumbnailURL = nil
        if shouldStart {
            DispatchQueue.main.async {
                extractAll(feedThumbnailURL: feedThumbnail)
            }
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: HomeLayoutMetrics.cardSpacing) {
            HomeHeroHeader(
                inputModel: inputModel,
                resultCount: results.count,
                queuedCount: batchTargetLinks.count,
                isYtDlpReady: ScraperEngine.isYTDLPAvailable,
                isPro: ProFeatureGate.isPro,
                showingStatusPopover: $showingStatusPopover
            )

            HomeURLInputCard(
                text: $urlText,
                isLoading: isLoading,
                onPaste: pasteFromClipboard,
                onClear: { urlText = "" },
                onExtract: { extractAll() }
            )
            .modifier(HomeDropDestination(
                onUrlPaste: appendURLText,
                onFileDrop: { _ in }
            ))

            HomeCompactQueue(
                seedboxWebdavPassword: seedboxWebdavPassword,
                onUpgradeRequired: onUpgradeRequired
            )

            supportedSources
            DependencySetupPanel(gdriveRemoteName: gdriveRemoteName)

            Group {
                if !results.isEmpty {
                    showResultsButton
                        .transition(resultsReadyTransition)
                } else {
                    emptyState
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: results.isEmpty)
        }
    }

    private var supportedSources: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Popular supported sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            CategoryIconRail(items: categoryItems) { _ in }
        }
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 10) {
            GradientProgressBar(progress: 0.6)
            Text(loadProgress.isEmpty ? "Extracting..." : loadProgress)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)

            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    ShimmerCard(height: 68)
                }
            }
        }
        .padding(14)
        .glassCard(tint: Theme.skyBlue.opacity(0.08), cornerRadius: HomeLayoutMetrics.cardCornerRadius)
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Results")
                    .font(Theme.sectionHeader)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(results.count) found")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.skyBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.skyBlue.opacity(0.12), in: Capsule())
            }

            LazyVStack(spacing: 10) {
                ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                    VideoResultCard(
                        result: result,
                        localState: { tracker.localDownloads[$0] },
                        megaState: { tracker.megaUploads[$0] },
                        gdriveState: { tracker.gdriveUploads[$0] },
                        seedboxState: { tracker.seedboxUploads[$0] },
                        onLocal: { url in Task { await startDownload(url: url, cloud: .local) } },
                        onMega: { url in Task { await startDownload(url: url, cloud: .mega) } },
                        onGDrive: { url in Task { await startDownload(url: url, cloud: .gdrive) } },
                        onSeedbox: { url in Task { await startDownload(url: url, cloud: .seedbox) } }
                    )
                }
            }

            if !batchTargetLinks.isEmpty {
                BatchDownloadBar(
                    queuedCount: batchTargetLinks.count,
                    selectedTarget: $batchTarget,
                    isRunning: tracker.isBatchDownloading,
                    progressText: loadProgress,
                    action: batchDownloadAll
                )
            }
        }
    }

    private var resultsSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Extraction Results")
                        .font(Theme.sectionHeader)
                        .foregroundStyle(Theme.textPrimary)
                    Text(resultsSheetSubtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Button {
                    showResultsSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Theme.surface2.opacity(0.78), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()
                .opacity(0.35)

            ScrollView {
                resultsSheetContent
                    .padding(20)
                    .frame(maxWidth: 880, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 720, idealWidth: 860, maxWidth: 980, minHeight: 420, idealHeight: 640, maxHeight: 760)
        .background(Theme.surface0.opacity(0.94))
    }

    @ViewBuilder
    private var resultsSheetContent: some View {
        if isLoading {
            loadingState
        } else {
            resultsSection
        }
    }

    private var resultsSheetSubtitle: String {
        if isLoading {
            return loadProgress.isEmpty ? "Extracting..." : loadProgress
        }
        return "\(results.count) found"
    }

    private var resultsReadyTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97))
    }

    private var showResultsButton: some View {
        Button {
            showResultsSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.skyBlue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Results Ready")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(results.count) extracted URL\(results.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(14)
            .glassCard(tint: Theme.skyBlue.opacity(0.10), cornerRadius: HomeLayoutMetrics.cardCornerRadius)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ready for URLs", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Paste a URL above, drop one onto the input card, or use Cmd+Return after pasting.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(tint: Theme.surface2.opacity(0.12), cornerRadius: HomeLayoutMetrics.cardCornerRadius)
    }

    // ===== ACTIONS =====
    private func pasteFromClipboard() {
        if let clip = ClipboardManager.currentURL {
            appendURLText(clip)
        }
    }

    private func appendURLText(_ value: String) {
        let lines = HomeURLInputModel(rawText: value).lines
        guard !lines.isEmpty else { return }
        let addition = lines.joined(separator: "\n")
        if urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            urlText = addition
        } else {
            urlText += "\n" + addition
        }
    }

    private func extractAll(feedThumbnailURL: String? = nil) {
        let urls = urlLines
        guard !urls.isEmpty, inputModel.invalidLines.isEmpty else { return }
        results = []
        isLoading = true
        showResultsSheet = true
        loadProgress = ""
        tracker.clear(except: Set(tracker.megaUploads.keys)
            .union(tracker.gdriveUploads.keys)
            .union(tracker.seedboxUploads.keys))
        loadProgress = "Extracting \(urls.count) URL(s)…"

        Task {
            var completed = 0
            var localResults: [Int: ExtractResult] = [:]

            await withTaskGroup(of: (Int, ExtractResult).self) { group in
                for (i, url) in urls.enumerated() {
                    group.addTask {
                        var src: VideoSource?; var err: String?
                        do { src = try await ScraperEngine.extract(from: url) }
                        catch { err = error.localizedDescription }
                        return (i, ExtractResult(url: url, source: src, error: err))
                    }
                }
                for await (idx, res) in group {
                    localResults[idx] = res; completed += 1
                    await MainActor.run { loadProgress = "Extracting… \(completed)/\(urls.count)" }
                }
            }

            var ordered: [ExtractResult] = []
            for i in 0 ..< urls.count { if let r = localResults[i] { ordered.append(r) } }
            results = ordered

            // Add to library
            for r in ordered {
                if let src = r.source {
                    let title = src.title ?? URL(string: r.url)?.pathComponents.last?.replacingOccurrences(of: "-", with: " ").capitalized ?? r.url
                    VideoLibrary.shared.addIfNew(
                        LibraryItem(
                            url: r.url,
                            title: title,
                            mp4Url: src.mp4,
                            hlsUrls: src.hls,
                            thumbnailURL: src.thumbnail ?? feedThumbnailURL,
                            uploaderName: src.uploader,
                            uploaderURL: src.uploaderURL,
                            sourceSiteName: src.siteName
                        )
                    )
                    HistoryManager.shared.record(url: r.url, source: src)
                }
            }
            NotificationManager.shared.notifyScrapeComplete(count: ordered.filter { $0.source != nil }.count)

            isLoading = false
            loadProgress = ""
            showResultsSheet = !ordered.isEmpty
        }
    }

    private func batchDownloadAll() {
        let jobs = batchTargetJobs
        guard !jobs.isEmpty else { return }
        let selectedTarget = batchTarget

        Task {
            guard ProFeatureGate.canBatchDownload(count: jobs.count) else {
                onUpgradeRequired()
                return
            }

            guard await LicenseManager.shared.preflight(count: jobs.count) else {
                onUpgradeRequired()
                return
            }
            tracker.isBatchDownloading = true
            loadProgress = "\(selectedTarget.homeBatchButtonTitle) 0/\(jobs.count)…"

            var resolutions: [DownloadResolution] = []
            for job in jobs {
                do {
                    resolutions.append(try await DownloadResolver.resolve(requestedUrl: job.url, in: results))
                } catch {
                    tracker.projectFailure(url: job.url, target: selectedTarget, message: error.localizedDescription)
                    NotificationManager.shared.notifyUploadFailed(filename: job.uploadFileName, reason: error.localizedDescription)
                }
            }

            guard ProFeatureGate.canDownloadAudio || !resolutions.contains(where: \.isAudio) else {
                onUpgradeRequired()
                tracker.isBatchDownloading = false
                loadProgress = ""
                return
            }

            let context = downloadJobContext
            var nextIndex = 0
            var done = jobs.count - resolutions.count
            let concurrencyLimit = DownloadQueue.shared.concurrentLimit

            await withTaskGroup(of: Bool.self) { group in
                func addNext() {
                    guard nextIndex < resolutions.count else { return }
                    let resolution = resolutions[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await DownloadJobRunner.shared.run(resolution: resolution, target: selectedTarget, context: context)
                    }
                }

                for _ in 0..<min(concurrencyLimit, resolutions.count) {
                    addNext()
                }

                for await _ in group {
                    done += 1
                    await MainActor.run { loadProgress = "\(selectedTarget.homeBatchButtonTitle) \(done)/\(jobs.count)" }
                    addNext()
                }
            }

            tracker.isBatchDownloading = false; loadProgress = ""
        }
    }

    private func startDownload(url: String, cloud: CloudTarget) async {
        guard await LicenseManager.shared.preflight() else {
            onUpgradeRequired()
            return
        }
        do {
            let resolution = try await DownloadResolver.resolve(requestedUrl: url, in: results)
            guard ProFeatureGate.canDownloadAudio || !resolution.isAudio else {
                onUpgradeRequired()
                return
            }
            DownloadJobRunner.shared.start(resolution: resolution, target: cloud, context: downloadJobContext)
        } catch {
            tracker.projectFailure(url: url, target: cloud, message: error.localizedDescription)
            NotificationManager.shared.notifyUploadFailed(filename: uploadFileName(for: url), reason: error.localizedDescription)
        }
    }

    private var downloadJobContext: DownloadJobContext {
        DownloadJobContext(
            megaRemotePath: megaRemotePath,
            gdriveRemoteName: gdriveRemoteName,
            gdriveRemotePath: gdriveRemotePath,
            seedboxTransferMode: seedboxTransferMode,
            seedboxRemoteName: seedboxRemoteName,
            seedboxRemotePath: seedboxRemotePath,
            seedboxWebdavURL: seedboxWebdavURL,
            seedboxWebdavUser: seedboxWebdavUser,
            seedboxWebdavPassword: seedboxWebdavPassword
        )
    }

    private func fileName(of url: String) -> String {
        (url.split(separator: "/").last.map { String($0) }) ?? url
    }

    private func title(for url: String) -> String? {
        results.first {
            $0.source?.mp4 == url || $0.source?.hls.contains(where: { $0.url == url }) == true
        }?.source?.title
    }

    private func displayName(for url: String) -> String {
        title(for: url) ?? fileName(of: url)
    }

    private func uploadFileName(for url: String) -> String {
        VideoFileNaming.mp4FileName(title: title(for: url), fallback: fileName(of: url))
    }

    private func state(for url: String, target: CloudTarget) -> UploadState? {
        switch target {
        case .local:
            return tracker.localDownloads[url]
        case .mega:
            return tracker.megaUploads[url]
        case .gdrive:
            return tracker.gdriveUploads[url]
        case .seedbox:
            return tracker.seedboxUploads[url]
        }
    }
}
