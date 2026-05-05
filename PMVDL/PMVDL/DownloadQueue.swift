import Foundation

@MainActor
class DownloadQueue: ObservableObject {
    static let shared = DownloadQueue()

    @Published var queue: [DownloadQueueItem] = []
    private var maxConcurrent = 3
    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    private let userDefaultsKey = "downloadQueue"

    private init() {
        load()
        // Resume pending/failed items as pending
        for i in queue.indices {
            if case .downloading = queue[i].status { queue[i].status = .pending }
            if case .verifying = queue[i].status { queue[i].status = .pending }
            if case .uploading = queue[i].status { queue[i].uploadStarted = true }
            if case .paused = queue[i].status { /* keep paused */ }
        }
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
        queue[idx].megatag = nil
        save()
        return true
    }

    func remove(_ item: DownloadQueueItem) {
        queue.removeAll { $0.id == item.id }
        cancelTask(for: item.id)
        save()
    }

    func remove(id: UUID) {
        queue.removeAll { $0.id == id }
        cancelTask(for: id)
        save()
    }

    func pause(_ item: DownloadQueueItem) {
        guard let idx = queue.firstIndex(where: { $0.id == item.id }) else { return }
        // Failed items are retried via the Retry button, not paused/resumed.
        switch queue[idx].status {
        case .downloading, .verifying, .uploading, .pending:
            queue[idx].status = .paused
        default:
            break
        }
        cancelTask(for: item.id)
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
        }
        for task in runningTasks.values { task.cancel() }
        runningTasks.removeAll()
        save()
    }

    func resumeAll() {
        // Only resume explicitly paused items. Failed items are retried via resetForRetry/Retry button.
        for i in queue.indices where queue[i].status == .paused {
            queue[i].status = .pending
            queue[i].progress = 0
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

    func update(id: UUID, status: QueueStatus, progress: Double, message: String? = nil) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let previousStatus = queue[idx].status
        let previousUploadStarted = queue[idx].uploadStarted
        let previousMessage = queue[idx].statusMessage
        if status == .uploading {
            queue[idx].uploadStarted = true
        }
        queue[idx].status = status
        queue[idx].progress = progress
        queue[idx].statusMessage = message
        if previousStatus != status || previousUploadStarted != queue[idx].uploadStarted || previousMessage != message || status.isTerminal {
            save()
        }
    }

    func complete(id: UUID, finalPath: String?, message: String) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[idx].status = .completed
        queue[idx].progress = 100
        queue[idx].statusMessage = message
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
        save()
    }

    func item(id: UUID) -> DownloadQueueItem? {
        queue.first { $0.id == id }
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

    private func cancelTask(for id: UUID) {
        runningTasks[id]?.cancel()
        runningTasks[id] = nil
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
