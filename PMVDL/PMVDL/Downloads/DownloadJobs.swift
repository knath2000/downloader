import AppKit
import Foundation

struct DownloadJobContext {
    let megaRemotePath: String
    let gdriveRemoteName: String
    let gdriveRemotePath: String
    let seedboxTransferMode: String
    let seedboxRemoteName: String
    let seedboxRemotePath: String
    let seedboxWebdavURL: String
    let seedboxWebdavUser: String
    let seedboxWebdavPassword: String

    init(
        megaRemotePath: String,
        gdriveRemoteName: String,
        gdriveRemotePath: String,
        seedboxTransferMode: String = "rclone",
        seedboxRemoteName: String = "seedbox",
        seedboxRemotePath: String = "/",
        seedboxWebdavURL: String = "",
        seedboxWebdavUser: String = "",
        seedboxWebdavPassword: String = ""
    ) {
        self.megaRemotePath = megaRemotePath
        self.gdriveRemoteName = gdriveRemoteName
        self.gdriveRemotePath = gdriveRemotePath
        self.seedboxTransferMode = seedboxTransferMode
        self.seedboxRemoteName = seedboxRemoteName
        self.seedboxRemotePath = seedboxRemotePath
        self.seedboxWebdavURL = seedboxWebdavURL
        self.seedboxWebdavUser = seedboxWebdavUser
        self.seedboxWebdavPassword = seedboxWebdavPassword
    }
}

extension DownloadJobContext {
    /// Build a secret-free retry context from the current job context.
    var retryContext: DownloadRetryContext {
        DownloadRetryContext(
            megaRemotePath: megaRemotePath,
            gdriveRemoteName: gdriveRemoteName,
            gdriveRemotePath: gdriveRemotePath,
            seedboxTransferMode: seedboxTransferMode,
            seedboxRemoteName: seedboxRemoteName,
            seedboxRemotePath: seedboxRemotePath,
            seedboxWebdavURL: seedboxWebdavURL,
            seedboxWebdavUser: seedboxWebdavUser
        )
    }
}

extension DownloadRetryContext {
    /// Reconstruct a full DownloadJobContext by injecting the current credential at retry time.
    func materialize(seedboxWebdavPassword: String) -> DownloadJobContext {
        let resolvedSeedboxWebdavPassword = seedboxWebdavPassword.isEmpty
            ? (SecureStore.string(forKey: "seedboxWebdavPassword") ?? "")
            : seedboxWebdavPassword
        return DownloadJobContext(
            megaRemotePath: megaRemotePath,
            gdriveRemoteName: gdriveRemoteName,
            gdriveRemotePath: gdriveRemotePath,
            seedboxTransferMode: seedboxTransferMode,
            seedboxRemoteName: seedboxRemoteName,
            seedboxRemotePath: seedboxRemotePath,
            seedboxWebdavURL: seedboxWebdavURL,
            seedboxWebdavUser: seedboxWebdavUser,
            seedboxWebdavPassword: resolvedSeedboxWebdavPassword
        )
    }
}

enum JobEvent {
    case progress(QueueStatus, Double, String, DownloadTransferMetrics? = nil)
}

struct JobCompletion {
    let finalPath: String?
    let notificationFilename: String
    let notificationDestination: String
    let completedUploadDestination: String?
    let completedUploadRemotePath: String?
    let revealURL: URL?
    let removeQueueItem: Bool
}

protocol DownloadJob {
    var queueId: UUID { get }
    var resolution: DownloadResolution { get }
    func run(onEvent: @escaping (JobEvent) -> Void) async throws -> JobCompletion
}

@MainActor
final class DownloadJobRunner {
    static let shared = DownloadJobRunner()

    private enum RunOutcome {
        case finished(Bool)
        case retryScheduled
    }

    private struct QueuedRun {
        let payload: DownloadRetryPayload
        let seedboxWebdavPassword: String
        let refreshSource: Bool
    }

