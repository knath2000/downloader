import Foundation

struct DirectDownloader {
    // MARK: - URL Encoding Helper

    /// Properly encodes a URL string to handle special characters like ~ in paths
    private func sanitizeURLString(_ urlString: String) -> URL? {
        // Try direct URL creation first (for already-encoded URLs)
        if let url = URLTrustPolicy.validated(urlString) {
            return url
        }

        // If that fails, try to use URLComponents to parse and rebuild
        if let components = URLComponents(string: urlString),
           let url = components.url,
           URLTrustPolicy.isAllowed(url) {
            return url
        }

        // Last resort: manually encode the string
        let allowedCharacters = CharacterSet(charactersIn: "!*'();:@&=+$,/?#[]~")
        if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: allowedCharacters) {
            return URLTrustPolicy.validated(encoded)
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
        MediaRequestHeaders.sanitized(headers).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
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
        return try await downloadAppendable(
            url: validUrl,
            destFile: destFile,
            headers: headers,
            delegate: delegate
        )
    }

    private func downloadAppendable(
        url: URL,
        destFile: URL,
        headers: [String: String]?,
        delegate: QueueDownloadProgressDelegate
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: destFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        var outputURL = destFile
        var existingSize = fileSize(at: outputURL)
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        MediaRequestHeaders.sanitized(headers).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if existingSize > 0 {
            request.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
        }

        let initialPartialPath = outputURL.path
        let initialResumeStrategy: DownloadResumeStrategy = existingSize > 0 ? .appendLocalRange : .restartSafeNewFile
        await MainActor.run {
            DownloadQueue.shared.updateResumeState(
                id: delegate.queueId,
                partialLocalPath: initialPartialPath,
                resumeStrategy: initialResumeStrategy
            )
        }

        let session = URLSession(configuration: .default)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.downloadFailed("No HTTP response.")
        }

        let isAppending = existingSize > 0 && http.statusCode == 206
        if existingSize > 0 && http.statusCode == 200 {
            outputURL = safeResumedFileURL(for: destFile)
            existingSize = 0
            let safePartialPath = outputURL.path
            await MainActor.run {
                DownloadQueue.shared.updateResumeState(
                    id: delegate.queueId,
                    partialLocalPath: safePartialPath,
                    supportsByteRange: false,
                    resumeStrategy: .restartSafeNewFile
                )
            }
        } else if !(200...299).contains(http.statusCode) {
            throw DownloadError.downloadFailed("CDN returned HTTP \(http.statusCode).")
        } else {
            let partialPath = outputURL.path
            let strategy: DownloadResumeStrategy = isAppending ? .appendLocalRange : .restartSafeNewFile
            await MainActor.run {
                DownloadQueue.shared.updateResumeState(
                    id: delegate.queueId,
                    partialLocalPath: partialPath,
                    supportsByteRange: isAppending,
                    resumeStrategy: strategy
                )
            }
        }

        let expectedTotal = expectedTotalBytes(response: http, existingSize: existingSize)
        if let expectedTotal {
            await MainActor.run {
                DownloadQueue.shared.updateResumeState(id: delegate.queueId, expectedTotalBytes: expectedTotal)
            }
        }

        if !FileManager.default.fileExists(atPath: outputURL.path) {
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var totalWritten = existingSize
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        var lastReportedPct = -1
        var lastSampleBytes = totalWritten
        var lastSampleDate = Date()

        func flush() throws {
            guard !buffer.isEmpty else { return }
            try handle.write(contentsOf: buffer)
            totalWritten += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)

            let now = Date()
            let elapsed = now.timeIntervalSince(lastSampleDate)
            let rate = elapsed > 0 ? Double(totalWritten - lastSampleBytes) / elapsed : nil
            lastSampleBytes = totalWritten
            lastSampleDate = now

            if let expectedTotal, expectedTotal > 0 {
                let pct = min(Int(Double(totalWritten) / Double(expectedTotal) * 100.0), 99)
                if pct != lastReportedPct {
                    lastReportedPct = pct
                    delegate.onProgress(Double(pct), totalWritten, expectedTotal, rate)
                }
            } else {
                delegate.onProgress(0, totalWritten, nil, rate)
            }
        }

        for try await byte in bytes {
            if Task.isCancelled { throw CancellationError() }
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try flush()
            }
        }
        try flush()
        delegate.onProgress(100.0, totalWritten, expectedTotal, nil)
        return outputURL
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private func expectedTotalBytes(response: HTTPURLResponse, existingSize: Int64) -> Int64? {
        if let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last,
           let value = Int64(total) {
            return value
        }
        if let length = response.value(forHTTPHeaderField: "Content-Length"),
           let value = Int64(length) {
            return existingSize + value
        }
        return response.expectedContentLength > 0 ? existingSize + response.expectedContentLength : nil
    }

    private func safeResumedFileURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = directory.appendingPathComponent("\(base) (resumed)").appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (resumed \(index))").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    private func legacyDownloadWithDelegate(
        url validUrl: URL,
        destFile: URL,
        headers: [String: String]?,
        delegate: QueueDownloadProgressDelegate
    ) async throws -> URL {
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
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var downloadTask: URLSessionDownloadTask?
    let queueId: UUID
    let onProgress: (Double, Int64?, Int64?, Double?) -> Void
    var destURL: URL
    private var lastReportedPct = -1
    private var lastSampleBytes: Int64 = 0
    private var lastSampleDate = Date()

    init(queueId: UUID, onProgress: @escaping (Double, Int64?, Int64?, Double?) -> Void) {
        self.queueId = queueId; self.onProgress = onProgress
        self.destURL = URL(fileURLWithPath: "/tmp/viddldummy")
    }

    func performDownload(session: URLSession, request: URLRequest) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                let task = session.downloadTask(with: request)
                lock.lock()
                continuation = cont
                downloadTask = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let pct = min(Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100.0), 99)
        guard pct != lastReportedPct else { return }
        lastReportedPct = pct
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleDate)
        let rate: Double?
        if elapsed > 0 {
            rate = Double(totalBytesWritten - lastSampleBytes) / elapsed
        } else {
            rate = nil
        }
        lastSampleBytes = totalBytesWritten
        lastSampleDate = now
        onProgress(Double(pct), totalBytesWritten, totalBytesExpectedToWrite, rate)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: location, to: destURL)
            DispatchQueue.main.async { [self] in self.onProgress(100.0, nil, nil, nil) }
            complete(.success(()))
        } catch {
            complete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let err = error {
            complete(.failure(err))
        }
    }

    private func cancel() {
        lock.lock()
        let task = downloadTask
        lock.unlock()
        task?.cancel()
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        downloadTask = nil
        lock.unlock()

        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}
