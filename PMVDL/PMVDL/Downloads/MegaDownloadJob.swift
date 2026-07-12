import Foundation

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