    private var queuedRuns: [UUID: QueuedRun] = [:]
    private var startingQueueIDs: Set<UUID> = []
    private var runningTasks: [UUID: Task<RunOutcome, Never>] = [:]
    private var runningTokens: [UUID: UUID] = [:]
    private var retryWakeTasks: [UUID: Task<Void, Never>] = [:]
    private var awaitedResultIDs: Set<UUID> = []
    private var resultWaiters: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    private var completedResults: [UUID: Bool] = [:]
    private var pausedQueueIDs: Set<UUID> = []
    private var cancelledQueueIDs: Set<UUID> = []

    private init() {}

    // MARK: - Public entry points

    @discardableResult
    func start(resolution: DownloadResolution, target: CloudTarget, context: DownloadJobContext) -> UUID {
        enqueue(resolution: resolution, target: target, context: context)
    }

    @discardableResult
    func queue(resolution: DownloadResolution, target: CloudTarget, context: DownloadJobContext) -> UUID {
        queue(resolutions: [resolution], target: target, context: context)[0]
    }

    @discardableResult
    func queue(resolutions: [DownloadResolution], target: CloudTarget, context: DownloadJobContext) -> [UUID] {
        resolutions.map { enqueueAgent(resolution: $0, target: target, context: context) }
    }

    @discardableResult
    func queue(
        sourcePageURL: String,
        preferredQualityLabel: String?,
        title: String,
        target: CloudTarget,
        context: DownloadJobContext,
        selector: LustreAgentQualitySelector? = nil
    ) -> UUID {
        let payload = DownloadRetryPayload(
            sourcePageURL: sourcePageURL,
            preferredQualityLabel: preferredQualityLabel,
            title: title,
            target: target,
            context: context.retryContext
        )
        let queueID = UUID()
        DownloadQueue.shared.addAgentOwned(
            id: queueID,
            url: sourcePageURL,
            quality: preferredQualityLabel ?? "Video",
            targetCloud: target,
            displayTitle: title,
            retryPayload: payload
        )
        Task {
            await LustreAgentController.shared.enqueue(
                id: queueID,
                sourcePageURL: sourcePageURL,
                title: title,
                preferredQualityLabel: preferredQualityLabel,
                target: target,
                gdriveRemoteName: context.gdriveRemoteName,
                gdriveRemotePath: context.gdriveRemotePath,
                selector: selector
            )
        }
        return queueID
    }

    func run(resolution: DownloadResolution, target: CloudTarget, context: DownloadJobContext) async -> Bool {
        if DestinationAvailabilityPolicy.canCreateNewJob(for: target) {
            _ = enqueueAgent(resolution: resolution, target: target, context: context)
            return true
        }
        let queueId = enqueue(resolution: resolution, target: target, context: context, waitsForResult: true)
        return await waitForResult(queueId: queueId)
    }

    /// Fire-and-forget wrapper called from the Downloads UI Retry button.
    func startRetry(queueId: UUID, payload: DownloadRetryPayload, seedboxWebdavPassword: String) {
        Task {
            _ = await retry(queueId: queueId, payload: payload, seedboxWebdavPassword: seedboxWebdavPassword)
        }
    }

    func startResume(queueId: UUID, payload: DownloadRetryPayload, seedboxWebdavPassword: String) {
        Task {
            _ = await resume(queueId: queueId, payload: payload, seedboxWebdavPassword: seedboxWebdavPassword)
        }
    }

    func startInterruptedResume(queueId: UUID, payload: DownloadRetryPayload, seedboxWebdavPassword: String) {
        enqueueExisting(queueId: queueId, payload: payload, seedboxWebdavPassword: seedboxWebdavPassword, refreshSource: true)
    }

    func startQueuedNow(queueId: UUID, payload: DownloadRetryPayload, seedboxWebdavPassword: String) {
        guard let item = DownloadQueue.shared.item(id: queueId),
              DownloadQueueManualStartPolicy.canStartNow(item, isPro: ProFeatureGate.isPro) else { return }
        cancelScheduledRetry(queueId: queueId)
        pausedQueueIDs.remove(queueId)
        cancelledQueueIDs.remove(queueId)
        DownloadQueue.shared.clearAutomaticRetryDelay(id: queueId)
        DownloadQueue.shared.update(id: queueId, status: .waiting, progress: 0, message: "Waiting to start…")
        queuedRuns[queueId] = QueuedRun(payload: payload, seedboxWebdavPassword: seedboxWebdavPassword, refreshSource: true)
        processNextIfNeeded()
    }

