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

struct LocalDownloadJob: DownloadJob {
    let queueId: UUID
    let resolution: DownloadResolution

    func run(onEvent: @escaping (JobEvent) -> Void) async throws -> JobCompletion {
        let destFile: URL
        switch resolution.mediaKind {
        case .ytDlp:
            onEvent(.progress(.downloading, 0, "Downloading via yt-dlp…"))
            destFile = try await DownloadManager.shared.downloadViaYTDLPSite(
                pageUrl: resolution.finalUrl,
                title: resolution.title,
                onProgress: { msg in onEvent(.progress(.downloading, 0, msg)) }
            )
        case .hls:
            onEvent(.progress(.downloading, 0, "Downloading HLS…"))
            destFile = try await DownloadManager.shared.downloadHLS(
                m3u8Url: resolution.finalUrl,
                title: resolution.title,
                headers: resolution.headers,
                sourcePageUrl: resolution.sourcePageUrl,
                onProgress: { event in
                    onEvent(.progress(event.phase.queueStatus, event.percent, event.message, event.metrics))
                }
            )
        case .audio:
            onEvent(.progress(.downloading, 0, "Downloading audio…"))
            destFile = try await DownloadManager.shared.downloadAudio(
                pageUrl: resolution.finalUrl,
                title: resolution.title,
                onProgress: { msg in onEvent(.progress(.downloading, 0, msg)) }
            )
        case .direct:
            onEvent(.progress(.downloading, 0, "Downloading…"))
            let delegate = QueueDownloadProgressDelegate(queueId: queueId) { pct, bytesDownloaded, totalBytes, bytesPerSecond in
                onEvent(.progress(
                    .downloading,
                    pct,
                    String(format: "Downloading… %d%%", Int(pct)),
                    DownloadTransferMetrics(
                        bytesDownloaded: bytesDownloaded,
                        totalBytes: totalBytes,
                        bytesPerSecond: bytesPerSecond
                    )
                ))
            }
            destFile = try await DownloadManager.shared.downloadDirectWithDelegate(
                url: resolution.finalUrl,
                title: resolution.title,
                headers: resolution.headers,
                delegate: delegate
            )
        }

        if !resolution.isAudio {
            onEvent(.progress(.verifying, 99, "Verifying video…"))
            try await VideoProcessor.verifyForUpload(destFile)
        }

        return JobCompletion(
            finalPath: destFile.path,
            notificationFilename: destFile.lastPathComponent,
            notificationDestination: "Local",
            completedUploadDestination: nil,
            completedUploadRemotePath: nil,
            revealURL: destFile,
            removeQueueItem: false
        )
    }
}

struct MegaDownloadJob: DownloadJob {
    let queueId: UUID
    let resolution: DownloadResolution
    let remotePath: String

    func run(onEvent: @escaping (JobEvent) -> Void) async throws -> JobCompletion {
        let uploadResult: MegaManager.UploadResult
        let uploadedName: String

        if resolution.isHLS {
            onEvent(.progress(.downloading, 0, "Materializing HLS…"))
            let mp4File = try await DownloadManager.shared.downloadHLS(
                m3u8Url: resolution.finalUrl,
                title: resolution.title,
                headers: resolution.headers,
                sourcePageUrl: resolution.sourcePageUrl,
                onProgress: { event in
                    onEvent(.progress(event.phase.queueStatus, event.percent, event.message, event.metrics))
                }
            )
            uploadResult = try await MegaManager.uploadLocalFile(
                mp4File,
                remotePath: remotePath,
                uploadID: queueId,
                onProgress: { event in
                    onEvent(.progress(event.phase.queueStatus, event.percent, event.message, event.metrics))
                }
            )
            uploadedName = uploadResult.remotePath.split(separator: "/").last.map(String.init) ?? mp4File.lastPathComponent
            try? FileManager.default.removeItem(at: mp4File)
        } else {
            onEvent(.progress(.downloading, 0, "Downloading… 0%"))
            uploadResult = try await MegaManager.upload(
                url: resolution.finalUrl,
                remotePath: remotePath,
                title: resolution.title,
                headers: resolution.headers,
                uploadID: queueId,
                onProgress: { event in
                    onEvent(.progress(event.phase.queueStatus, event.percent, event.message, event.metrics))
                }
            )
            uploadedName = VideoFileNaming.mp4FileName(title: resolution.title, fallback: fileName(of: resolution.requestedUrl))
        }

        return JobCompletion(
            finalPath: uploadResult.remotePath,
            notificationFilename: uploadedName,
            notificationDestination: remotePath,
            completedUploadDestination: "Mega",
            completedUploadRemotePath: uploadResult.remotePath,
            revealURL: nil,
            removeQueueItem: true
        )
    }

