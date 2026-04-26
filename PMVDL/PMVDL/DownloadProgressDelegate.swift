import Foundation

/// URLSession download delegate for direct downloads.
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let progressHandler: (String) -> Void
    private let destURL: URL
    private var lastReportedPct: Int = -1

    init(onProgress: @escaping (String) -> Void, destURL: URL) {
        self.progressHandler = onProgress
        self.destURL = destURL
    }

    func performDownload(session: URLSession, request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let task = session.downloadTask(with: request)
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let pct = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100.0)
        if pct != lastReportedPct {
            lastReportedPct = pct
            let dl = fmt(totalBytesWritten)
            let total = fmt(totalBytesExpectedToWrite)
            progressHandler("Downloading… \(dl)/\(total) \(pct)%")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: location, to: destURL)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private func fmt(_ bytes: Int64) -> String {
        let u = ["B","KB","MB","GB","TB"]; var s = Double(bytes); var i = 0
        while s >= 1024 && i < u.count-1 { s/=1024; i+=1 }
        return String(format:"%.1f %@",s,u[i])
    }
}
