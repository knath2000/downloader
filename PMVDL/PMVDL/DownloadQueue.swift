import Combine
import Foundation

enum AppPreferenceKeys {
    static let preventSleepWhileRunning = "preventSleepWhileRunning"
}

enum SleepPreventionPolicy {
    static func shouldPreventSleep(isEnabled: Bool, items: [DownloadQueueItem]) -> Bool {
        isEnabled && items.contains { isRunningStatus($0.status) }
    }

    static func isRunningStatus(_ status: QueueStatus) -> Bool {
        switch status {
        case .downloading, .verifying, .uploading, .processing:
            return true
        case .pending, .waiting, .completed, .paused, .failed:
            return false
        }
    }
}

@MainActor
final class SleepPreventionManager {
    static let shared = SleepPreventionManager()

    private var activity: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    private init() {}

    func start() {
        guard cancellables.isEmpty else {
            update()
            return
        }

        DownloadQueue.shared.$queue
            .sink { [weak self] _ in
                self?.update()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                self?.update()
            }
            .store(in: &cancellables)

        update()
    }

    func update() {
        let shouldPreventSleep = SleepPreventionPolicy.shouldPreventSleep(
            isEnabled: UserDefaults.standard.bool(forKey: AppPreferenceKeys.preventSleepWhileRunning),
            items: DownloadQueue.shared.queue
        )

        if shouldPreventSleep {
            begin()
        } else {
            end()
        }
    }

    func stop() {
        end()
        cancellables.removeAll()
    }

    private func begin() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,
                .idleSystemSleepDisabled,
                .idleDisplaySleepDisabled,
                .automaticTerminationDisabled,
                .suddenTerminationDisabled
            ],
            reason: "VidDL downloads are running"
        )
    }

    private func end() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}

enum DownloadQueueManualStartPolicy {
    static func canStartNow(_ item: DownloadQueueItem, isPro: Bool) -> Bool {
        isPro && (item.status == .pending || item.status == .waiting) && item.retryPayload != nil
    }
}

@MainActor
class DownloadQueue: ObservableObject {
    static let shared = DownloadQueue()

    @Published var queue: [DownloadQueueItem] = []
    private var maxConcurrent: Int { ProFeatureGate.concurrentDownloadLimit }

    private let userDefaultsKey = "downloadQueue"
    private let restartMessage = "Resuming after app restart…"
    private let retryMessage = "Retrying…"
    private let progressPublishInterval: TimeInterval = 0.25
    private let progressPersistDelay: UInt64 = 1_000_000_000
    private var lastProgressUpdateAt: [UUID: Date] = [:]
    private var pendingProgressSaveTask: Task<Void, Never>?

    var concurrentLimit: Int { maxConcurrent }

