import Foundation

struct SeedboxDownloadJob: DownloadJob {
    let queueId: UUID
    let resolution: DownloadResolution
    let context: DownloadJobContext

    enum HLSUploadStrategy: Equatable {
        case materializeLocally
        case streamToRclone
    }

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
                  hlsUploadStrategy == .streamToRclone,
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
                    let projection = event.seedboxMaterializationProjection
                    onEvent(.progress(projection.status, projection.progress, projection.message, projection.metrics))
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
        if resolution.mediaKind == .hls {
            onEvent(.progress(.uploading, 0, "Uploading to seedbox… 0%"))
        }
        return try await manager.uploadFile(
            at: localFile,
            filename: filename,
            progressHandler: { progress in
                let pct = min(99, max(0, progress * 100))
                onEvent(.progress(.uploading, pct, String(format: "Uploading to seedbox… %.0f%%", pct)))
            }
        )
    }

    var hlsUploadStrategy: HLSUploadStrategy {
        Self.hlsUploadStrategy(forSiteName: resolution.source.siteName, sourcePageUrl: resolution.sourcePageUrl)
    }

    static func hlsUploadStrategy(forSiteName siteName: String?, sourcePageUrl: String?) -> HLSUploadStrategy {
        let values = [siteName, sourcePageUrl].compactMap { $0?.lowercased() }
        if values.contains(where: { $0.contains("lulu") || $0.contains("vidara") }) {
            return .materializeLocally
        }
        return .streamToRclone
    }

    private func transferMode() throws -> SeedboxTransferMode {
        if context.seedboxTransferMode == "webdav" {
            let trimmed = context.seedboxWebdavURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let base = URLTrustPolicy.validated(trimmed), base.scheme?.lowercased() == "https" else { throw SeedboxError.notConfigured }
            return .webdav(
                baseURL: base,
                user: context.seedboxWebdavUser,
                password: context.seedboxWebdavPassword,
                remotePath: context.seedboxRemotePath,
                allowSelfSigned: UserDefaults.standard.bool(forKey: "seedboxWebdavAllowSelfSigned")
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
