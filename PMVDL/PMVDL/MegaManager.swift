import Foundation

enum MegaUpError: LocalizedError {
    case notInstalled, notLoggedIn, uploadFailed(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Mega CLI not installed: brew install --cask megacmd-app"
        case .notLoggedIn: return "Not logged in to Mega"
        case .uploadFailed(let m): return m
        }
    }
}

struct MegaManager {
    private static var tempDir: URL { FileManager.default.temporaryDirectory }
    @MainActor private static var activeUploads: [UUID: MegaUploadHandle] = [:]
    @MainActor private static var canceledUploads: Set<UUID> = []

    static let defaultPath = "/Cloud/VidDL/"

    private struct MegaUploadHandle {
        let process: RunningSubprocess
        let filename: String
    }

    static var isAvailable: Bool { findMegaExec() != nil }

    static var isLoggedIn: Bool {
        guard let exec = findMegaExec() else { return false }
        let result = try? SubprocessRunner.runBlocking(
            executable: exec,
            arguments: ["whoami"],
            timeout: 5
        )
        return result?.exitStatus == 0
    }

    static func cleanupTempFiles() {
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            for name in contents where name.hasPrefix("viddl_") {
                try? FileManager.default.removeItem(atPath: "\(FileManager.default.temporaryDirectory.path)/\(name)")
            }
        } catch {
        }
    }

    static func cancelAllOperations() {
        _ = try? SubprocessRunner.runBlocking(
            executable: URL(fileURLWithPath: "/usr/bin/killall"),
            arguments: ["mega-exec"],
            timeout: 5
        )
    }

    @MainActor
    static func cancelUpload(id: UUID, filenames: [String] = []) async {
        canceledUploads.insert(id)
        var names = filenames
        if let handle = activeUploads[id] {
            names.append(handle.filename)
            handle.process.terminate()
        }
        await cancelTransfers(matching: names)
    }

    private static func findMegaExec() -> URL? {
        ToolLocator.find("mega-exec", extraPaths: ["/Applications/MEGAcmd.app/Contents/MacOS/mega-exec"])
    }

    private static func runMegaOutputCommand(_ megaExec: URL, arguments: [String], timeout: TimeInterval) async -> String? {
        let result = try? await SubprocessRunner.run(
            executable: megaExec,
            arguments: arguments,
            timeout: timeout
        )
        return result?.stdout
    }

    @MainActor
    private static func registerUpload(id: UUID?, process: RunningSubprocess, filename: String) {
        guard let id else { return }
        activeUploads[id] = MegaUploadHandle(process: process, filename: filename)
    }

    @MainActor
    private static func unregisterUpload(id: UUID?) {
        guard let id else { return }
        activeUploads[id] = nil
        canceledUploads.remove(id)
    }

    @MainActor
    private static func isCanceled(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return canceledUploads.contains(id)
    }

    @MainActor
    private static func resetCancelState(_ id: UUID?) {
        guard let id else { return }
        canceledUploads.remove(id)
    }

    @MainActor
    private static func cancelTransfers(matching filenames: [String]) async {
        guard let megaExec = findMegaExec() else { return }
        let names = filenames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "unknown" }
        guard !names.isEmpty else { return }

        guard let output = await runMegaOutputCommand(
            megaExec,
            arguments: ["transfers", "--only-uploads", "--path-display-size=500"],
            timeout: 5
        ) else { return }

        var tags: [String] = []
        for line in output.split(separator: "\n") {
            let lower = String(line).lowercased()
            guard names.contains(where: { lower.contains($0) }) else { continue }
            let parts = lower.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
            if parts.count > 1 {
                tags.append(parts[1])
            }
        }

        for tag in Set(tags) {
            _ = try? await SubprocessRunner.run(
                executable: megaExec,
                arguments: ["cancel", tag],
                timeout: 5
            )
        }
    }

    static func delete(remotePath: String) async throws {
        guard let megaExec = findMegaExec() else { throw MegaUpError.notInstalled }
        guard isLoggedIn else { throw MegaUpError.notLoggedIn }
        let result = try await SubprocessRunner.run(
            executable: megaExec,
            arguments: ["rm", remotePath],
            timeout: 30
        )
        if result.exitStatus != 0 {
            throw MegaUpError.uploadFailed("Failed to delete \(remotePath) (exit \(result.exitStatus))")
        }
    }

    static func listRemoteFiles(remotePath: String = defaultPath) async throws -> [String] {
        guard let megaExec = findMegaExec() else { throw MegaUpError.notInstalled }
        guard isLoggedIn else { throw MegaUpError.notLoggedIn }
        let stdout = await runMegaOutputCommand(megaExec, arguments: ["ls", "--csv", remotePath], timeout: 30) ?? ""
        var filenames: [String] = []
        let lines = stdout.split(omittingEmptySubsequences: true) { $0.isNewline }
        for line in lines {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            filenames.append(s)
        }
        return filenames
    }

    struct UploadResult {
        let remotePath: String
        init(remotePath: String) { self.remotePath = remotePath }
    }

    // MARK: - Upload from local file

    @MainActor
    static func uploadLocalFile(_ localFile: URL, remotePath: String = defaultPath, remoteFileName: String? = nil, uploadID: UUID? = nil, onProgress: @escaping (ProgressEvent) -> Void) async throws -> UploadResult {
        guard let megaExec = findMegaExec() else { throw MegaUpError.notInstalled }
        guard isLoggedIn else { throw MegaUpError.notLoggedIn }
        resetCancelState(uploadID)

        let uploadRemotePath = remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
        let uniqueName = VideoFileNaming.mp4FileName(
            title: remoteFileName ?? localFile.deletingPathExtension().lastPathComponent,
            fallback: localFile.lastPathComponent
        )
        let uploadFile: URL
        var tempUploadDir: URL?
        if localFile.lastPathComponent == uniqueName {
            uploadFile = localFile
        } else {
            let stagingDir = tempDir.appendingPathComponent("viddl_upload_\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let tempFile = stagingDir.appendingPathComponent(uniqueName)
            do {
                try FileManager.default.linkItem(at: localFile, to: tempFile)
            } catch {
                try FileManager.default.copyItem(at: localFile, to: tempFile)
            }
            tempUploadDir = stagingDir
            uploadFile = tempFile
        }
        defer {
            if let tempUploadDir {
                try? FileManager.default.removeItem(at: tempUploadDir)
            }
        }

        onProgress(.verifying(msg: "Verifying video..."))
        if isCanceled(uploadID) { throw MegaUpError.uploadFailed("Upload canceled") }
        try await VideoProcessor.verifyForUpload(localFile)
        if isCanceled(uploadID) { throw MegaUpError.uploadFailed("Upload canceled") }

        ThumbnailCache.generateAndCache(fromLocalFile: localFile.path, forRemoteUrl: localFile.absoluteString)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? Int64) ?? 0
        onProgress(.uploading(msg: "Ready \(fmt(fileSize)) — uploading to Mega…", pct: 0))

        _ = try await SubprocessRunner.run(
            executable: megaExec,
            arguments: ["mkdir", "-p", uploadRemotePath],
            timeout: 30
        )

        onProgress(.uploading(msg: "Uploading to Mega… 0%", pct: 0))
        let uploadProcess = try SubprocessRunner.start(
            executable: megaExec,
            arguments: ["put", uploadFile.path, uploadRemotePath]
        )
        registerUpload(id: uploadID, process: uploadProcess, filename: uniqueName)
        defer { unregisterUpload(id: uploadID) }

        let pollStart = Date()
        var lastPct = 0

        while uploadProcess.isRunning {
            if isCanceled(uploadID) {
                uploadProcess.terminate()
                throw MegaUpError.uploadFailed("Upload canceled")
            }
            guard Date() < pollStart.addingTimeInterval(7200) else {
                uploadProcess.terminate()
                throw MegaUpError.uploadFailed("Upload timed out")
            }
            try await Task.sleep(for: .seconds(2))
            var transferFound = false
            if let stdout = await runMegaOutputCommand(
                megaExec,
                arguments: ["transfers", "--only-uploads", "--path-display-size=500"],
                timeout: 5
            ) {
                for line in stdout.split(separator: "\n") {
                    let s = String(line).trimmingCharacters(in: .whitespaces)
                    guard s.contains(uniqueName) else { continue }
                    transferFound = true
                    if let ipct = DownloadProgressParsers.megaTransferPercent(from: s) {
                        if ipct > lastPct { onProgress(.uploading(msg: "Uploading to Mega… \(ipct)%", pct: Double(ipct))); lastPct = ipct }
                    }
                    if s.contains("FAILED") {
                        uploadProcess.terminate()
                        throw MegaUpError.uploadFailed("Mega upload failed")
                    }
                }
            }
            if !transferFound {
                let elapsed = Date().timeIntervalSince(pollStart)
                let slowPct = min(Int(elapsed / 12), 95)
                if slowPct > lastPct { lastPct = slowPct; onProgress(.uploading(msg: "Uploading to Mega… \(slowPct)%", pct: Double(slowPct))) }
            }
        }

        if isCanceled(uploadID) { throw MegaUpError.uploadFailed("Upload canceled") }
        let uploadResult = try await uploadProcess.wait()
        guard uploadResult.exitStatus == 0 else {
            throw MegaUpError.uploadFailed("mega-exec put failed (exit \(uploadResult.exitStatus))")
        }
        onProgress(.completed(msg: "Uploaded to Mega: \(uploadRemotePath)"))
        return UploadResult(remotePath: uploadRemotePath + uniqueName)
    }

    // MARK: - Upload from URL (download first)

    @MainActor
    static func upload(url: String, remotePath: String = defaultPath, title: String? = nil, headers: [String: String]? = nil, uploadID: UUID? = nil, onProgress: @escaping (ProgressEvent) -> Void) async throws -> UploadResult {
        guard let megaExec = findMegaExec() else { throw MegaUpError.notInstalled }
        guard isLoggedIn else { throw MegaUpError.notLoggedIn }
        resetCancelState(uploadID)

        let uploadRemotePath = remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
        let uniqueName = VideoFileNaming.mp4FileName(title: title, fallback: URL(string: url)?.lastPathComponent ?? "video")
        let stagingDir = tempDir.appendingPathComponent("viddl_upload_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let tempFile = stagingDir.appendingPathComponent(uniqueName)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        // Use URLSession with typed progress
        let delegate = DownloadProgressPEDelegate(onProgress: { pct, msg in onProgress(.downloading(msg: msg, pct: pct)) }, destURL: tempFile)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        try await delegate.performDownload(session: session, request: request)
        if isCanceled(uploadID) { throw MegaUpError.uploadFailed("Upload canceled") }

        onProgress(.verifying(msg: "Verifying downloaded video..."))
        try await VideoProcessor.verifyForUpload(tempFile)
        if isCanceled(uploadID) { throw MegaUpError.uploadFailed("Upload canceled") }

        ThumbnailCache.generateAndCache(fromLocalFile: tempFile.path, forRemoteUrl: url)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempFile.path)[.size] as? Int64) ?? 0
        onProgress(.uploading(msg: "Downloaded \(fmt(fileSize)) — uploading to Mega…", pct: 0))

        _ = try await SubprocessRunner.run(
            executable: megaExec,
            arguments: ["mkdir", "-p", uploadRemotePath],
            timeout: 30
        )

        // Use synchronous put (no -q) so MEGAcmd holds the file open for the entire upload.
        // The -q (queued) flag caused MEGAcmd to create the remote node immediately, making
        // the ls-based completion check return a false positive, which caused defer to delete
        // the temp file while MEGAcmd was still reading it → corrupted upload / decryption error.
        onProgress(.uploading(msg: "Uploading to Mega… 0%", pct: 0))
        let uploadProcess = try SubprocessRunner.start(
            executable: megaExec,
            arguments: ["put", tempFile.path, uploadRemotePath]
        )
        registerUpload(id: uploadID, process: uploadProcess, filename: uniqueName)
        defer { unregisterUpload(id: uploadID) }

        // Poll transfers for progress while the synchronous put is running
        let pollStart = Date()
        var lastPct = 0
        while uploadProcess.isRunning {
            if isCanceled(uploadID) {
                uploadProcess.terminate()
                throw MegaUpError.uploadFailed("Upload canceled")
            }
            guard Date() < pollStart.addingTimeInterval(7200) else {
                uploadProcess.terminate()
                throw MegaUpError.uploadFailed("Upload timed out")
            }
            try await Task.sleep(for: .seconds(2))
            if let stdout = await runMegaOutputCommand(
                megaExec,
                arguments: ["transfers", "--only-uploads", "--path-display-size=500"],
                timeout: 5
            ) {
                for line in stdout.split(separator: "\n") {
                    let s = String(line).trimmingCharacters(in: .whitespaces)
                    guard s.contains(uniqueName) else { continue }
                    if let ipct = DownloadProgressParsers.megaTransferPercent(from: s) {
                        if ipct > lastPct { onProgress(.uploading(msg: "Uploading to Mega… \(ipct)%", pct: Double(ipct))); lastPct = ipct }
                    }
                    if s.contains("FAILED") {
                        uploadProcess.terminate()
                        throw MegaUpError.uploadFailed("Mega upload failed")
                    }
                }
            }
            // Provide estimated progress when transfer hasn't appeared in the queue yet
            let elapsed = Date().timeIntervalSince(pollStart)
            let slowPct = min(Int(elapsed / 12), 95)
            if slowPct > lastPct { lastPct = slowPct; onProgress(.uploading(msg: "Uploading to Mega… \(slowPct)%", pct: Double(slowPct))) }
        }

        if isCanceled(uploadID) { throw MegaUpError.uploadFailed("Upload canceled") }
        let uploadResult = try await uploadProcess.wait()
        guard uploadResult.exitStatus == 0 else {
            throw MegaUpError.uploadFailed("mega-exec put failed (exit \(uploadResult.exitStatus))")
        }
        // defer deletes tempFile here, safely, after MEGAcmd has fully finished reading it
        onProgress(.completed(msg: "Uploaded to Mega: \(uploadRemotePath)"))
        return UploadResult(remotePath: uploadRemotePath + uniqueName)
    }

    static func fmt(_ bytes: Int64) -> String {
        let u = ["B","KB","MB","GB","TB"]; var s = Double(bytes); var i = 0
        while s >= 1024 && i < u.count-1 { s/=1024; i+=1 }
        return String(format:"%.1f %@",s,u[i])
    }
}