    private init() {
        load()
        let didNormalize = normalizeInterruptedItemsForLaunch()
        if didNormalize {
            persistQueueSnapshot()
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([DownloadQueueItem].self, from: data) {
            queue = decoded
        }
    }

    func save() {
        persistQueueSnapshot()
        LibraryPipelineStore.shared.rebuild(queueItems: queue)
    }

    private func persistQueueSnapshot() {
        if let encoded = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    @discardableResult
    func normalizeInterruptedItemsForLaunch() -> Bool {
        var didChange = false
        for i in queue.indices {
            switch queue[i].status {
            case .processing:
                let message = "Processing was interrupted and must be started again."
                queue[i].status = .failed(message)
                queue[i].progress = 0
                queue[i].bytesPerSecond = nil
                queue[i].statusMessage = message
                didChange = true
            case .downloading, .verifying, .uploading:
                let wasUploading = queue[i].status == .uploading
                if queue[i].retryPayload != nil {
                    queue[i].status = .waiting
                    queue[i].progress = 0
                    queue[i].bytesPerSecond = nil
                    queue[i].statusMessage = restartMessage
                    if wasUploading {
                        queue[i].uploadStarted = true
                    }
                    if queue[i].targetCloud == .seedbox {
                        queue[i].resumeStrategy = .remoteSafeNewFile
                    }
                } else {
                    let message = "Interrupted and cannot resume because retry metadata is missing."
                    queue[i].status = .failed(message)
                    queue[i].progress = 0
                    queue[i].bytesPerSecond = nil
                    queue[i].statusMessage = message
                }
                didChange = true
            case .paused, .pending, .waiting, .completed, .failed:
                break
            }
        }
        return didChange
    }

    func add(
        url: String,
        quality: String,
        targetCloud: CloudTarget = .mega,
        displayTitle: String? = nil,
        retryPayload: DownloadRetryPayload? = nil
    ) -> UUID {
        let item = DownloadQueueItem(
            url: url,
            quality: quality,
            targetCloud: targetCloud,
            displayTitle: displayTitle,
            retryPayload: retryPayload
        )
        queue.append(item)
        save()
        processNextIfNeeded()
        return item.id
    }

    @discardableResult
    func addQueued(_ items: [DownloadQueueItem]) -> [UUID] {
        guard !items.isEmpty else { return [] }
        queue.append(contentsOf: items)
        save()
        return items.map(\.id)
    }

    @discardableResult
    func addFailed(
        url: String,
        quality: String,
        targetCloud: CloudTarget = .local,
        displayTitle: String? = nil,
        message: String,
        itemKind: DownloadQueueItemKind? = nil
    ) -> UUID {
        var item = DownloadQueueItem(
            url: url,
            quality: quality,
            targetCloud: targetCloud,
            displayTitle: displayTitle
        )
        item.status = .failed(message)
        item.statusMessage = message
        item.itemKind = itemKind
        queue.append(item)
        save()
        return item.id
    }

    func addProcessing(
        url: String,
        quality: String,
        displayTitle: String,
        message: String = "Checking encoder…"
    ) -> UUID {
        var item = DownloadQueueItem(
            url: url,
            quality: quality,
            targetCloud: .local,
            displayTitle: displayTitle,
            retryPayload: nil
        )
        item.status = .processing
        item.progress = 0
        item.statusMessage = message
        item.itemKind = .processing
        queue.append(item)
        save()
        return item.id
    }

    /// Resets a failed queue item back to pending so `DownloadJobRunner` can re-run it.
    /// Returns false if the item does not exist or is not retryable.
    @discardableResult
    func resetForRetry(id: UUID) -> Bool {
        guard let idx = queue.firstIndex(where: { $0.id == id }),
              queue[idx].canRetry else { return false }
        queue[idx].status = .waiting
        queue[idx].progress = 0
        queue[idx].finalPath = nil
        queue[idx].uploadStarted = nil
        queue[idx].statusMessage = "Retrying…"
        queue[idx].bytesDownloaded = nil
        queue[idx].totalBytes = nil
        queue[idx].bytesPerSecond = nil
        queue[idx].expectedTotalBytes = nil
        queue[idx].megatag = nil
        save()
        return true
    }

    @discardableResult
    func resetForResume(id: UUID) -> Bool {
        guard let idx = queue.firstIndex(where: { $0.id == id }),
              queue[idx].status == .paused,
              queue[idx].retryPayload != nil else { return false }
        queue[idx].status = .waiting
        queue[idx].progress = 0
        queue[idx].finalPath = nil
        queue[idx].uploadStarted = nil
        queue[idx].statusMessage = "Resuming..."
        queue[idx].bytesDownloaded = nil
        queue[idx].totalBytes = nil
        queue[idx].bytesPerSecond = nil
        queue[idx].expectedTotalBytes = nil
        queue[idx].megatag = nil
        save()
        return true
    }

    func remove(_ item: DownloadQueueItem) {
        if let current = queue.first(where: { $0.id == item.id }),
           !current.status.isTerminal {
            cancelActiveWork(id: item.id, status: current.status)
        }
        lastProgressUpdateAt[item.id] = nil
        queue.removeAll { $0.id == item.id }
        save()
    }

    func remove(id: UUID) {
        if let current = queue.first(where: { $0.id == id }),
           !current.status.isTerminal {
            cancelActiveWork(id: id, status: current.status)
        }
        lastProgressUpdateAt[id] = nil
        queue.removeAll { $0.id == id }
        save()
    }

    func pause(_ item: DownloadQueueItem) {
        guard let idx = queue.firstIndex(where: { $0.id == item.id }) else { return }
        var shouldPauseRunner = false
        switch queue[idx].status {
        case .pending, .waiting, .downloading, .verifying, .uploading:
            queue[idx].status = .paused
            queue[idx].bytesPerSecond = nil
            queue[idx].statusMessage = "Paused"
            shouldPauseRunner = true
        default:
            break
        }
        guard shouldPauseRunner else { return }
        DownloadJobRunner.shared.pause(queueId: item.id)
        save()
    }

    func resume(_ item: DownloadQueueItem) {
        guard let idx = queue.firstIndex(where: { $0.id == item.id }) else { return }
        guard let payload = queue[idx].retryPayload else { return }
        DownloadJobRunner.shared.startResume(
            queueId: item.id,
            payload: payload,
            seedboxWebdavPassword: SecureStore.string(forKey: "seedboxWebdavPassword") ?? ""
        )
    }

    @discardableResult
    func startNow(_ item: DownloadQueueItem, seedboxWebdavPassword: String) -> Bool {
        guard let current = self.item(id: item.id),
              DownloadQueueManualStartPolicy.canStartNow(current, isPro: ProFeatureGate.isPro),
              let payload = current.retryPayload else { return false }
        DownloadJobRunner.shared.startQueuedNow(
            queueId: current.id,
            payload: payload,
            seedboxWebdavPassword: seedboxWebdavPassword
        )
        return true
    }

    func moveUp(_ item: DownloadQueueItem) {
        guard let idx = queue.firstIndex(where: { $0.id == item.id }), idx > 0 else { return }
        queue.swapAt(idx, idx - 1)
        save()
    }

    func moveDown(_ item: DownloadQueueItem) {
        guard let idx = queue.firstIndex(where: { $0.id == item.id }), idx < queue.count - 1 else { return }
        queue.swapAt(idx, idx + 1)
        save()
    }

    func pauseAll() {
        for i in queue.indices where !queue[i].status.isTerminal && queue[i].status != .processing {
            queue[i].status = .paused
            queue[i].bytesPerSecond = nil
            queue[i].statusMessage = "Paused"
            DownloadJobRunner.shared.pause(queueId: queue[i].id)
        }
        save()
    }

    func pauseQueued() {
        for i in queue.indices where queue[i].status == .pending || queue[i].status == .waiting {
            queue[i].status = .paused
            queue[i].bytesPerSecond = nil
            queue[i].statusMessage = "Paused"
            DownloadJobRunner.shared.pause(queueId: queue[i].id)
        }
        save()
    }

    func resumeAll() {
        // Only resume explicitly paused items. Failed items are retried via resetForRetry/Retry button.
        for i in queue.indices where queue[i].status == .paused {
            queue[i].status = .waiting
            queue[i].progress = 0
            queue[i].bytesDownloaded = nil
            queue[i].bytesPerSecond = nil
        }
        save()
        processNextIfNeeded()
    }

    func clearCompleted() {
        let completedIDs = queue.filter { $0.status.isTerminal }.map(\.id)
        completedIDs.forEach { lastProgressUpdateAt[$0] = nil }
        queue.removeAll { $0.status.isTerminal }
        save()
    }

    @discardableResult
    func updateProgress(id: UUID, status: QueueStatus, progress: Double) -> Bool {
        update(id: id, status: status, progress: progress, message: nil)
    }

    @discardableResult
    func update(
        id: UUID,
        status: QueueStatus,
        progress: Double,
        message: String? = nil,
        metrics: DownloadTransferMetrics? = nil
    ) -> Bool {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return false }
        let previousStatus = queue[idx].status
        let previousUploadStarted = queue[idx].uploadStarted
        let previousMessage = queue[idx].statusMessage
        let previousProgress = queue[idx].progress
        let previousBytesDownloaded = queue[idx].bytesDownloaded
        let previousTotalBytes = queue[idx].totalBytes
        let previousBytesPerSecond = queue[idx].bytesPerSecond
        let parsedMetrics = metrics ?? message.flatMap { DownloadProgressParsers.transferMetrics(from: $0) }
        let nextUploadStarted = status == .uploading ? true : previousUploadStarted
        let nextBytesDownloaded = parsedMetrics?.bytesDownloaded ?? previousBytesDownloaded
        let nextTotalBytes = parsedMetrics?.totalBytes ?? previousTotalBytes
        let nextBytesPerSecond = parsedMetrics?.bytesPerSecond ?? previousBytesPerSecond
        let statusChanged = previousStatus != status
        let uploadStartedChanged = previousUploadStarted != nextUploadStarted
        let messageChanged = previousMessage != message
        let metricsChanged = previousBytesDownloaded != nextBytesDownloaded ||
            previousTotalBytes != nextTotalBytes ||
            previousBytesPerSecond != nextBytesPerSecond
        let progressDelta = abs(progress - previousProgress)
        let now = Date()
        let lastUpdate = lastProgressUpdateAt[id] ?? .distantPast
        let enoughTimeElapsed = now.timeIntervalSince(lastUpdate) >= progressPublishInterval
        let shouldPublish = statusChanged ||
            uploadStartedChanged ||
            status.isTerminal ||
            progressDelta >= 1 ||
            (enoughTimeElapsed && (progressDelta > 0 || messageChanged || metricsChanged))
        guard shouldPublish else { return false }

        queue[idx].uploadStarted = nextUploadStarted
        queue[idx].status = status
        queue[idx].progress = progress
        queue[idx].statusMessage = message
        queue[idx].bytesDownloaded = nextBytesDownloaded
        queue[idx].totalBytes = nextTotalBytes
        queue[idx].bytesPerSecond = nextBytesPerSecond
        if let totalBytes = nextTotalBytes {
            queue[idx].expectedTotalBytes = totalBytes
        }
        lastProgressUpdateAt[id] = now

        if statusChanged || uploadStartedChanged || status.isTerminal {
            save()
        } else {
            scheduleProgressSave()
        }
        return true
    }

    func complete(id: UUID, finalPath: String?, message: String) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[idx].status = .completed
        queue[idx].progress = 100
        queue[idx].statusMessage = message
        queue[idx].bytesPerSecond = nil
        queue[idx].finalPath = finalPath
        lastProgressUpdateAt[id] = nil
        save()
    }