    func startQueuedWithFreshSource(queueId: UUID, payload: DownloadRetryPayload, seedboxWebdavPassword: String) {
        guard let item = DownloadQueue.shared.item(id: queueId), item.status == .pending || item.status == .waiting else { return }
        if item.status == .pending {
            DownloadQueue.shared.update(id: queueId, status: .waiting, progress: 0, message: "Waiting to start…")
        }
        enqueueExisting(queueId: queueId, payload: payload, seedboxWebdavPassword: seedboxWebdavPassword, refreshSource: true)
    }

    func pause(queueId: UUID) {
        if DownloadQueue.shared.item(id: queueId)?.isAgentOwned == true {
            LustreAgentController.shared.apply(.pause, id: queueId)
            return
        }
        cancelScheduledRetry(queueId: queueId)
        pausedQueueIDs.insert(queueId)
        cancelledQueueIDs.remove(queueId)
        if let task = runningTasks[queueId] {
            task.cancel()
        } else {
            cancelQueuedRun(queueId: queueId)
        }
    }

    func cancel(queueId: UUID) {
        if DownloadQueue.shared.item(id: queueId)?.isAgentOwned == true {
            LustreAgentController.shared.apply(.cancel, id: queueId)
            return
        }
        cancelScheduledRetry(queueId: queueId)
        cancelledQueueIDs.insert(queueId)
        pausedQueueIDs.remove(queueId)
        if let task = runningTasks[queueId] {
            task.cancel()
        } else {
            cancelQueuedRun(queueId: queueId)
        }
    }

    /// Resets the existing queue row and reruns the job with the original payload.
    @discardableResult
    func retry(queueId: UUID, payload: DownloadRetryPayload, seedboxWebdavPassword: String) async -> Bool {
        if let item = DownloadQueue.shared.item(id: queueId), item.isAgentOwned {
            LustreAgentController.shared.retry(
                id: queueId,
                payload: payload,
                title: item.displayTitle ?? payload.resolution.title
            )
            return true
        }
        guard DownloadQueue.shared.resetForRetry(id: queueId) else { return false }
        awaitedResultIDs.insert(queueId)
        enqueueExisting(queueId: queueId, payload: payload, seedboxWebdavPassword: seedboxWebdavPassword, refreshSource: true)
        return await waitForResult(queueId: queueId)
    }

    @discardableResult
    func resume(queueId: UUID, payload: DownloadRetryPayload, seedboxWebdavPassword: String) async -> Bool {
        if DownloadQueue.shared.item(id: queueId)?.isAgentOwned == true {
            LustreAgentController.shared.apply(.resume, id: queueId)
            return true
        }
        guard DownloadQueue.shared.resetForResume(id: queueId) else { return false }
        awaitedResultIDs.insert(queueId)
        enqueueExisting(queueId: queueId, payload: payload, seedboxWebdavPassword: seedboxWebdavPassword, refreshSource: true)
        return await waitForResult(queueId: queueId)
    }

    func processNextIfNeeded() {
        rehydrateWaitingRuns()
        let queueItems = DownloadQueue.shared.queue
        for item in queueItems {
            guard !item.isAgentOwned else { continue }
            let limit = item.targetCloud == .seedbox
                ? DownloadQueue.shared.concurrentLimit
                : ProFeatureGate.concurrentDownloadLimit
            guard inFlightCount < limit else { continue }
            guard item.status == .waiting,
                  let queuedRun = queuedRuns[item.id],
                  !pausedQueueIDs.contains(item.id),
                  !cancelledQueueIDs.contains(item.id) else {
                continue
            }
            if let delay = DownloadQueue.shared.automaticRetryDelay(for: item) {
                scheduleRetryWake(
                    queueId: item.id,
                    payload: queuedRun.payload,
                    seedboxWebdavPassword: queuedRun.seedboxWebdavPassword,
                    delay: delay
                )
                continue
            }
            startQueued(queueId: item.id)
        }
    }