// MARK: - URLSession download delegate with typed progress

final class DownloadProgressPEDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let onProgress: (Double, String) -> Void
    private let destURL: URL

    init(onProgress: @escaping (Double, String) -> Void, destURL: URL) {
        self.onProgress = onProgress; self.destURL = destURL
    }

    func performDownload(session: URLSession, request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { cont in continuation = cont
            let task = session.downloadTask(with: request); task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let pct = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100.0)
        let dl = MegaManager.fmt(totalBytesWritten)
        let total = MegaManager.fmt(totalBytesExpectedToWrite)
        onProgress(Double(pct), "Downloading… \(dl)/\(total) \(pct)%")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let httpResponse = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            continuation?.resume(throwing: DownloadError.downloadFailed("CDN returned HTTP \(httpResponse.statusCode) — token may have expired"))
            continuation = nil
            return
        }
        // Guard against HTML responses (e.g. CDN redirected to an error page without a network error)
        if let data = try? Data(contentsOf: location, options: .mappedIfSafe), data.count > 4 {
            let magic = data.prefix(5)
            let isHTML = magic.starts(with: "<html".utf8) || magic.starts(with: "<!DOC".utf8) || magic.starts(with: "<!doc".utf8)
            if isHTML {
                continuation?.resume(throwing: DownloadError.downloadFailed("CDN returned an HTML page instead of video — the URL may have expired or Referer was rejected"))
                continuation = nil
                return
            }
        }
        do { try? FileManager.default.removeItem(at: destURL); try FileManager.default.moveItem(at: location, to: destURL); continuation?.resume() }
        catch { continuation?.resume(throwing: error) }; continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { continuation?.resume(throwing: error); continuation = nil }
    }
}
