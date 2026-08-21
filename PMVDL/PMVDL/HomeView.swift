import SwiftUI
import AppKit

enum ExtractionRetrySupport {
    static func failedIndices(in results: [ExtractResult]) -> [Int] {
        results.enumerated().compactMap { index, result in
            result.error == nil ? nil : index
        }
    }

    static func retryableFailedIndices(in results: [ExtractResult], retryingIndices: Set<Int>) -> [Int] {
        failedIndices(in: results).filter { !retryingIndices.contains($0) }
    }

    static func replacingResult(at index: Int, in results: [ExtractResult], with replacement: ExtractResult) -> [ExtractResult] {
        guard results.indices.contains(index) else { return results }
        var next = results
        next[index] = replacement
        return next
    }
}

enum ExtractionBatchPolicy {
    static let maximumConcurrentExtractions = 3

    static func ranges(forCount count: Int) -> [Range<Int>] {
        guard count > 0 else { return [] }
        return stride(from: 0, to: count, by: maximumConcurrentExtractions).map {
            $0..<min($0 + maximumConcurrentExtractions, count)
        }
    }
}

struct ExtractionSlot: Identifiable, Equatable {
    let id: UUID
    let url: String
    var title: String
    let thumbnailURL: String?
    var result: ExtractResult?
    var activity: [String]
}

enum ExtractionTitleSupport {
    static func title(for urlString: String, hint: String? = nil) -> String {
        if let hint = normalized(hint) {
            return hint
        }
        guard let url = URL(string: urlString) else { return urlString }
        let slug = url.lastPathComponent.removingPercentEncoding?
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !slug.isEmpty, slug != "/" {
            return slug.capitalized
        }
        return url.host ?? urlString
    }