    private func rehydrateWaitingRuns() {
        let seedboxWebdavPassword = SecureStore.string(forKey: "seedboxWebdavPassword") ?? ""
        for item in DownloadQueue.shared.queue where item.status == .waiting {
            guard queuedRuns[item.id] == nil,
                  !startingQueueIDs.contains(item.id),
                  runningTasks[item.id] == nil,
                  let payload = item.retryPayload else { continue }
            queuedRuns[item.id] = QueuedRun(
                payload: payload,
                seedboxWebdavPassword: seedboxWebdavPassword,
                refreshSource: true
            )
        }
    }

    // MARK: - Shared execution core

    @discardableResult
    private func enqueue(
        resolution: DownloadResolution,
        target: CloudTarget,
        context: DownloadJobContext,
        waitsForResult: Bool = false
    ) -> UUID {
        if DestinationAvailabilityPolicy.canCreateNewJob(for: target) {
            return enqueueAgent(resolution: resolution, target: target, context: context)
        }
        let payload = buildRetryPayload(for: resolution, target: target, context: context)
        let queueId = DownloadQueue.shared.add(
            url: resolution.result.url,
            quality: queueQuality(for: resolution, target: target),
            targetCloud: target,
            displayTitle: resolution.title,
            retryPayload: payload
        )
        DownloadQueue.shared.update(id: queueId, status: .waiting, progress: 0, message: "Waiting to start…")
        ActiveWorkTracker.shared.project(queueId: queueId)
        if waitsForResult {
            awaitedResultIDs.insert(queueId)
        }
        enqueueExisting(queueId: queueId, payload: payload, seedboxWebdavPassword: context.seedboxWebdavPassword)
        return queueId
    }

    private func enqueueAgent(
        resolution: DownloadResolution,
        target: CloudTarget,
        context: DownloadJobContext
    ) -> UUID {
        let id = UUID()
        let payload = buildRetryPayload(for: resolution, target: target, context: context)
        let selectedQuality = resolution.source.hls.first {
            $0.url == resolution.requestedUrl || $0.url == resolution.finalUrl
        }
        let preferredLabel = selectedQuality?.label
        let selector = LustreAgentQualitySelector(
            provider: agentProvider(for: resolution),
            mediaKind: resolution.mediaKind == .hls ? .hls : (resolution.mediaKind == .ytDlp ? .ytDlp : .direct),
            formatSelector: nil
        )
        let assisted: LustreAgentAssistedResolution?
        if (selectedQuality?.resolutionMethod ?? resolution.source.resolutionMethod ?? "")
            .localizedCaseInsensitiveContains("WebView") {
            assisted = URL(string: resolution.finalUrl).map {
                LustreAgentAssistedResolution(
                    mediaURL: $0,
                    headers: resolution.headers ?? [:],
                    mediaKind: resolution.mediaKind == .hls ? .hls : .direct,
                    title: resolution.title,
                    resolutionMethod: selectedQuality?.resolutionMethod ?? "LustreStudio browser assistance"
                )
            }
        } else {
            assisted = nil
        }
        DownloadQueue.shared.addAgentOwned(
            id: id,
            url: resolution.result.url,
            quality: queueQuality(for: resolution, target: target),
            targetCloud: target,
            displayTitle: resolution.title,
            retryPayload: payload
        )
        Task {
            await LustreAgentController.shared.enqueue(
                id: id,
                sourcePageURL: resolution.result.url,
                title: resolution.title,
                preferredQualityLabel: preferredLabel,
                target: target,
                gdriveRemoteName: context.gdriveRemoteName,
                gdriveRemotePath: context.gdriveRemotePath,
                assistedResolution: assisted,
                selector: selector
            )
        }
        return id
    }

