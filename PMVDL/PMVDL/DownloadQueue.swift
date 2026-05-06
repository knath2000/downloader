import Foundation

@MainActor
class DownloadQueue: ObservableObject {
    static let shared = DownloadQueue()

    @Published var queue: [DownloadQueueItem] = []
    private var maxConcurrent: Int { ProFeatureGate.concurrentDownloadLimit }

    private let userDefaultsKey = "downloadQueue"
    private let restartMessage = "Resuming after app restart…"

    var concurrentLimit: Int { maxConcurrent }

    private init() {
        load()
        normalizeInterruptedItemsForLaunch()
        save()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([DownloadQueueItem].self, from: data) {
            queue = decoded
        }
    }

    func save() {
        if let encoded = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    func normalizeInterruptedItemsForLaunch() {
        for i in queue.indices {
            switch queue[i].status {
            case .downloading, .verifying, .uploading:
                let wasUploading = queue[i].status == .uploading
                if queue[i].retryPayload != nil {
                    queue[i].status = .pending
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
            case .paused, .pending, .completed, .failed:
                break
            }
        }
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

    /// Resets a failed queue item back to pending so `DownloadJobRunner` can re-run it.
    /// Returns false if the item does not exist or is not retryable.
    @discardableResult
    func resetForRetry(id: UUID) -> Bool {
        guard let idx = queue.firstIndex(where: { $0.id == id }),
              queue[idx].canRetry else { return false }
        queue[idx].status = .pending
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
        queue[idx].status = .pending
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
            DownloadJobRunner.shared.cancel(queueId: item.id)
        }
        queue.removeAll { $0.id == item.id }
        save()
    }

    func remove(id: UUID) {
        if let current = queue.first(where: { $0.id == id }),
           !current.status.isTerminal {
            DownloadJobRunner.shared.cancel(queueId: id)
        }
        queue.removeAll { $0.id == id }
        save()
    }

    func pause(_ item: DownloadQueueItem) {
        guard let idx = queue.firstIndex(where: { $0.id == item.id }) else { return }
        // Failed items are retried via the Retry button, not paused/resumed.
        switch queue[idx].status {
        case .downloading, .verifying, .uploading, .pending:
            queue[idx].status = .paused
            queue[idx].bytesPerSecond = nil
            queue[idx].statusMessage = "Paused"
        default:
            break
        }
        DownloadJobRunner.shared.pause(queueId: item.id)
        save()
    }

    func resume(_ item: DownloadQueueItem) {
        guard let idx = queue.firstIndex(where: { $0.id == item.id }) else { return }
        queue[idx].status = .pending
        queue[idx].progress = 0
        save()
        processNextIfNeeded()
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
        for i in queue.indices where !queue[i].status.isTerminal {
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
            queue[i].status = .pending
            queue[i].progress = 0
            queue[i].bytesDownloaded = nil
            queue[i].bytesPerSecond = nil
        }
        save()
        processNextIfNeeded()
    }

    func clearCompleted() {
        queue.removeAll { $0.status.isTerminal }
        save()
    }

    func updateProgress(id: UUID, status: QueueStatus, progress: Double) {
        update(id: id, status: status, progress: progress, message: nil)
    }

    func update(
        id: UUID,
        status: QueueStatus,
        progress: Double,
        message: String? = nil,
        metrics: DownloadTransferMetrics? = nil
    ) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let previousStatus = queue[idx].status
        let previousUploadStarted = queue[idx].uploadStarted
        let previousMessage = queue[idx].statusMessage
        let previousBytesDownloaded = queue[idx].bytesDownloaded
        let previousTotalBytes = queue[idx].totalBytes
        let parsedMetrics = metrics ?? message.flatMap { DownloadProgressParsers.transferMetrics(from: $0) }
        if status == .uploading {
            queue[idx].uploadStarted = true
        }
        queue[idx].status = status
        queue[idx].progress = progress
        queue[idx].statusMessage = message
        if let bytesDownloaded = parsedMetrics?.bytesDownloaded {
            queue[idx].bytesDownloaded = bytesDownloaded
        }
        if let totalBytes = parsedMetrics?.totalBytes {
            queue[idx].totalBytes = totalBytes
            queue[idx].expectedTotalBytes = totalBytes
        }
        if let bytesPerSecond = parsedMetrics?.bytesPerSecond {
            queue[idx].bytesPerSecond = bytesPerSecond
        }
        if previousStatus != status ||
            previousUploadStarted != queue[idx].uploadStarted ||
            previousMessage != message ||
            previousBytesDownloaded != queue[idx].bytesDownloaded ||
            previousTotalBytes != queue[idx].totalBytes ||
            status.isTerminal {
            save()
        }
    }

    func complete(id: UUID, finalPath: String?, message: String) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[idx].status = .completed
        queue[idx].progress = 100
        queue[idx].statusMessage = message
        queue[idx].bytesPerSecond = nil
        queue[idx].finalPath = finalPath
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
            item.status == .pending &&
            item.retryPayload != nil &&
            item.statusMessage == restartMessage
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
        case .downloading, .verifying, .uploading:
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
        default:
            return item.statusMessage ?? ""
        }
    }

    private var activeCount: Int {
        queue.filter { item in
            switch item.status {
            case .downloading, .verifying, .uploading: return true
            default: return false
            }
        }.count
    }

    func processNextIfNeeded() {
        // Will be called from ContentView batch download logic
        // The actual processing is handled by the calling code
        // This just tracks the state
    }
}
