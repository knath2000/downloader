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

    func add(url: String, quality: String, targetCloud: CloudTarget = .mega, displayTitle: String? = nil) -> UUID {
        let item = DownloadQueueItem(url: url, quality: quality, targetCloud: targetCloud, displayTitle: displayTitle)
        queue.append(item)
        save()
        processNextIfNeeded()
        return item.id
    }

    func remove(_ item: DownloadQueueItem) {
        queue.removeAll { $0.id == item.id }
        cancelTask(for: item.id)
        save()
    }

    func pause(_ item: DownloadQueueItem) {
        guard let idx = queue.firstIndex(where: { $0.id == item.id }) else { return }
        if case .failed = queue[idx].status { queue[idx].status = .paused }
        else if case .downloading = queue[idx].status, case .uploading = queue[idx].status {
            queue[idx].status = .paused
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
        for i in queue.indices where queue[i].status == .paused || queue[i].status == .failed("") {
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
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[idx].status = status
        queue[idx].progress = progress
        save()
    }

    private func cancelTask(for id: UUID) {
        runningTasks[id]?.cancel()
        runningTasks[id] = nil
    }

    private var activeCount: Int {
        queue.filter { item in
            switch item.status {
            case .downloading, .uploading: return true
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