    private func agentProvider(for resolution: DownloadResolution) -> String {
        let identity = [
            resolution.source.siteName,
            URL(string: resolution.result.url)?.host,
            URL(string: resolution.sourcePageUrl ?? "")?.host
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
        if identity.contains("pmvhaven") { return "pmvhaven" }
        if identity.contains("allpornstream") { return "allPornStream" }
        if identity.contains("hqporner") { return "hqporner" }
        if identity.contains("dood") || identity.contains("playmogo") || identity.contains("vide0") { return "doodStream" }
        if identity.contains("mydaddy") { return "myDaddy" }
        if identity.contains("mixdrop") || identity.contains("m1xdrop") { return "mixDrop" }
        if identity.contains("streamtape") { return "streamTape" }
        if identity.contains("lulustream") { return "luluStream" }
        if identity.contains("vidara") { return "vidara" }
        if identity.contains("pornhub") { return "pornhub" }
        if resolution.mediaKind == .ytDlp { return "yt-dlp" }
        return "direct"
    }

    private func enqueueExisting(
        queueId: UUID,
        payload: DownloadRetryPayload,
        seedboxWebdavPassword: String,
        refreshSource: Bool = false
    ) {
        cancelScheduledRetry(queueId: queueId)
        pausedQueueIDs.remove(queueId)
        cancelledQueueIDs.remove(queueId)
        queuedRuns[queueId] = QueuedRun(
            payload: payload,
            seedboxWebdavPassword: seedboxWebdavPassword,
            refreshSource: refreshSource
        )
        processNextIfNeeded()
    }

    private func startQueued(queueId: UUID) {
        guard let queuedRun = queuedRuns.removeValue(forKey: queueId) else { return }
        startingQueueIDs.insert(queueId)
        Task { @MainActor in
            _ = await self.runRegistered(
                queueId: queueId,
                payload: queuedRun.payload,
                seedboxWebdavPassword: queuedRun.seedboxWebdavPassword,
                refreshSource: queuedRun.refreshSource
            )
        }
    }

    private func waitForResult(queueId: UUID) async -> Bool {
        if let result = completedResults.removeValue(forKey: queueId) {
            awaitedResultIDs.remove(queueId)
            return result
        }
        return await withCheckedContinuation { continuation in
            resultWaiters[queueId, default: []].append(continuation)
        }
    }

    private func cancelQueuedRun(queueId: UUID) {
        guard queuedRuns.removeValue(forKey: queueId) != nil else { return }
        startingQueueIDs.remove(queueId)
        pausedQueueIDs.remove(queueId)
        cancelledQueueIDs.remove(queueId)
        resolveWaiters(queueId: queueId, result: false)
        processNextIfNeeded()
    }

    private func cancelScheduledRetry(queueId: UUID) {
        retryWakeTasks.removeValue(forKey: queueId)?.cancel()
    }

    private func scheduleRetryWake(
        queueId: UUID,
        payload: DownloadRetryPayload,
        seedboxWebdavPassword: String,
        delay: TimeInterval
    ) {
        guard retryWakeTasks[queueId] == nil else { return }
        retryWakeTasks[queueId] = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.retryWakeTasks[queueId] = nil
            guard let item = DownloadQueue.shared.item(id: queueId),
                  item.status == .waiting,
                  !self.pausedQueueIDs.contains(queueId),
                  !self.cancelledQueueIDs.contains(queueId) else { return }
            self.enqueueExisting(
                queueId: queueId,
                payload: payload,
                seedboxWebdavPassword: seedboxWebdavPassword,
                refreshSource: true
            )
        }
    }

    private func runRegistered(
        queueId: UUID,
        payload: DownloadRetryPayload,
        seedboxWebdavPassword: String,
        refreshSource: Bool
    ) async -> Bool {
        startingQueueIDs.remove(queueId)

        let token = UUID()
        let task = Task { @MainActor in
            await self.runExisting(
                queueId: queueId,
                payload: payload,
                seedboxWebdavPassword: seedboxWebdavPassword,
                refreshSource: refreshSource
            )
        }
        runningTokens[queueId] = token
        runningTasks[queueId] = task

        let outcome = await task.value
        if runningTokens[queueId] == token {
            runningTokens[queueId] = nil
            runningTasks[queueId] = nil
            cancelledQueueIDs.remove(queueId)
        }
        let result: Bool
        switch outcome {
        case .finished(let didComplete):
            result = didComplete
            resolveWaiters(queueId: queueId, result: didComplete)
        case .retryScheduled:
            result = false
        }
        processNextIfNeeded()
        return result
    }

