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
        let process: Process
        let filename: String
    }

    private final class ProcessOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ newData: Data) {
            lock.lock()
            data.append(newData)
            if data.count > 1_048_576 {
                data.removeFirst(data.count - 1_048_576)
            }
            lock.unlock()
        }

        func string() -> String {
            lock.lock()
            let snapshot = data
            lock.unlock()
            return String(data: snapshot, encoding: .utf8) ?? ""
        }
    }

    static var isAvailable: Bool { findMegaExec() != nil }

    static var isLoggedIn: Bool {
        guard let exec = findMegaExec() else { return false }
        let p = Process(); p.executableURL = exec; p.arguments = ["whoami"]
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["mega-exec"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    @MainActor
    static func cancelUpload(id: UUID, filenames: [String] = []) async {
        canceledUploads.insert(id)
        var names = filenames
        if let handle = activeUploads[id] {
            names.append(handle.filename)
            if handle.process.isRunning {
                handle.process.terminate()
            }
        }
        await cancelTransfers(matching: names)
    }

    private static func findMegaExec() -> URL? {
        ToolLocator.find("mega-exec", extraPaths: ["/Applications/MEGAcmd.app/Contents/MacOS/mega-exec"])
    }

    private static func runMegaOutputCommand(_ megaExec: URL, arguments: [String], timeout: TimeInterval) async -> String? {
        let process = Process()
        process.executableURL = megaExec
        process.arguments = arguments

        let out = Pipe()
        let buffer = ProcessOutputBuffer()
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                buffer.append(data)
            }
        }

        process.standardOutput = out
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        let start = Date()
        while process.isRunning && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if process.isRunning {
            process.terminate()
            let terminateStart = Date()
            while process.isRunning && Date().timeIntervalSince(terminateStart) < 1 {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        let finished = !process.isRunning
        out.fileHandleForReading.readabilityHandler = nil
        if finished {
            let remaining = out.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty {
                buffer.append(remaining)
            }
        }
        return buffer.string()
    }

    @MainActor
    private static func registerUpload(id: UUID?, process: Process, filename: String) {
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
            let cancel = Process()
            cancel.executableURL = megaExec
            cancel.arguments = ["cancel", tag]
            cancel.standardOutput = FileHandle.nullDevice
            cancel.standardError = FileHandle.nullDevice
            try? cancel.run()
            cancel.waitUntilExit()
        }
    }

    static func delete(remotePath: String) async throws {
        guard let megaExec = findMegaExec() else { throw MegaUpError.notInstalled }
        guard isLoggedIn else { throw MegaUpError.notLoggedIn }
        let p = Process()
        p.executableURL = megaExec
        p.arguments = ["rm", remotePath]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let start = Date()
        while p.isRunning && Date().timeIntervalSince(start) < 30 {
            try await Task.sleep(for: .milliseconds(500))
        }
        if p.isRunning { p.terminate(); p.waitUntilExit() }
        if p.terminationStatus != 0 {
            throw MegaUpError.uploadFailed("Failed to delete \(remotePath) (exit \(p.terminationStatus))")
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

        let mkDir = Process()
        mkDir.executableURL = megaExec; mkDir.arguments = ["mkdir", "-p", uploadRemotePath]
        mkDir.standardOutput = FileHandle.nullDevice; mkDir.standardError = FileHandle.nullDevice
        try mkDir.run(); mkDir.waitUntilExit()

        onProgress(.uploading(msg: "Uploading to Mega… 0%", pct: 0))
        let q = Process()
        q.executableURL = megaExec; q.arguments = ["put", uploadFile.path, uploadRemotePath]
        q.standardOutput = FileHandle.nullDevice; q.standardError = FileHandle.nullDevice
        try q.run()
        registerUpload(id: uploadID, process: q, filename: uniqueName)
        defer { unregisterUpload(id: uploadID) }

        let pollStart = Date()
        var lastPct = 0

        while q.isRunning {
            if isCanceled(uploadID) {
                q.terminate(); q.waitUntilExit()
                throw MegaUpError.uploadFailed("Upload canceled")
            }
            guard Date() < pollStart.addingTimeInterval(7200) else {
                q.terminate(); q.waitUntilExit()
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
                    if let m = try? NSRegularExpression(pattern: "([\\d.]+)%\\s+of").firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)),
                       let r = Range(m.range(at: 1), in: s), let pct = Double(s[r]) {
                        let ipct = Int(pct)
                        if ipct > lastPct { onProgress(.uploading(msg: "Uploading to Mega… \(ipct)%", pct: Double(ipct))); lastPct = ipct }
                    }
                    if s.contains("FAILED") {
                        q.terminate(); q.waitUntilExit()
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
        guard q.terminationStatus == 0 else {
            throw MegaUpError.uploadFailed("mega-exec put failed (exit \(q.terminationStatus))")
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
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        try await delegate.performDownload(session: session, request: request)
        if isCanceled(uploadID) { throw MegaUpError.uploadFailed("Upload canceled") }

        onProgress(.verifying(msg: "Verifying downloaded video..."))
        try await VideoProcessor.verifyForUpload(tempFile)
        if isCanceled(uploadID) { throw MegaUpError.uploadFailed("Upload canceled") }

        ThumbnailCache.generateAndCache(fromLocalFile: tempFile.path, forRemoteUrl: url)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempFile.path)[.size] as? Int64) ?? 0
        onProgress(.uploading(msg: "Downloaded \(fmt(fileSize)) — uploading to Mega…", pct: 0))

        let mkDir = Process()
        mkDir.executableURL = megaExec; mkDir.arguments = ["mkdir", "-p", uploadRemotePath]
        mkDir.standardOutput = FileHandle.nullDevice; mkDir.standardError = FileHandle.nullDevice
        try mkDir.run(); mkDir.waitUntilExit()

        // Use synchronous put (no -q) so MEGAcmd holds the file open for the entire upload.
        // The -q (queued) flag caused MEGAcmd to create the remote node immediately, making
        // the ls-based completion check return a false positive, which caused defer to delete
        // the temp file while MEGAcmd was still reading it → corrupted upload / decryption error.
        onProgress(.uploading(msg: "Uploading to Mega… 0%", pct: 0))
        let q = Process()
        q.executableURL = megaExec
        q.arguments = ["put", tempFile.path, uploadRemotePath]
        q.standardOutput = FileHandle.nullDevice; q.standardError = FileHandle.nullDevice
        try q.run()
        registerUpload(id: uploadID, process: q, filename: uniqueName)
        defer { unregisterUpload(id: uploadID) }

        // Poll transfers for progress while the synchronous put is running
        let pollStart = Date()
        var lastPct = 0
        while q.isRunning {
            if isCanceled(uploadID) {
                q.terminate(); q.waitUntilExit()
                throw MegaUpError.uploadFailed("Upload canceled")
            }
            guard Date() < pollStart.addingTimeInterval(7200) else {
                q.terminate(); q.waitUntilExit()
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
                    if let m = try? NSRegularExpression(pattern: "([\\d.]+)%\\s+of").firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)),
                       let r = Range(m.range(at: 1), in: s), let pct = Double(s[r]) {
                        let ipct = Int(pct)
                        if ipct > lastPct { onProgress(.uploading(msg: "Uploading to Mega… \(ipct)%", pct: Double(ipct))); lastPct = ipct }
                    }
                    if s.contains("FAILED") {
                        q.terminate(); q.waitUntilExit()
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
        guard q.terminationStatus == 0 else {
            throw MegaUpError.uploadFailed("mega-exec put failed (exit \(q.terminationStatus))")
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