    private func fileName(of url: String) -> String {
        url.split(separator: "/").last.map(String.init) ?? url
    }
}

struct GDriveDownloadJob: DownloadJob {
    let queueId: UUID
    let resolution: DownloadResolution
    let remoteName: String
    let remotePath: String
    let megaRemotePath: String?

    func run(onEvent: @escaping (JobEvent) -> Void) async throws -> JobCompletion {
        let finalPath: String
        let filename: String

        if resolution.isHLS {
            onEvent(.progress(.downloading, 0, "Materializing HLS…"))
            let mp4File = try await DownloadManager.shared.downloadHLS(
                m3u8Url: resolution.finalUrl,
                title: resolution.title,
                headers: resolution.headers,
                sourcePageUrl: resolution.sourcePageUrl,
                onProgress: { event in
                    onEvent(.progress(event.phase.queueStatus, event.percent, event.message, event.metrics))
                }
            )
            try await GDriveManager.uploadLocalFile(
                mp4File,
                remoteName: remoteName,
                remotePath: remotePath,
                onProgress: { event in
                    onEvent(.progress(event.phase.queueStatus, event.percent, event.message, event.metrics))
                }
            )
            filename = mp4File.lastPathComponent
            finalPath = "\(remoteName):\(normalizedRemotePath)\(filename)"
            try? FileManager.default.removeItem(at: mp4File)
        } else {
            onEvent(.progress(.downloading, 0, "Downloading… 0%"))
            finalPath = try await GDriveManager.upload(
                url: resolution.finalUrl,
                remoteName: remoteName,
                remotePath: remotePath,
                title: resolution.title,
                headers: resolution.headers,
                onProgress: { msg in
                    let pct = msg.parsePercent() ?? 0
                    onEvent(.progress(msg.localizedCaseInsensitiveContains("uploading") ? .uploading : .downloading, pct, msg))
                }
            )
            filename = VideoFileNaming.mp4FileName(title: resolution.title, fallback: fileName(of: resolution.requestedUrl))
        }

        if let megaRemotePath {
            try? await MegaManager.delete(remotePath: megaRemotePath)
        }

        return JobCompletion(
            finalPath: finalPath,
            notificationFilename: filename,
            notificationDestination: remotePath,
            completedUploadDestination: nil,
            completedUploadRemotePath: nil,
            revealURL: nil,
            removeQueueItem: false
        )
    }

    private var normalizedRemotePath: String {
        remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
    }

    private func fileName(of url: String) -> String {
        url.split(separator: "/").last.map(String.init) ?? url
    }
}

struct SeedboxDownloadJob: DownloadJob {
    let queueId: UUID
    let resolution: DownloadResolution
    let context: DownloadJobContext

    func run(onEvent: @escaping (JobEvent) -> Void) async throws -> JobCompletion {
        var filename = VideoFileNaming.mp4FileName(title: resolution.title, fallback: fileName(of: resolution.requestedUrl))
        let manager = SeedboxManager(mode: try transferMode())
        onEvent(.progress(.downloading, 0, "Connecting to seedbox…"))
        try await manager.preflight(filename: filename)

        let finalPath: String

        if resolution.mediaKind == .direct {
            let isRestartResume = await MainActor.run {
                DownloadQueue.shared.item(id: queueId)?.resumeStrategy == .remoteSafeNewFile
            }
            let existingSize = try? await manager.remoteSize(filename: filename)
            if let existingSize, existingSize > 0 {
                filename = SeedboxManager.safeResumedFilename(filename: filename, queueId: queueId)
                onEvent(.progress(.uploading, 0, "Existing seedbox partial found; continuing to a safe new file…"))
            } else if isRestartResume && existingSize == nil {
                filename = SeedboxManager.safeResumedFilename(filename: filename, queueId: queueId)
                onEvent(.progress(.uploading, 0, "Cannot safely append; restarting without overwriting existing partial."))
            }
            guard let sourceURL = URL(string: resolution.finalUrl) else { throw SeedboxError.invalidSourceURL }
            onEvent(.progress(.uploading, 0, "Transferring to seedbox… 0%"))
            finalPath = try await manager.upload(
                sourceURL: sourceURL,
                filename: filename,
                headers: resolution.headers,
                progressHandler: { progress in
                    let pct = min(99, max(0, progress * 100))
                    onEvent(.progress(.uploading, pct, String(format: "Transferring to seedbox… %.0f%%", pct)))
                }
            )
        } else if resolution.mediaKind == .hls,
                  !shouldMaterializeHLSLocally,
                  let m3u8URL = URL(string: resolution.finalUrl) {
            onEvent(.progress(.downloading, 0, "Streaming HLS to seedbox…"))
            finalPath = try await manager.uploadHLS(
                m3u8URL: m3u8URL,
                filename: filename,
                headers: resolution.headers,
                progressHandler: { progress in
                    let pct = min(99, max(0, progress * 100))
                    onEvent(.progress(.downloading, pct, String(format: "Streaming HLS… %.1f%%", pct)))
                }
            )
        } else {
            finalPath = try await runLocalFallback(filename: filename, manager: manager, onEvent: onEvent)
        }

        return JobCompletion(
            finalPath: finalPath,
            notificationFilename: filename,
            notificationDestination: "Seedbox",
            completedUploadDestination: nil,
            completedUploadRemotePath: nil,
            revealURL: nil,
            removeQueueItem: false
        )
    }