    static func resolvedTitle(_ sourceTitle: String?, fallback: String) -> String {
        normalized(sourceTitle) ?? fallback
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ExtractionSlotSupport {
    static func startingSlots(
        for urls: [String],
        titleHints: [String: String] = [:],
        thumbnailHints: [String: String] = [:]
    ) -> [ExtractionSlot] {
        urls.map {
            ExtractionSlot(
                id: UUID(),
                url: $0,
                title: ExtractionTitleSupport.title(for: $0, hint: titleHints[$0]),
                thumbnailURL: thumbnailHints[$0],
                result: nil,
                activity: []
            )
        }
    }

    static func replacingSlot(id: UUID, in slots: [ExtractionSlot], with result: ExtractResult) -> [ExtractionSlot] {
        slots.map { slot in
            guard slot.id == id else { return slot }
            return ExtractionSlot(
                id: slot.id,
                url: slot.url,
                title: ExtractionTitleSupport.resolvedTitle(result.source?.title, fallback: slot.title),
                thumbnailURL: slot.thumbnailURL,
                result: result,
                activity: slot.activity
            )
        }
    }

    static func appendingActivity(_ message: String, toSlot id: UUID, in slots: [ExtractionSlot]) -> [ExtractionSlot] {
        slots.map { slot in
            guard slot.id == id else { return slot }
            var activity = slot.activity
            if activity.last != message {
                activity.append(message)
            }
            return ExtractionSlot(
                id: slot.id,
                url: slot.url,
                title: slot.title,
                thumbnailURL: slot.thumbnailURL,
                result: slot.result,
                activity: Array(activity.suffix(12))
            )
        }
    }

    static func completedResults(in slots: [ExtractionSlot]) -> [ExtractResult] {
        slots.compactMap(\.result)
    }

    static func slotIDForCompletedResult(at index: Int, in slots: [ExtractionSlot]) -> UUID? {
        let completedSlots = slots.filter { $0.result != nil }
        guard completedSlots.indices.contains(index) else { return nil }
        return completedSlots[index].id
    }
}

private struct HomeQueueStatusProgressBar: View {
    let progress: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.surface2.opacity(0.42))

                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: [tint, tint.opacity(0.66)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

struct HomeView: View {
    @ObservedObject var appState: AppStateManager
    @ObservedObject private var tracker = ActiveWorkTracker.shared
    @ObservedObject private var downloadQueue = DownloadQueue.shared
    @ObservedObject private var verificationCoordinator = ExtractionVerificationCoordinator.shared
    @State private var urlText: String = ""
    @State private var results: [ExtractResult] = []
    @State private var extractionSlots: [ExtractionSlot] = []
    @State private var isLoading = false
    @State private var loadProgress = ""
    @State private var activeBatchSubmission: BatchSubmission?
    @State private var queueAllWhenExtractionCompletes = false
    @State private var queuePreparationFailure: String?
    @State private var retryingResultIndices: Set<Int> = []
    @State private var extractionGeneration = UUID()
    @State private var showResultsSheet = false
    @State private var showActiveDownloadsSheet = false
    @State private var showQueuedDownloadsSheet = false
    @State private var showCompletedDownloadsSheet = false
    @State private var showCompletionBanner = false
    @State private var hadActiveDownloads = false
    @State private var completionBannerToken = UUID()
    @State private var modalAddURLText = ""
    @State private var extractionTitleHints: [String: String] = [:]
    @State private var extractionThumbnailHints: [String: String] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appShellWindowSize) private var appShellWindowSize
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

    private var layoutWindowSize: CGSize {
        appShellWindowSize == .zero ? appState.windowSize : appShellWindowSize
    }

    var urlLines: [String] {
        inputModel.validURLs
    }

    var batchTargetLinks: [String] {
        batchQueueJobs.map(\.url)
    }

    private var inputModel: HomeURLInputModel {
        HomeURLInputModel(rawText: urlText)
    }

    private var hasActiveDownloads: Bool {
        !activeDownloadItems.isEmpty
    }

    private var hasCompletedDownloads: Bool {
        !completedDownloadItems.isEmpty
    }

    private var visibleDownloadItems: [DownloadQueueItem] {
        downloadQueue.queue.filter(\.isVisibleInDownloads)
    }

    private var activeDownloadItems: [DownloadQueueItem] {
        visibleDownloadItems.filter { HomeQueueCounts.isActive($0.status) }
    }

    private var queuedDownloadItems: [DownloadQueueItem] {
        visibleDownloadItems.filter {
            switch $0.status {
            case .pending, .waiting, .paused, .failed:
                return true
            case .downloading, .verifying, .uploading, .processing, .completed:
                return false
            }
        }
    }

    private var hasQueuedDownloads: Bool { !queuedDownloadItems.isEmpty }

    private var completedDownloadItems: [DownloadQueueItem] {
        visibleDownloadItems.filter { $0.status == .completed }
    }

    private var queueCounts: HomeQueueCounts {
        HomeQueueCounts(items: visibleDownloadItems)
    }

    @State private var batchTarget: CloudTarget = .local

    private struct BatchDownloadJob {
        let url: String
        let sourcePageURL: String
        let qualityLabel: String
        let title: String?
        let displayName: String
        let uploadFileName: String
    }

    private struct BatchSignature: Equatable {
        let target: CloudTarget
        let urls: [String]
    }

    private struct BatchSubmission: Equatable {
        let signature: BatchSignature
        var progressText: String
    }

    private func preferredBatchTarget(for source: VideoSource) -> VideoSource.Quality? {
        if let mp4 = source.mp4 {
            return VideoSource.Quality(label: "Video", url: mp4, kind: .direct, headers: source.headers)
        }
        return source.hls.first { $0.kind != .pageUrl }
    }

    private func batchJobs(excludingExistingQueueItems: Bool) -> [BatchDownloadJob] {
        results.compactMap { result in
            guard let source = result.source,
                  let target = preferredBatchTarget(for: source) else {
                return nil
            }
            if excludingExistingQueueItems {
                if hasExistingQueueItem(for: target.url, target: batchTarget) {
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
            }
            let title = source.title
            return BatchDownloadJob(
                url: target.url,
                sourcePageURL: result.url,
                qualityLabel: target.label,
                title: title,
                displayName: title ?? fileName(of: target.url),
                uploadFileName: VideoFileNaming.mp4FileName(title: title, fallback: fileName(of: target.url))
            )
        }
    }

    private var batchTargetJobs: [BatchDownloadJob] {
        batchJobs(excludingExistingQueueItems: true)
    }

    private var batchQueueJobs: [BatchDownloadJob] {
        batchJobs(excludingExistingQueueItems: false)
    }

    private var currentBatchSignature: BatchSignature? {
        let urls = results.compactMap { result in
            result.source.flatMap(preferredBatchTarget(for:))?.url
        }
        guard !urls.isEmpty else { return nil }
        return BatchSignature(target: batchTarget, urls: urls.sorted())
    }

    private var isCurrentBatchSubmitting: Bool {
        guard let currentBatchSignature else { return false }
        return activeBatchSubmission?.signature == currentBatchSignature
    }

    private var currentBatchProgressText: String {
        guard isCurrentBatchSubmitting else { return "" }
        return activeBatchSubmission?.progressText ?? ""
    }

    private var failedResultIndices: [Int] {
        ExtractionRetrySupport.failedIndices(in: results)
    }

    private var retryableFailedResultIndices: [Int] {
        ExtractionRetrySupport.retryableFailedIndices(in: results, retryingIndices: retryingResultIndices)
    }

    private var isRetryingFailedResults: Bool {
        !retryingResultIndices.isEmpty
    }

    private var hasNoActiveDownloads: Bool {
        !hasActiveDownloads
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
        ZStack {
            ScrollView {
                mainColumn
                .frame(maxWidth: AppShellSurfaceMetrics.pageMaxWidth(for: layoutWindowSize), alignment: .top)
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(HomeLayoutMetrics.pagePadding)
            }

            if showResultsSheet {
                AppModalOverlay(
                    dismiss: { showResultsSheet = false }
                ) {
                    resultsSheet
                }
                .zIndex(20)
            }

            if showActiveDownloadsSheet {
                AppModalOverlay(dismiss: { showActiveDownloadsSheet = false }) {
                    HomeCompactQueue(
                        displayMode: .activeModal,
                        seedboxWebdavPassword: seedboxWebdavPassword,
                        onUpgradeRequired: onUpgradeRequired,
                        onClose: { showActiveDownloadsSheet = false }
                    )
                }
                .zIndex(21)
            }

            if showQueuedDownloadsSheet {
                AppModalOverlay(dismiss: { showQueuedDownloadsSheet = false }) {
                    HomeCompactQueue(
                        displayMode: .queuedModal,
                        seedboxWebdavPassword: seedboxWebdavPassword,
                        onUpgradeRequired: onUpgradeRequired,
                        onClose: { showQueuedDownloadsSheet = false }
                    )
                }
                .zIndex(22)
            }

            if showCompletedDownloadsSheet {
                AppModalOverlay(dismiss: { showCompletedDownloadsSheet = false }) {
                    HomeCompactQueue(
                        displayMode: .completedModal,
                        seedboxWebdavPassword: seedboxWebdavPassword,
                        onUpgradeRequired: onUpgradeRequired,
                        onClose: { showCompletedDownloadsSheet = false }
                    )
                }
                .zIndex(23)
            }

            if let request = verificationCoordinator.request {
                AppModalOverlay(dismiss: {
                    verificationCoordinator.finishVerification()
                }) {
                    ExtractionVerificationPane(
                        request: request,
                        onCompleted: {
                            verificationCoordinator.finishVerification()
                            retryFailedResults()
                        },
                        onCancel: {
                            verificationCoordinator.finishVerification()
                        }
                    )
                }
                .zIndex(30)
            }
        }
        .onAppear {
            hadActiveDownloads = hasActiveDownloads
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
        .onChange(of: hasActiveDownloads) { oldValue, newValue in
            hadActiveDownloads = newValue
            if !newValue {
                showActiveDownloadsSheet = false
            }
            if oldValue && !newValue && hasCompletedDownloads {
                presentCompletionBanner()
            }
        }
        .onChange(of: completedDownloadItems.count) { _, newValue in
            if newValue == 0 {
                showCompletionBanner = false
                showCompletedDownloadsSheet = false
            }
        }
        .onChange(of: queuedDownloadItems.count) { _, newValue in
            if newValue == 0 {
                showQueuedDownloadsSheet = false
            }
        }
        .onChange(of: isLoading) { oldValue, newValue in
            guard oldValue, !newValue, queueAllWhenExtractionCompletes else { return }
            queueAllWhenExtractionCompletes = false
            batchQueueAll()
        }
        .alert(
            "Could Not Queue Download",
            isPresented: Binding(
                get: { queuePreparationFailure != nil },
                set: { if !$0 { queuePreparationFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(queuePreparationFailure ?? "")
        }
    }

    private func consumePendingExtractURL(_ url: String) {
        let shouldStart = appState.pendingExtractShouldStart
        let feedThumbnail = appState.pendingExtractThumbnailURL
        extractionTitleHints = appState.pendingExtractTitles
        extractionThumbnailHints = appState.pendingExtractThumbnailURLs
        if extractionThumbnailHints[url] == nil, let feedThumbnail {
            extractionThumbnailHints[url] = feedThumbnail
        }
        urlText = url
        appState.pendingExtractURL = nil
        appState.pendingExtractShouldStart = false
        appState.pendingExtractThumbnailURL = nil
        appState.pendingExtractThumbnailURLs = [:]
        appState.pendingExtractTitles = [:]
        if shouldStart {
            DispatchQueue.main.async {
                extractAll(feedThumbnailURL: feedThumbnail)
            }
        }
    }

    private var mainColumn: some View {
        noActiveDownloadStack
    }

    private var noActiveDownloadStack: some View {
        VStack(alignment: .center, spacing: HomeLayoutMetrics.cardSpacing) {
            HomeStitchCommandPanel(
                text: $urlText,
                isLoading: isLoading,
                isYtDlpReady: ScraperEngine.isYTDLPAvailable,
                isPro: ProFeatureGate.isPro,
                onPaste: pasteFromClipboard,
                onClear: { urlText = "" },
                onExtract: extractFromPrimaryAction,
                completedContent: {
                    queueStatusEntrypoints
                },
                resultsContent: {
                    if !results.isEmpty {
                        showResultsButton(isCompact: false)
                            .transition(resultsReadyTransition)
                    }
                }
            )
            .modifier(HomeDropDestination(
                onUrlPaste: appendURLText,
                onFileDrop: { _ in }
            ))

            DependencySetupPanel(gdriveRemoteName: gdriveRemoteName)
        }
        .frame(maxWidth: AppShellSurfaceMetrics.mainPanelWidth(for: layoutWindowSize))
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82), value: results.isEmpty)
    }

    @ViewBuilder
    private var queueStatusEntrypoints: some View {
        if hasActiveDownloads || hasQueuedDownloads || hasCompletedDownloads || showCompletionBanner {
            VStack(alignment: .leading, spacing: 10) {
                if showCompletionBanner && hasCompletedDownloads {
                    completionBanner
                }

                if hasActiveDownloads || hasQueuedDownloads || hasCompletedDownloads {
                    HStack(spacing: 10) {
                        if hasActiveDownloads {
                            queueEntrypointButton(
                                title: "Active Downloads",
                                subtitle: activeDownloadItems.count == 1 ? "1 transfer in progress" : "\(activeDownloadItems.count) transfers in progress",
                                systemImage: "arrow.down.circle.fill",
                                tint: Theme.skyBlue,
                                count: queueCounts.active,
                                progress: queueCounts.activeProgress
                            ) {
                                showActiveDownloadsSheet = true
                            }
                        }

                        if hasQueuedDownloads {
                            queueEntrypointButton(
                                title: "Queued Downloads",
                                subtitle: queueCounts.queuedSummaryText,
                                systemImage: "clock.fill",
                                tint: Theme.warning,
                                count: queuedDownloadItems.count,
                                progress: 0
                            ) {
                                showQueuedDownloadsSheet = true
                            }
                        }

                        if hasCompletedDownloads {
                            queueEntrypointButton(
                                title: "Completed",
                                subtitle: completedDownloadItems.count == 1 ? "1 ready to review" : "\(completedDownloadItems.count) ready to review",
                                systemImage: "checkmark.circle.fill",
                                tint: Theme.success,
                                count: completedDownloadItems.count,
                                progress: 1
                            ) {
                                showCompletedDownloadsSheet = true
                            }
                        }
                    }
                }
            }
            .transition(resultsReadyTransition)
        }
    }

    private var completionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.success)

            VStack(alignment: .leading, spacing: 2) {
                Text("Downloads Complete")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text(completedDownloadItems.count == 1 ? "1 completed download is ready." : "\(completedDownloadItems.count) completed downloads are ready.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 10)

            Button("View Completed") {
                showCompletionBanner = false
                showCompletedDownloadsSheet = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(Theme.success)

            Button("Dismiss") {
                showCompletionBanner = false
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(Theme.success.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(Theme.success.opacity(0.22), lineWidth: 1)
        )
    }

    private func queueEntrypointButton(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        count: Int,
        progress: Double,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(tint)

                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)

                    Spacer(minLength: 8)

                    Text("\(count)")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(Theme.surface0)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(tint, in: Capsule())
                        .contentTransition(.numericText())
                }

                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                HomeQueueStatusProgressBar(progress: progress, tint: tint)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface0.opacity(0.36), in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func presentCompletionBanner() {
        let token = UUID()
        completionBannerToken = token
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            showCompletionBanner = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard completionBannerToken == token else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                showCompletionBanner = false
            }
        }
    }

    private func urlInputCard(isCompact: Bool, isCommandCenter: Bool = false) -> some View {
        HomeURLInputCard(
            text: $urlText,
            isLoading: isLoading,
            isCompact: isCompact,
            isCommandCenter: isCommandCenter,
            isYtDlpReady: ScraperEngine.isYTDLPAvailable,
            isPro: ProFeatureGate.isPro,
            onPaste: pasteFromClipboard,
            onClear: { urlText = "" },
            onExtract: { extractAll() }
        )
        .modifier(HomeDropDestination(
            onUrlPaste: appendURLText,
            onFileDrop: { _ in }
        ))
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 10) {
            GradientProgressBar(progress: 0.6)
            Text(loadProgress.isEmpty ? "Extracting..." : loadProgress)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)

            ShimmerCard(height: 68)
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
                ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                    VideoResultCard(
                        result: result,
                        isRetrying: retryingResultIndices.contains(index),
                        localState: { tracker.localDownloads[$0] },
                        megaState: { tracker.megaUploads[$0] },
                        gdriveState: { tracker.gdriveUploads[$0] },
                        seedboxState: { tracker.seedboxUploads[$0] },
                        onRetry: { retryExtractResult(at: index) },
                        onLocal: { url in Task { await startDownload(url: url, cloud: .local) } },
                        onMega: { url in Task { await startDownload(url: url, cloud: .mega) } },
                        onGDrive: { url in Task { await startDownload(url: url, cloud: .gdrive) } },
                        onSeedbox: { url in Task { await startDownload(url: url, cloud: .seedbox) } },
                        onMultiple: { url, destinations in Task { await startDownload(url: url, destinations: destinations) } }
                    )
                }
            }

            if !batchTargetLinks.isEmpty {
                BatchDownloadBar(
                    queuedCount: batchTargetLinks.count,
                    selectedTarget: $batchTarget,
                    isSubmitting: isCurrentBatchSubmitting,
                    progressText: currentBatchProgressText,
                    action: batchDownloadAll
                )
            }
        }
    }

