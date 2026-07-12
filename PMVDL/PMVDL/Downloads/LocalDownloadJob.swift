import Foundation

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