    private func runLocalFallback(
        filename: String,
        manager: SeedboxManager,
        onEvent: @escaping (JobEvent) -> Void
    ) async throws -> String {
        let localFile: URL
        switch resolution.mediaKind {
        case .hls:
            onEvent(.progress(.downloading, 0, "Materializing HLS…"))
            localFile = try await DownloadManager.shared.downloadHLS(
                m3u8Url: resolution.finalUrl,
                title: resolution.title,
                headers: resolution.headers,
                sourcePageUrl: resolution.sourcePageUrl,
                onProgress: { event in
                    onEvent(.progress(event.phase.queueStatus, event.percent, event.message, event.metrics))
                }
            )
        case .ytDlp:
            onEvent(.progress(.downloading, 0, "Downloading via yt-dlp…"))
            localFile = try await DownloadManager.shared.downloadViaYTDLPSite(
                pageUrl: resolution.finalUrl,
                title: resolution.title,
                onProgress: { msg in onEvent(.progress(.downloading, 0, msg)) }
            )
        case .audio:
            onEvent(.progress(.downloading, 0, "Downloading audio…"))
            localFile = try await DownloadManager.shared.downloadAudio(
                pageUrl: resolution.finalUrl,
                title: resolution.title,
                onProgress: { msg in onEvent(.progress(.downloading, 0, msg)) }
            )
        case .direct:
            throw SeedboxError.hlsUnsupported
        }

        defer { try? FileManager.default.removeItem(at: localFile) }
        return try await manager.uploadFile(
            at: localFile,
            filename: filename,
            progressHandler: { progress in
                let pct = min(99, max(0, progress * 100))
                onEvent(.progress(.uploading, pct, String(format: "Uploading to seedbox… %.0f%%", pct)))
            }
        )
    }

    private var shouldMaterializeHLSLocally: Bool {
        guard resolution.mediaKind == .hls else { return false }
        if resolution.source.siteName?.localizedCaseInsensitiveContains("Lulu") == true {
            return true
        }
        return resolution.sourcePageUrl?.localizedCaseInsensitiveContains("lulu") == true
    }

    private func transferMode() throws -> SeedboxTransferMode {
        if context.seedboxTransferMode == "webdav" {
            let trimmed = context.seedboxWebdavURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let base = URL(string: trimmed) else { throw SeedboxError.notConfigured }
            return .webdav(
                baseURL: base,
                user: context.seedboxWebdavUser,
                password: context.seedboxWebdavPassword,
                remotePath: context.seedboxRemotePath
            )
        }

        return .rclone(
            remoteName: context.seedboxRemoteName,
            remotePath: context.seedboxRemotePath
        )
    }

    private func fileName(of url: String) -> String {
        url.split(separator: "/").last.map(String.init) ?? url
    }
}

@MainActor
final class DownloadJobRunner {
    static let shared = DownloadJobRunner()

    private var runningTasks: [UUID: Task<Bool, Never>] = [:]
    private var runningTokens: [UUID: UUID] = [:]
    private var pausedQueueIDs: Set<UUID> = []
    private var cancelledQueueIDs: Set<UUID> = []

    private init() {}

    // MARK: - Public entry points

    func start(resolution: DownloadResolution, target: CloudTarget, context: DownloadJobContext) {
        Task {
            _ = await run(resolution: resolution, target: target, context: context)
        }
    }

    func run(resolution: DownloadResolution, target: CloudTarget, context: DownloadJobContext) async -> Bool {
        let payload = buildRetryPayload(for: resolution, target: target, context: context)
        let queueId = DownloadQueue.shared.add(
            url: resolution.requestedUrl,
            quality: queueQuality(for: resolution, target: target),
            targetCloud: target,
            displayTitle: resolution.title,
            retryPayload: payload
        )
        return await runRegistered(
            queueId: queueId,
            payload: payload,
            seedboxWebdavPassword: context.seedboxWebdavPassword
        )
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
        Task {
            _ = await runRegistered(queueId: queueId, payload: payload, seedboxWebdavPassword: seedboxWebdavPassword)
        }
    }

