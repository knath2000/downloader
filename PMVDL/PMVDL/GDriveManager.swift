import Foundation

enum GDriveError: LocalizedError {
    case notInstalled, notConfigured, uploadFailed(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "rclone not installed: brew install rclone"
        case .notConfigured: return "Google Drive remote not configured: run rclone config"
        case .uploadFailed(let m): return m
        }
    }
}

struct GDriveManager {
    static var isAvailable: Bool { findRclone() != nil }

    static func isConfigured(remoteName: String = "gdrive") -> Bool {
        guard let rclone = findRclone() else { return false }
        let p = Process()
        p.executableURL = rclone
        p.arguments = ["config", "show", remoteName]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 5 {
            if !p.isRunning { return p.terminationStatus == 0 }
            Thread.sleep(forTimeInterval: 0.1)
        }
        p.terminate(); return false
    }

    private static func findRclone() -> URL? {
        for path in ["/usr/local/bin/rclone", "/opt/homebrew/bin/rclone", "/usr/bin/rclone"] {
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static func uploadLocalFile(_ localFile: URL, remoteName: String = "gdrive", remotePath: String = "VidDL/", onProgress: @escaping (ProgressEvent) -> Void) async throws {
        guard let rclone = findRclone() else { throw GDriveError.notInstalled }
        guard isConfigured(remoteName: remoteName) else { throw GDriveError.notConfigured }

        let uploadRemotePath = remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
        let uniqueName = VideoFileNaming.mp4FileName(
            title: localFile.deletingPathExtension().lastPathComponent,
            fallback: localFile.lastPathComponent
        )
        let remoteDest = "\(remoteName):\(uploadRemotePath)\(uniqueName)"

        onProgress(.uploading(msg: "Verifying video…", pct: 0))
        try await VideoProcessor.verifyForUpload(localFile)

        ThumbnailCache.generateAndCache(fromLocalFile: localFile.path, forRemoteUrl: localFile.absoluteString)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? Int64) ?? 0
        onProgress(.uploading(msg: "Ready \(MegaManager.fmt(fileSize)) — uploading to Google Drive…", pct: 0))

        onProgress(.uploading(msg: "Uploading to Google Drive… 0%", pct: 0))

        let p = Process()
        p.executableURL = rclone
        p.arguments = ["copyto", localFile.path, remoteDest, "--progress", "--fast-list", "--transfers=1", "-v"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let outHandle = outPipe.fileHandleForReading
        var lastUploadPct = -1
        outHandle.readabilityHandler = { (handle: FileHandle) in
            let data = handle.availableData
            if data.isEmpty { outHandle.readabilityHandler = nil; return }
            if let s = String(data: data, encoding: .utf8),
               let pct = extractPercent(s),
               pct > lastUploadPct {
                lastUploadPct = pct
                DispatchQueue.main.async { onProgress(.uploading(msg: "Uploading to Google Drive… \(pct)%", pct: Double(pct))) }
            }
        }

        let errHandle = errPipe.fileHandleForReading
        errHandle.readabilityHandler = { (handle: FileHandle) in
            let data = handle.availableData
            if data.isEmpty { errHandle.readabilityHandler = nil; return }
            if let s = String(data: data, encoding: .utf8),
               let pct = extractPercent(s),
               pct > lastUploadPct {
                lastUploadPct = pct
                DispatchQueue.main.async { onProgress(.uploading(msg: "Uploading to Google Drive… \(pct)%", pct: Double(pct))) }
            }
        }

        try p.run()

        let uploadStart = Date()
        while p.isRunning {
            if Date().timeIntervalSince(uploadStart) > 7200 {
                p.terminate()
                throw GDriveError.uploadFailed("Upload timed out")
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil

        if p.terminationStatus != 0 {
            throw GDriveError.uploadFailed("Upload failed (exit \(p.terminationStatus))")
        }

        onProgress(.completed(msg: "Uploaded to Google Drive: \(remoteDest)"))
    }

    @discardableResult
    static func upload(url: String, remoteName: String = "gdrive", remotePath: String = "VidDL/", title: String? = nil, headers: [String: String]? = nil, onProgress: @escaping (String) -> Void) async throws -> String {
        guard let rclone = findRclone() else { throw GDriveError.notInstalled }
        guard isConfigured(remoteName: remoteName) else { throw GDriveError.notConfigured }

        let uploadRemotePath = remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
        let uniqueName = VideoFileNaming.mp4FileName(title: title, fallback: URL(string: url)?.lastPathComponent ?? "video")
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddl_gdrive_upload_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let tempFile = stagingDir.appendingPathComponent(uniqueName)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        // Download first using URLSession delegate
        let delegate = GDUploadProgressDelegate(onProgress: onProgress, destURL: tempFile)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        try await delegate.performDownload(session: session, request: request)

        onProgress("Verifying downloaded video…")
        try await VideoProcessor.verifyForUpload(tempFile)

        ThumbnailCache.generateAndCache(fromLocalFile: tempFile.path, forRemoteUrl: url)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempFile.path)[.size] as? Int64) ?? 0
        onProgress("Downloaded \(MegaManager.fmt(fileSize)) — uploading to Google Drive…")

        let remoteDest = "\(remoteName):\(uploadRemotePath)\(uniqueName)"
        onProgress("Uploading to Google Drive… 0%")

        let p = Process()
        p.executableURL = rclone
        p.arguments = ["copyto", tempFile.path, remoteDest, "--progress", "--fast-list", "--transfers=1", "-v"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let outHandle = outPipe.fileHandleForReading
        var lastUploadPct = -1
        outHandle.readabilityHandler = { (handle: FileHandle) in
            let data = handle.availableData
            if data.isEmpty { outHandle.readabilityHandler = nil; return }
            if let s = String(data: data, encoding: .utf8),
               let pct = extractPercent(s),
               pct > lastUploadPct {
                lastUploadPct = pct
                DispatchQueue.main.async { onProgress("Uploading to Google Drive… \(pct)%") }
            }
        }

        let errHandle = errPipe.fileHandleForReading
        errHandle.readabilityHandler = { (handle: FileHandle) in
            let data = handle.availableData
            if data.isEmpty { errHandle.readabilityHandler = nil; return }
            if let s = String(data: data, encoding: .utf8),
               let pct = extractPercent(s),
               pct > lastUploadPct {
                lastUploadPct = pct
                DispatchQueue.main.async { onProgress("Uploading to Google Drive… \(pct)%") }
            }
        }

        try p.run()

        let uploadStart = Date()
        while p.isRunning {
            if Date().timeIntervalSince(uploadStart) > 7200 {
                p.terminate()
                throw GDriveError.uploadFailed("Upload timed out")
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        outHandle.readabilityHandler = nil
        errHandle.readabilityHandler = nil

        if p.terminationStatus != 0 {
            throw GDriveError.uploadFailed("Upload failed (exit \(p.terminationStatus))")
        }

        onProgress("Uploaded to Google Drive: \(remoteDest)")
        return remoteDest
    }

    private static func extractPercent(_ text: String) -> Int? {
        if let m = try? NSRegularExpression(
            pattern: "Transferred:[^\\n]*?(\\d+)%"
        ).firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
           let r = Range(m.range(at: 1), in: text),
           let pct = Double(text[r]), pct >= 0 {
            return Int(pct)
        }
        return nil
    }
}

// String-based download delegate (used by GDriveManager.upload)
final class GDUploadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let progressHandler: (String) -> Void
    private let destURL: URL

    init(onProgress: @escaping (String) -> Void, destURL: URL) {
        self.progressHandler = onProgress; self.destURL = destURL
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
        let pct = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100.0)
        if pct != lastReportedPct {
            lastReportedPct = pct
            let dl = MegaManager.fmt(totalBytesWritten)
            let total = MegaManager.fmt(totalBytesExpectedToWrite)
            progressHandler("Downloading… \(dl)/\(total) \(pct)%")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do { try? FileManager.default.removeItem(at: destURL); try FileManager.default.moveItem(at: location, to: destURL); continuation?.resume() }
        catch { continuation?.resume(throwing: error) }; continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { continuation?.resume(throwing: error); continuation = nil }
    }

    private var lastReportedPct: Int = -1
}