    private func resolveWaiters(queueId: UUID, result: Bool) {
        let waiters = resultWaiters.removeValue(forKey: queueId) ?? []
        if waiters.isEmpty {
            if awaitedResultIDs.contains(queueId) {
                completedResults[queueId] = result
            }
            return
        }
        awaitedResultIDs.remove(queueId)
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private var inFlightCount: Int {
        runningTasks.count + startingQueueIDs.count
    }

    private func runExisting(
        queueId: UUID,
        payload: DownloadRetryPayload,
        seedboxWebdavPassword: String,
        refreshSource: Bool
    ) async -> RunOutcome {
        guard !shouldStop(queueId: queueId) else { return .finished(false) }

        var resolution = payload.resolution
        let target = payload.target
        let context = payload.context.materialize(seedboxWebdavPassword: seedboxWebdavPassword)

        DownloadQueue.shared.update(
            id: queueId,
            status: .waiting,
            progress: 0,
            message: initialMessage(for: resolution, target: target)
        )
        ActiveWorkTracker.shared.project(queueId: queueId)

        guard !shouldStop(queueId: queueId) else { return .finished(false) }

        do {
            try validate(target: target, context: context)
            if refreshSource {
                DownloadQueue.shared.update(
                    id: queueId,
                    status: .waiting,
                    progress: 0,
                    message: "Resolving video source..."
                )
                resolution = try await DownloadResolver.resolve(
                    sourcePageURL: payload.sourcePageURL,
                    preferredQualityLabel: payload.preferredQualityLabel,
                    preferredQualityURL: nil
                )
            }
            try validateProFeatures(for: resolution)
        } catch {
            return handleFailure(
                queueId: queueId,
                title: resolution.title,
                error: error,
                stage: "source resolution",
                source: payload.sourcePageURL,
                payload: payload,
                seedboxWebdavPassword: seedboxWebdavPassword
            )
        }

        let runPayload = DownloadRetryPayload(
            resolution: resolution,
            target: payload.target,
            context: payload.context,
            gdriveMegaRemotePath: payload.gdriveMegaRemotePath
        )
        let job = makeJob(queueId: queueId, payload: runPayload, context: context)
        do {
            let completion = try await job.run { event in
                Task { @MainActor in
                    self.apply(event, queueId: queueId)
                }
            }
            guard !shouldStop(queueId: queueId) else { return .finished(false) }
            complete(queueId: queueId, resolution: resolution, completion: completion)
            return .finished(true)
        } catch {
            if isCancellation(error, queueId: queueId) {
                return .finished(false)
            }
            return handleFailure(
                queueId: queueId,
                title: resolution.title,
                error: error,
                stage: "media transfer",
                source: resolution.finalUrl,
                payload: payload,
                seedboxWebdavPassword: seedboxWebdavPassword
            )
        }
    }

    private func handleFailure(
        queueId: UUID,
        title: String,
        error: Error,
        stage: String,
        source: String,
        payload: DownloadRetryPayload,
        seedboxWebdavPassword: String
    ) -> RunOutcome {
        let attempts = DownloadQueue.shared.item(id: queueId)?.automaticRetryCount ?? 0
        guard DownloadAutomaticRetryPolicy.shouldRetry(error, after: attempts) else {
            fail(queueId: queueId, title: title, error: error, stage: stage, source: source)
            return .finished(false)
        }

        let nextAttempt = attempts + 1
        let delay = DownloadAutomaticRetryPolicy.delay(forAttempt: nextAttempt)
        guard DownloadQueue.shared.scheduleAutomaticRetry(id: queueId, attempt: nextAttempt, after: delay) else {
            fail(queueId: queueId, title: title, error: error, stage: stage, source: source)
            return .finished(false)
        }
        scheduleRetryWake(
            queueId: queueId,
            payload: payload,
            seedboxWebdavPassword: seedboxWebdavPassword,
            delay: delay
        )
        return .retryScheduled
    }

    private func validate(target: CloudTarget, context: DownloadJobContext) throws {
        switch target {
        case .local:
            return
        case .mega:
            guard MegaManager.isAvailable else { throw MegaUpError.notInstalled }
            guard MegaManager.isLoggedIn else { throw MegaUpError.notLoggedIn }
        case .gdrive:
            guard GDriveManager.isAvailable else { throw GDriveError.notInstalled }
        case .seedbox:
            if context.seedboxTransferMode == "webdav" {
                guard !context.seedboxWebdavURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SeedboxError.notConfigured }
            } else {
                guard SeedboxManager.isRcloneAvailable else { throw SeedboxError.notInstalled }
                guard !context.seedboxRemoteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SeedboxError.notConfigured }
            }
        }
    }

    private func validateProFeatures(for resolution: DownloadResolution) throws {
        if resolution.isAudio && !ProFeatureGate.canDownloadAudio {
            throw ProFeatureError.audioRequiresPro
        }
    }

    private func buildRetryPayload(
        for resolution: DownloadResolution,
        target: CloudTarget,
        context: DownloadJobContext
    ) -> DownloadRetryPayload {
        // Snapshot the GDrive Mega path at first-attempt time so retry doesn't accidentally
        // delete a different Mega file that was resolved after this job was queued.
        let gdriveMegaRemotePath: String?
        if target == .gdrive {
            gdriveMegaRemotePath = DownloadQueue.shared.latestFinalPath(for: resolution.requestedUrl, target: .mega)
                ?? ActiveWorkTracker.shared.megaFilenames[resolution.requestedUrl]
        } else {
            gdriveMegaRemotePath = nil
        }
        return DownloadRetryPayload(
            resolution: resolution,
            target: target,
            context: context.retryContext,
            gdriveMegaRemotePath: gdriveMegaRemotePath
        )
    }

    private func makeJob(queueId: UUID, payload: DownloadRetryPayload, context: DownloadJobContext) -> any DownloadJob {
        let resolution = payload.resolution
        switch payload.target {
        case .local:
            return LocalDownloadJob(queueId: queueId, resolution: resolution)
        case .mega:
            return MegaDownloadJob(queueId: queueId, resolution: resolution, remotePath: context.megaRemotePath)
        case .gdrive:
            return GDriveDownloadJob(
                queueId: queueId,
                resolution: resolution,
                remoteName: context.gdriveRemoteName,
                remotePath: context.gdriveRemotePath,
                megaRemotePath: payload.gdriveMegaRemotePath
            )
        case .seedbox:
            return SeedboxDownloadJob(queueId: queueId, resolution: resolution, context: context)
        }
    }

    private func apply(_ event: JobEvent, queueId: UUID) {
        guard !shouldStop(queueId: queueId),
              DownloadQueue.shared.item(id: queueId)?.status != .paused else { return }
        switch event {
        case .progress(let status, let progress, let message, let metrics):
            if DownloadQueue.shared.update(id: queueId, status: status, progress: progress, message: message, metrics: metrics) {
                ActiveWorkTracker.shared.project(queueId: queueId)
            }
        }
    }

    private func complete(queueId: UUID, resolution: DownloadResolution, completion: JobCompletion) {
        let message: String
        switch resolution.result.source {
        case .some:
            message = completion.finalPath.map { completion.notificationDestination == "Local" ? "Saved to \(URL(fileURLWithPath: $0).lastPathComponent)" : "Uploaded to \(completion.notificationDestination)" }
                ?? "Done"
        case .none:
            message = "Done"
        }

        DownloadQueue.shared.complete(id: queueId, finalPath: completion.finalPath, message: message)
        ActiveWorkTracker.shared.project(queueId: queueId)

        if let destination = completion.completedUploadDestination,
           let remotePath = completion.completedUploadRemotePath {
            HistoryManager.shared.recordCompletedUpload(
                url: resolution.requestedUrl,
                source: resolution.source,
                destination: destination,
                remotePath: remotePath
            )
        }

        let libraryItem = libraryItem(for: resolution.result)
        let cloud = DownloadQueue.shared.item(id: queueId)?.targetCloud ?? .local
        if let finalPath = completion.finalPath {
            VideoLibrary.shared.updateRemotePaths(for: libraryItem, cloud: cloud, path: finalPath)
        }

        Task {
            await LicenseManager.shared.recordSuccessfulDownload()
        }

        if let revealURL = completion.revealURL {
            NSWorkspace.shared.activateFileViewerSelecting([revealURL])
        }

        if completion.removeQueueItem {
            DownloadQueue.shared.remove(id: queueId)
        }

        if completion.notificationDestination != "Local",
           let item = DownloadQueue.shared.item(id: queueId),
           item.targetCloud == .gdrive {
            ActiveWorkTracker.shared.removeMegaFilename(for: resolution.requestedUrl)
        }

        NotificationManager.shared.notifyUploadComplete(
            filename: completion.notificationFilename,
            destination: completion.notificationDestination
        )
    }

    private func fail(queueId: UUID, title: String, error: Error, stage: String, source: String) {
        let message = "Source failed • stage: \(stage) • source: \(source) • reason: \(error.localizedDescription)"
        DownloadQueue.shared.fail(id: queueId, message: message)
        ActiveWorkTracker.shared.project(queueId: queueId)
        NotificationManager.shared.notifyUploadFailed(filename: title, reason: message)
    }

    private func shouldStop(queueId: UUID) -> Bool {
        Task.isCancelled || pausedQueueIDs.contains(queueId) || cancelledQueueIDs.contains(queueId)
    }

    private func isCancellation(_ error: Error, queueId: UUID) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if shouldStop(queueId: queueId) { return true }
        return DownloadQueue.shared.item(id: queueId)?.status == .paused
    }

    private func queueQuality(for resolution: DownloadResolution, target: CloudTarget) -> String {
        switch target {
        case .local:
            return resolution.queueQuality
        case .mega:
            return resolution.isHLS ? "HLS → Mega" : "Mega"
        case .gdrive:
            return resolution.isHLS ? "HLS → GDrive" : "GDrive"
        case .seedbox:
            return resolution.isHLS ? "HLS → Seedbox" : "Seedbox"
        }
    }

    private func initialMessage(for resolution: DownloadResolution, target: CloudTarget) -> String {
        switch target {
        case .local:
            switch resolution.mediaKind {
            case .direct: return "Downloading…"
            case .hls: return "Downloading HLS…"
            case .ytDlp: return "Downloading via yt-dlp…"
            case .audio: return "Downloading audio…"
            }
        case .mega:
            return resolution.isHLS ? "Materializing HLS…" : "Downloading… 0%"
        case .gdrive:
            if GDriveDownloadJob.shouldStream(
                mediaKind: resolution.mediaKind,
                siteName: resolution.source.siteName,
                sourcePageUrl: resolution.sourcePageUrl
            ) {
                return resolution.isHLS ? "Streaming HLS to Google Drive…" : "Transferring to Google Drive…"
            }
            return resolution.isHLS ? "Materializing HLS…" : "Preparing Google Drive upload…"
        case .seedbox:
            return resolution.isHLS ? "Streaming HLS to seedbox…" : "Transferring to seedbox…"
        }
    }

    private func libraryItem(for result: ExtractResult) -> LibraryItem {
        let title = result.source?.title ?? URL(string: result.url)?.pathComponents.last?.replacingOccurrences(of: "-", with: " ").capitalized ?? result.url
        let newItem = LibraryItem(
            url: result.url,
            title: title,
            mp4Url: result.source?.mp4,
            hlsUrls: result.source?.hls ?? [],
            thumbnailURL: result.source?.thumbnail,
            uploaderName: result.source?.uploader,
            uploaderURL: result.source?.uploaderURL,
            sourceSiteName: result.source?.siteName
        )
        VideoLibrary.shared.addIfNew(newItem)
        return VideoLibrary.shared.items.first(where: { $0.url == result.url }) ?? newItem
    }
}

struct DownloadQueueProgressProjection: Equatable {
    let status: QueueStatus
    let progress: Double
    let message: String
    let metrics: DownloadTransferMetrics?
}

extension ProgressEvent {
    var seedboxMaterializationProjection: DownloadQueueProgressProjection {
        switch phase {
        case .completing:
            return DownloadQueueProgressProjection(
                status: .verifying,
                progress: min(percent, 99),
                message: "Preparing seedbox upload…",
                metrics: nil
            )
        default:
            return DownloadQueueProgressProjection(
                status: phase.queueStatus,
                progress: percent,
                message: message,
                metrics: metrics
            )
        }
    }
}

extension ProgressEvent.Phase {
    var queueStatus: QueueStatus {
        switch self {
        case .downloading:
            return .downloading
        case .verifying:
            return .verifying
        case .uploading:
            return .uploading
        case .completing:
            return .verifying
        }
    }
}