    private var resultsSheet: some View {
        ExtractionModalView(
            addURLText: $modalAddURLText,
            batchTarget: $batchTarget,
            isLoading: isLoading,
            loadProgress: loadProgress,
            extractionSlots: extractionSlots,
            results: results,
            retryingResultIndices: retryingResultIndices,
            batchQueuedCount: batchTargetLinks.count,
            isBatchSubmitting: isCurrentBatchSubmitting,
            batchProgressText: currentBatchProgressText,
            queueAllWhenReady: queueAllWhenExtractionCompletes,
            canRetryFailed: !retryableFailedResultIndices.isEmpty,
            isYtDlpReady: ScraperEngine.isYTDLPAvailable,
            localState: { tracker.localDownloads[$0] },
            megaState: { tracker.megaUploads[$0] },
            gdriveState: { tracker.gdriveUploads[$0] },
            seedboxState: { tracker.seedboxUploads[$0] },
            onAddURL: addURLFromResultsModal,
            onRetryFailed: retryFailedResults,
            onRetry: retryExtractResult,
            onLocal: { url in Task { await startDownload(url: url, cloud: .local) } },
            onMega: { url in Task { await startDownload(url: url, cloud: .mega) } },
            onGDrive: { url in Task { await startDownload(url: url, cloud: .gdrive) } },
            onSeedbox: { url in Task { await startDownload(url: url, cloud: .seedbox) } },
            onMultiple: { url, destinations in Task { await startDownload(url: url, destinations: destinations) } },
            onQueue: { url, target in Task { await queueDownload(url: url, target: target) } },
            onBatchDownload: batchDownloadAll,
            onBatchQueue: requestBatchQueueAll
        )
    }