    func pause(queueId: UUID) {
        pausedQueueIDs.insert(queueId)
        cancelledQueueIDs.remove(queueId)
        runningTasks[queueId]?.cancel()
    }

    func cancel(queueId: UUID) {
        cancelledQueueIDs.insert(queueId)
        pausedQueueIDs.remove(queueId)
        runningTasks[queueId]?.cancel()
    }

    /// Resets the existing queue row and reruns the job with the original payload.
    @discardableResult
    func retry(queueId: UUID, payload: DownloadRetryPayload, seedboxWebdavPassword: String) async -> Bool {
        guard DownloadQueue.shared.resetForRetry(id: queueId) else { return false }
        return await runRegistered(queueId: queueId, payload: payload, seedboxWebdavPassword: seedboxWebdavPassword)
    }

    @discardableResult
    func resume(queueId: UUID, payload: DownloadRetryPayload, seedboxWebdavPassword: String) async -> Bool {
        guard DownloadQueue.shared.resetForResume(id: queueId) else { return false }
        return await runRegistered(queueId: queueId, payload: payload, seedboxWebdavPassword: seedboxWebdavPassword)
    }

    // MARK: - Shared execution core

    private func runRegistered(
        queueId: UUID,
        payload: DownloadRetryPayload,
        seedboxWebdavPassword: String
    ) async -> Bool {
        pausedQueueIDs.remove(queueId)
        cancelledQueueIDs.remove(queueId)

        let token = UUID()
        let task = Task { @MainActor in
            await self.runExisting(
                queueId: queueId,
                payload: payload,
                seedboxWebdavPassword: seedboxWebdavPassword
            )
        }
        runningTokens[queueId] = token
        runningTasks[queueId] = task

        let result = await task.value
        if runningTokens[queueId] == token {
            runningTokens[queueId] = nil
            runningTasks[queueId] = nil
            cancelledQueueIDs.remove(queueId)
        }
        return result
    }

    private func runExisting(
        queueId: UUID,
        payload: DownloadRetryPayload,
        seedboxWebdavPassword: String
    ) async -> Bool {
        guard !shouldStop(queueId: queueId) else { return false }

        let resolution = payload.resolution
        let target = payload.target
        let context = payload.context.materialize(seedboxWebdavPassword: seedboxWebdavPassword)

        DownloadQueue.shared.update(
            id: queueId,
            status: .pending,
            progress: 0,
            message: initialMessage(for: resolution, target: target)
        )
        ActiveWorkTracker.shared.project(queueId: queueId)

        guard !shouldStop(queueId: queueId) else { return false }

        do {
            try validate(target: target, context: context)
            try validateProFeatures(for: resolution)
        } catch {
            fail(queueId: queueId, title: resolution.title, error: error)
            return false
        }

        let job = makeJob(queueId: queueId, payload: payload, context: context)
        do {
            let completion = try await job.run { event in
                Task { @MainActor in
                    self.apply(event, queueId: queueId)
                }
            }
            guard !shouldStop(queueId: queueId) else { return false }
            complete(queueId: queueId, resolution: resolution, completion: completion)
            return true
        } catch {
            if isCancellation(error, queueId: queueId) {
                return false
            }
            fail(queueId: queueId, title: resolution.title, error: error)
            return false
        }
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
            DownloadQueue.shared.update(id: queueId, status: status, progress: progress, message: message, metrics: metrics)
            ActiveWorkTracker.shared.project(queueId: queueId)
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

    private func fail(queueId: UUID, title: String, error: Error) {
        DownloadQueue.shared.fail(id: queueId, error: error)
        ActiveWorkTracker.shared.project(queueId: queueId)
        NotificationManager.shared.notifyUploadFailed(filename: title, reason: error.localizedDescription)
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
            return resolution.isHLS ? "Materializing HLS…" : "Downloading… 0%"
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
            thumbnailURL: result.source?.thumbnail
        )
        VideoLibrary.shared.addIfNew(newItem)
        return VideoLibrary.shared.items.first(where: { $0.url == result.url }) ?? newItem
    }
}

private extension ProgressEvent.Phase {
    var queueStatus: QueueStatus {
        switch self {
        case .downloading:
            return .downloading
        case .verifying:
            return .verifying
        case .uploading:
            return .uploading
        case .completing:
            return .completed
        }
    }
}