    func fail(id: UUID, error: Error) {
        fail(id: id, message: error.localizedDescription)
    }

    func fail(id: UUID, message: String) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[idx].status = .failed(message)
        queue[idx].progress = 0
        queue[idx].statusMessage = message
        queue[idx].bytesPerSecond = nil
        lastProgressUpdateAt[id] = nil
        save()
    }

    func item(id: UUID) -> DownloadQueueItem? {
        queue.first { $0.id == id }
    }

    func updateResumeState(
        id: UUID,
        partialLocalPath: String? = nil,
        expectedTotalBytes: Int64? = nil,
        supportsByteRange: Bool? = nil,
        resumeStrategy: DownloadResumeStrategy? = nil
    ) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        if let partialLocalPath { queue[idx].partialLocalPath = partialLocalPath }
        if let expectedTotalBytes { queue[idx].expectedTotalBytes = expectedTotalBytes }
        if let supportsByteRange { queue[idx].supportsByteRange = supportsByteRange }
        if let resumeStrategy { queue[idx].resumeStrategy = resumeStrategy }
        save()
    }

    func resumeInterruptedOnLaunch(seedboxWebdavPassword: String = "") {
        let resumable = queue.filter { item in
            item.status == .waiting &&
            item.retryPayload != nil
        }
        guard !resumable.isEmpty else { return }
        for item in resumable {
            guard let payload = item.retryPayload else { continue }
            DownloadJobRunner.shared.startInterruptedResume(
                queueId: item.id,
                payload: payload,
                seedboxWebdavPassword: seedboxWebdavPassword
            )
        }
    }

    func latestFinalPath(for url: String, target: CloudTarget) -> String? {
        queue
            .filter { $0.url == url && $0.targetCloud == target }
            .sorted { $0.createdAt > $1.createdAt }
            .first(where: { $0.finalPath != nil })?
            .finalPath
    }

    func projectedState(for item: DownloadQueueItem) -> UploadState? {
        let message = item.statusMessage
        switch item.status {
        case .pending:
            return .uploading(message ?? "Queued")
        case .waiting:
            return .uploading(message ?? "Waiting to start")
        case .downloading, .verifying, .uploading, .processing:
            return .uploading(message ?? statusLabel(for: item))
        case .completed:
            return .done(message ?? "Done")
        case .failed(let reason):
            return .failed(reason.isEmpty ? (message ?? "Failed") : reason)
        case .paused:
            return .uploading(message ?? "Paused")
        }
    }

    private func statusLabel(for item: DownloadQueueItem) -> String {
        switch item.status {
        case .downloading:
            return String(format: "Downloading… %.0f%%", item.progress)
        case .verifying:
            return "Verifying video…"
        case .uploading:
            return String(format: "Uploading… %.0f%%", item.progress)
        case .processing:
            return String(format: "Processing… %.0f%%", item.progress)
        default:
            return item.statusMessage ?? ""
        }
    }

    var activeDownloadCount: Int {
        queue.filter { item in
            switch item.status {
            case .downloading, .verifying, .uploading, .processing: return true
            default: return false
            }
        }.count
    }

    func processNextIfNeeded() {
        DownloadJobRunner.shared.processNextIfNeeded()
    }

    private func cancelActiveWork(id: UUID, status: QueueStatus) {
        if status == .processing {
            VideoProcessingLauncher.cancel(queueId: id)
        } else {
            DownloadJobRunner.shared.cancel(queueId: id)
        }
    }

    private func scheduleProgressSave() {
        guard pendingProgressSaveTask == nil else { return }
        pendingProgressSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: progressPersistDelay)
            save()
            pendingProgressSaveTask = nil
        }
    }
}