    private var resultsReadyTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97))
    }

    private func showResultsButton(isCompact: Bool) -> some View {
        Button {
            showResultsSheet = true
        } label: {
            HStack(spacing: isCompact ? 8 : 10) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: isCompact ? 13 : 15, weight: .bold))
                    .foregroundStyle(Theme.skyBlue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Review Downloads")
                        .font((isCompact ? Font.caption : Font.subheadline).weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(results.count) video\(results.count == 1 ? "" : "s") ready to download")
                        .font(isCompact ? .caption2 : .caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: isCompact ? 11 : 13, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(isCompact ? 10 : 14)
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

    private func extractFromPrimaryAction() {
        guard !isLoading else { return }

        if urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let clip = ClipboardManager.currentURL else { return }
            appendURLText(clip)
            DispatchQueue.main.async {
                extractAll()
            }
            return
        }

        extractAll()
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
        let generation = UUID()
        extractionGeneration = generation
        retryingResultIndices.removeAll()
        extractionSlots = ExtractionSlotSupport.startingSlots(
            for: urls,
            titleHints: extractionTitleHints,
            thumbnailHints: extractionThumbnailHints
        )
        extractionTitleHints = [:]
        extractionThumbnailHints = [:]
        results = []
        isLoading = true
        showResultsSheet = true
        loadProgress = ""
        tracker.clear(except: Set(tracker.megaUploads.keys)
            .union(tracker.gdriveUploads.keys)
            .union(tracker.seedboxUploads.keys))
        let batchRanges = ExtractionBatchPolicy.ranges(forCount: urls.count)
        loadProgress = "Extracting batch 1 of \(batchRanges.count)…"

        Task {
            var completed = 0
            var successCount = 0
            let slots = extractionSlots

            for (batchIndex, range) in batchRanges.enumerated() {
                await MainActor.run {
                    guard extractionGeneration == generation else { return }
                    loadProgress = "Extracting batch \(batchIndex + 1) of \(batchRanges.count)… \(completed)/\(urls.count)"
                }

                await withTaskGroup(of: (UUID, ExtractResult).self) { group in
                    for i in range {
                        let url = urls[i]
                        let slotID = slots[i].id
                        group.addTask {
                            var src: VideoSource?; var err: String?
                            let progress: @Sendable (String) -> Void = { message in
                                Task { @MainActor in
                                    guard extractionGeneration == generation else { return }
                                    extractionSlots = ExtractionSlotSupport.appendingActivity(
                                        message,
                                        toSlot: slotID,
                                        in: extractionSlots
                                    )
                                    loadProgress = message
                                }
                            }
                            do { src = try await ExtractionCoordinator.extractWithProgress(from: url, onProgress: progress) }
                            catch {
                                err = error.localizedDescription
                                progress("Source failed • stage: page extraction • source: \(url) • reason: \(err ?? "Unknown error")")
                            }
                            return (slotID, ExtractResult(url: url, source: src, error: err))
                        }
                    }

                    for await (slotID, res) in group {
                        completed += 1
                        await MainActor.run {
                            guard extractionGeneration == generation else { return }
                            if res.source == nil {
                                let title = extractionSlots.first(where: { $0.id == slotID })?.title
                                    ?? ExtractionTitleSupport.title(for: res.url)
                                recordExtractionFailure(res, title: title)
                                extractionSlots = ExtractionSlotSupport.replacingSlot(id: slotID, in: extractionSlots, with: res)
                            } else {
                                extractionSlots = ExtractionSlotSupport.replacingSlot(id: slotID, in: extractionSlots, with: res)
                            }
                            results = ExtractionSlotSupport.completedResults(in: extractionSlots)
                            let resultCount = res.source.map { $0.hls.filter { $0.kind != .pageUrl }.count + ($0.mp4 == nil ? 0 : 1) } ?? 0
                            let completion = res.source == nil
                                ? (res.error ?? "Extraction failed.")
                                : "Completed: \(resultCount) downloadable source\(resultCount == 1 ? "" : "s")"
                            extractionSlots = ExtractionSlotSupport.appendingActivity(completion, toSlot: slotID, in: extractionSlots)
                            loadProgress = "Batch \(batchIndex + 1) of \(batchRanges.count) • \(completed)/\(urls.count) • \(completion)"
                            if res.source != nil {
                                successCount += 1
                                persistSuccessfulExtraction(res, feedThumbnailURL: feedThumbnailURL)
                            }
                        }
                    }
                }
            }

            await MainActor.run {
                guard extractionGeneration == generation else { return }
                results = ExtractionSlotSupport.completedResults(in: extractionSlots)
                retryingResultIndices.removeAll()
                NotificationManager.shared.notifyScrapeComplete(count: successCount)
                isLoading = false
                loadProgress = ""
                showResultsSheet = true
            }
        }
    }

    private func addURLFromResultsModal() {
        let model = HomeURLInputModel(rawText: modalAddURLText)
        guard model.readyCount == 1,
              model.invalidLines.isEmpty,
              let url = model.validURLs.first else { return }
        appendURLText(url)
        modalAddURLText = ""
        extractAdditionalURL(url)
    }

    private func extractAdditionalURL(_ url: String) {
        let generation = UUID()
        extractionGeneration = generation
        let slot = ExtractionSlot(
            id: UUID(),
            url: url,
            title: ExtractionTitleSupport.title(for: url),
            thumbnailURL: nil,
            result: nil,
            activity: []
        )
        extractionSlots.append(slot)
        isLoading = true
        loadProgress = "Extracting 1 URL..."

        Task {
            let progress: @Sendable (String) -> Void = { message in
                Task { @MainActor in
                    guard extractionGeneration == generation else { return }
                    extractionSlots = ExtractionSlotSupport.appendingActivity(message, toSlot: slot.id, in: extractionSlots)
                    loadProgress = message
                }
            }
            let result = await extractResult(for: url, onProgress: progress)
            await MainActor.run {
                guard extractionGeneration == generation else { return }
                if result.source == nil {
                    recordExtractionFailure(result, title: slot.title)
                    extractionSlots = ExtractionSlotSupport.replacingSlot(id: slot.id, in: extractionSlots, with: result)
                } else {
                    extractionSlots = ExtractionSlotSupport.replacingSlot(id: slot.id, in: extractionSlots, with: result)
                }
                results = ExtractionSlotSupport.completedResults(in: extractionSlots)
                let resolvedCount = result.source.map { $0.hls.filter { $0.kind != .pageUrl }.count + ($0.mp4 == nil ? 0 : 1) } ?? 0
                let completion = result.source == nil
                    ? (result.error ?? "Extraction failed.")
                    : "Completed: \(resolvedCount) downloadable source\(resolvedCount == 1 ? "" : "s")"
                extractionSlots = ExtractionSlotSupport.appendingActivity(completion, toSlot: slot.id, in: extractionSlots)
                if result.source != nil {
                    persistSuccessfulExtraction(result, feedThumbnailURL: nil)
                }
                isLoading = false
                loadProgress = ""
                showResultsSheet = true
            }
        }
    }

    @MainActor
    private func persistSuccessfulExtraction(_ result: ExtractResult, feedThumbnailURL: String?) {
        guard let src = result.source else { return }
        let title = src.title ?? URL(string: result.url)?.pathComponents.last?.replacingOccurrences(of: "-", with: " ").capitalized ?? result.url
        VideoLibrary.shared.addIfNew(
            LibraryItem(
                url: result.url,
                title: title,
                mp4Url: src.mp4,
                hlsUrls: src.hls,
                thumbnailURL: src.thumbnail ?? feedThumbnailURL,
                uploaderName: src.uploader,
                uploaderURL: src.uploaderURL,
                sourceSiteName: src.siteName
            )
        )
        HistoryManager.shared.record(url: result.url, source: src)
    }

    @MainActor
    private func recordExtractionFailure(_ result: ExtractResult, title: String) {
        DownloadQueue.shared.addFailed(
            url: result.url,
            quality: "Extraction",
            displayTitle: title,
            message: result.error ?? "Could not extract downloadable sources.",
            itemKind: .extraction
        )
    }

    private func extractResult(for url: String, onProgress: (@Sendable (String) -> Void)? = nil) async -> ExtractResult {
        do {
            return ExtractResult(url: url, source: try await ExtractionCoordinator.extractWithProgress(from: url, onProgress: onProgress), error: nil)
        } catch {
            onProgress?("Source failed • stage: page extraction • source: \(url) • reason: \(error.localizedDescription)")
            return ExtractResult(url: url, source: nil, error: error.localizedDescription)
        }
    }

    @MainActor
    private func retryFailedResults() {
        for index in retryableFailedResultIndices {
            retryExtractResult(at: index)
        }
    }

    @MainActor
    private func retryExtractResult(at index: Int) {
        guard results.indices.contains(index),
              retryingResultIndices.insert(index).inserted else { return }

        let url = results[index].url
        let generation = extractionGeneration
        let slotID = ExtractionSlotSupport.slotIDForCompletedResult(at: index, in: extractionSlots)

        Task {
            let progress: @Sendable (String) -> Void = { message in
                Task { @MainActor in
                    guard extractionGeneration == generation else { return }
                    if let slotID {
                        extractionSlots = ExtractionSlotSupport.appendingActivity(message, toSlot: slotID, in: extractionSlots)
                    }
                    loadProgress = message
                }
            }
            let retried = await extractResult(for: url, onProgress: progress)
            await MainActor.run {
                guard extractionGeneration == generation else { return }
                retryingResultIndices.remove(index)
                guard results.indices.contains(index),
                      results[index].url == url else { return }
                results = ExtractionRetrySupport.replacingResult(at: index, in: results, with: retried)
                if let slotID {
                    extractionSlots = ExtractionSlotSupport.replacingSlot(id: slotID, in: extractionSlots, with: retried)
                }
                if retried.source != nil {
                    persistSuccessfulExtraction(retried, feedThumbnailURL: nil)
                }
            }
        }
    }

    private func batchDownloadAll() {
        let jobs = batchTargetJobs
        guard !jobs.isEmpty,
              let signature = currentBatchSignature,
              activeBatchSubmission?.signature != signature else { return }
        let selectedTarget = batchTarget
        let currentResults = results
        activeBatchSubmission = BatchSubmission(
            signature: signature,
            progressText: "\(selectedTarget.homeBatchButtonTitle) 0/\(jobs.count)..."
        )

        Task {
            defer {
                Task { @MainActor in
                    if activeBatchSubmission?.signature == signature {
                        activeBatchSubmission = nil
                    }
                }
            }

            guard ProFeatureGate.canBatchDownload(count: jobs.count) else {
                onUpgradeRequired()
                return
            }

            guard await LicenseManager.shared.preflight(count: jobs.count) else {
                onUpgradeRequired()
                return
            }

            let context = downloadJobContext
            for (index, job) in jobs.enumerated() {
                do {
                    let resolution = try await DownloadResolver.resolve(requestedUrl: job.url, in: currentResults)
                    guard ProFeatureGate.canDownloadAudio || !resolution.isAudio else {
                        onUpgradeRequired()
                        return
                    }
                    DownloadJobRunner.shared.start(resolution: resolution, target: selectedTarget, context: context)
                    await MainActor.run {
                        if var submission = activeBatchSubmission, submission.signature == signature {
                            submission.progressText = "\(selectedTarget.homeBatchButtonTitle) \(index + 1)/\(jobs.count)"
                            activeBatchSubmission = submission
                        }
                    }
                } catch {
                    tracker.projectFailure(url: job.url, target: selectedTarget, message: error.localizedDescription)
                    NotificationManager.shared.notifyUploadFailed(filename: job.uploadFileName, reason: error.localizedDescription)
                }
            }
        }
    }

    private func requestBatchQueueAll() {
        if isLoading {
            queueAllWhenExtractionCompletes = true
            return
        }
        batchQueueAll()
    }

    private func batchQueueAll() {
        let jobs = batchQueueJobs
        guard !jobs.isEmpty,
              let signature = currentBatchSignature,
              activeBatchSubmission?.signature != signature else { return }
        let selectedTarget = batchTarget
        activeBatchSubmission = BatchSubmission(
            signature: signature,
            progressText: "Queueing 0/\(jobs.count)..."
        )

        Task {
            defer {
                Task { @MainActor in
                    if activeBatchSubmission?.signature == signature {
                        activeBatchSubmission = nil
                    }
                }
            }

            let context = downloadJobContext
            for (index, job) in jobs.enumerated() {
                DownloadJobRunner.shared.queue(
                    sourcePageURL: job.sourcePageURL,
                    preferredQualityLabel: job.qualityLabel,
                    title: job.title ?? job.displayName,
                    target: selectedTarget,
                    context: context
                )
                await MainActor.run {
                    if var submission = activeBatchSubmission, submission.signature == signature {
                        submission.progressText = "Queueing \(index + 1)/\(jobs.count)"
                        activeBatchSubmission = submission
                    }
                }
            }
        }
    }

    private func startDownload(url: String, cloud: CloudTarget) async {
        await startDownload(url: url, destinations: [cloud])
    }

    private func queueDownload(url: String, target: CloudTarget) async {
        guard let result = results.first(where: {
            $0.source?.mp4 == url || $0.source?.hls.contains(where: { $0.url == url }) == true
        }), let source = result.source else { return }
        let qualityLabel = source.hls.first(where: { $0.url == url })?.label ?? "Video"
        DownloadJobRunner.shared.queue(
            sourcePageURL: result.url,
            preferredQualityLabel: qualityLabel,
            title: source.title ?? displayName(for: url),
            target: target,
            context: downloadJobContext
        )
    }

    private func startDownload(url: String, destinations: Set<CloudTarget>) async {
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
            for destination in destinations {
                DownloadJobRunner.shared.start(resolution: resolution, target: destination, context: downloadJobContext)
            }
        } catch {
            for destination in destinations {
                tracker.projectFailure(url: url, target: destination, message: error.localizedDescription)
                NotificationManager.shared.notifyUploadFailed(filename: uploadFileName(for: url), reason: error.localizedDescription)
            }
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

    private func hasExistingQueueItem(for url: String, target: CloudTarget) -> Bool {
        downloadQueue.queue.contains { item in
            item.url == url &&
                item.targetCloud == target &&
                !isFailedStatus(item.status)
        }
    }

    private func isFailedStatus(_ status: QueueStatus) -> Bool {
        if case .failed = status {
            return true
        }
        return false
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
