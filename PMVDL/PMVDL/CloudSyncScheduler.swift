import Foundation

/// Throttles CloudKit writes. Batches changes and writes every 30 seconds.
@MainActor
class CloudSyncScheduler {
    static let shared = CloudSyncScheduler()

    private var timer: Timer?
    private var pendingWrites = 0
    private let throttleInterval: TimeInterval = 30

    private init() {
        start()
    }

    func start() {
        guard timer == nil, CloudKitManager.shared.isSyncEnabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: throttleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.flush() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Mark that local data has changed — will be flushed on next tick.
    func markDirty() {
        pendingWrites += 1
        // Also flush immediately if we haven't flushed in a while
        if pendingWrites >= 10 { flushNow() }
    }

    private func flush() async {
        guard pendingWrites > 0 else { return }
        let writes = pendingWrites
        pendingWrites = 0
        await CloudKitManager.shared.pushLocalState()
    }

    private func flushNow() {
        guard pendingWrites > 0 else { return }
        pendingWrites = 0
        Task { await CloudKitManager.shared.pushLocalState() }
    }
}
