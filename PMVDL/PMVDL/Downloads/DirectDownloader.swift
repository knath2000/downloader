import Foundation

struct DirectDownloader {
    // MARK: - URL Encoding Helper

    /// Properly encodes a URL string to handle special characters like ~ in paths
    private func sanitizeURLString(_ urlString: String) -> URL? {
        // Try direct URL creation first (for already-encoded URLs)
        if let url = URL(string: urlString) {
            return url
        }

        // If that fails, try to use URLComponents to parse and rebuild
        if let components = URLComponents(string: urlString) {
            return components.url
        }

        // Last resort: manually encode the string
        let allowedCharacters = CharacterSet(charactersIn: "!*'();:@&=+$,/?#[]~")
        if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: allowedCharacters) {
            return URL(string: encoded)
        }

        return nil
    }

    // MARK: - Direct download (URLSession)

    /// Download a direct video URL to the local Downloads/VidDL folder.
    func downloadDirect(url: String, title: String? = nil,
                        headers: [String: String]? = nil,
                        onProgress: @escaping (String) -> Void) async throws -> URL {
        guard let validUrl = sanitizeURLString(url) else {
            throw DownloadError.invalidURL(url)
        }

        let filename = VideoFileNaming.mp4FileName(title: title, fallback: validUrl.pathComponents.last ?? "video")
        let destFile = DownloadPaths.downloadDir.appendingPathComponent(filename)

        let delegate = DownloadProgressDelegate(onProgress: onProgress, destURL: destFile)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: validUrl)
        request.timeoutInterval = 120
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        try await delegate.performDownload(session: session, request: request)

        return destFile
    }

    /// Download a direct video URL with a progress delegate that reports numeric percent.
    func downloadDirectWithDelegate(url: String, title: String? = nil,
                                     headers: [String: String]? = nil,
                                     delegate: QueueDownloadProgressDelegate) async throws -> URL {
        guard let validUrl = sanitizeURLString(url) else {
            throw DownloadError.invalidURL(url)
        }

        let filename = VideoFileNaming.mp4FileName(title: title, fallback: validUrl.pathComponents.last ?? "video")
        let destFile = DownloadPaths.downloadDir.appendingPathComponent(filename)
        delegate.destURL = destFile
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: validUrl)
        request.timeoutInterval = 120
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        try await delegate.performDownload(session: session, request: request)

        return destFile
    }
}

final class QueueDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    let queueId: UUID
    let onProgress: (Double) -> Void
    var destURL: URL
    private var lastReportedPct = -1

    init(queueId: UUID, onProgress: @escaping (Double) -> Void) {
        self.queueId = queueId; self.onProgress = onProgress
        self.destURL = URL(fileURLWithPath: "/tmp/viddldummy")
    }

    func performDownload(session: URLSession, request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let task = session.downloadTask(with: request); task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let pct = min(Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100.0), 99)
        guard pct != lastReportedPct else { return }
        lastReportedPct = pct
        onProgress(Double(pct))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: location, to: destURL)
            DispatchQueue.main.async { [self] in self.onProgress(100.0) }
            continuation?.resume()
        }
        catch { continuation?.resume(throwing: error) }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let err = error { continuation?.resume(throwing: err); continuation = nil }
    }
}
