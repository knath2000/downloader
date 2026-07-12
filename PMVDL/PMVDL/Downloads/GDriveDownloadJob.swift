import Foundation

struct GDriveDownloadJob: DownloadJob {
    let queueId: UUID
    let resolution: DownloadResolution
    let remoteName: String
    let remotePath: String
    let megaRemotePath: String?

    enum HLSUploadStrategy: Equatable {
        case materializeLocally
        case streamToRclone
    }

    func run(onEvent: @escaping (JobEvent) -> Void) async throws -> JobCompletion {
        var filename = VideoFileNaming.mp4FileName(title: resolution.title, fallback: fileName(of: resolution.requestedUrl))
        let finalPath: String

        if resolution.mediaKind == .direct {
            guard let sourceURL = URL(string: resolution.finalUrl) else { throw GDriveError.invalidSourceURL }
            onEvent(.progress(.uploading, 0, "Transferring to Google Drive… 0%"))
            finalPath = try await GDriveManager.uploadStream(
                sourceURL: sourceURL,
                remoteName: remoteName,
                remotePath: remotePath,
                filename: filename,
                headers: resolution.headers,
                onRetry: { attempt, delay in
                    onEvent(.progress(.uploading, 99, "Google Drive rate limit hit; retry \(attempt) in \(Int(delay))s…"))
                },
                onVerifying: {
                    onEvent(.progress(.verifying, 99, "Checking Google Drive…"))
                },
                onProgress: { progress in
                    let pct = min(99, max(0, progress * 100))
                    onEvent(.progress(.uploading, pct, String(format: "Transferring to Google Drive… %.0f%%", pct)))
                }
            )
        } else if resolution.mediaKind == .hls,
                  hlsUploadStrategy == .streamToRclone,
                  let m3u8URL = URL(string: resolution.finalUrl) {
            onEvent(.progress(.downloading, 0, "Streaming HLS to Google Drive…"))
            finalPath = try await GDriveManager.uploadHLSStream(
                m3u8URL: m3u8URL,
                remoteName: remoteName,
                remotePath: remotePath,
                filename: filename,
                headers: resolution.headers,
                onRetry: { attempt, delay in
                    onEvent(.progress(.uploading, 99, "Google Drive rate limit hit; retry \(attempt) in \(Int(delay))s…"))
                },
                onVerifying: {
                    onEvent(.progress(.verifying, 99, "Checking Google Drive…"))
                },
                onProgress: { progress in
                    let pct = min(99, max(0, progress * 100))
                    onEvent(.progress(.downloading, pct, String(format: "Streaming HLS to Google Drive… %.1f%%", pct)))
                }
            )
        } else if resolution.isHLS {
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
            finalPath = try await GDriveManager.uploadLocalFile(
                mp4File,
                remoteName: remoteName,
                remotePath: remotePath,
                onProgress: { event in
                    onEvent(.progress(event.phase.queueStatus, event.percent, event.message, event.metrics))
                }
            )
            filename = mp4File.lastPathComponent
            try? FileManager.default.removeItem(at: mp4File)
        } else {
            finalPath = try await runLocalFallback(
                filename: filename,
                remoteName: remoteName,
                remotePath: remotePath,
                onEvent: onEvent
            )
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

    var hlsUploadStrategy: HLSUploadStrategy {
        Self.hlsUploadStrategy(forSiteName: resolution.source.siteName, sourcePageUrl: resolution.sourcePageUrl)
    }

    static func hlsUploadStrategy(forSiteName siteName: String?, sourcePageUrl: String?) -> HLSUploadStrategy {
        let values = [siteName, sourcePageUrl].compactMap { $0?.lowercased() }
        if values.contains(where: { value in
            value.contains("lulu")
                || value.contains("vidara")
                || value.contains("providerlink")
                || value.contains("allpornstream.com")
        }) {
            return .materializeLocally
        }
        return .streamToRclone
    }

    static func shouldStream(mediaKind: DownloadMediaKind, siteName: String?, sourcePageUrl: String?) -> Bool {
        switch mediaKind {
        case .direct:
            return true
        case .hls:
            return hlsUploadStrategy(forSiteName: siteName, sourcePageUrl: sourcePageUrl) == .streamToRclone
        case .ytDlp, .audio:
            return false
        }
    }

    private func runLocalFallback(
        filename: String,
        remoteName: String,
        remotePath: String,
        onEvent: @escaping (JobEvent) -> Void
    ) async throws -> String {
        let localFile: URL
        switch resolution.mediaKind {
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
            guard let sourceURL = URL(string: resolution.finalUrl) else { throw GDriveError.invalidSourceURL }
            return try await GDriveManager.uploadStream(
                sourceURL: sourceURL,
                remoteName: remoteName,
                remotePath: remotePath,
                filename: filename,
                headers: resolution.headers,
                onRetry: { attempt, delay in
                    onEvent(.progress(.uploading, 99, "Google Drive rate limit hit; retry \(attempt) in \(Int(delay))s…"))
                },
                onVerifying: {
                    onEvent(.progress(.verifying, 99, "Checking Google Drive…"))
                },
                onProgress: { progress in
                    let pct = min(99, max(0, progress * 100))
                    onEvent(.progress(.uploading, pct, String(format: "Transferring to Google Drive… %.0f%%", pct)))
                }
            )
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
        }

        defer { try? FileManager.default.removeItem(at: localFile) }
        onEvent(.progress(.uploading, 0, "Uploading to Google Drive… 0%"))
        return try await GDriveManager.uploadLocalFile(
            localFile,
            remoteName: remoteName,
            remotePath: remotePath,
            onProgress: { event in
                onEvent(.progress(event.phase.queueStatus, event.percent, event.message, event.metrics))
            }
        )
    }

    private var normalizedRemotePath: String {
        GDriveManager.normalizedRclonePath(remotePath)
    }

    private func fileName(of url: String) -> String {
        url.split(separator: "/").last.map(String.init) ?? url
    }
}

