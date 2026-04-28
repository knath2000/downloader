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

    static let defaultPath = "/Cloud/PMVDL/"

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
            for name in contents where name.hasPrefix("pmvdl_") {
                try? FileManager.default.removeItem(atPath: "\(FileManager.default.temporaryDirectory.path)/\(name)")
            }
        } catch {
        }
    }

    static func cancelAllOperations() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["mega-exec"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    private static func findMegaExec() -> URL? {
        for p in ["/Applications/MEGAcmd.app/Contents/MacOS/mega-exec",
                  "/usr/local/bin/mega-exec", "/opt/homebrew/bin/mega-exec"] {
            if FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    static func delete(remotePath: String) async throws {
        guard let megaExec = findMegaExec() else { throw MegaUpError.notInstalled }
        guard isLoggedIn else { throw MegaUpError.notLoggedIn }
        let p = Process()
        p.executableURL = megaExec
        p.arguments = ["rm", remotePath]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        let start = Date()
        while p.isRunning && Date().timeIntervalSince(start) < 30 {
            try await Task.sleep(for: .milliseconds(500))
        }
        if p.isRunning { p.terminate(); _ = p.waitUntilExit() }
        if p.terminationStatus != 0 {
            throw MegaUpError.uploadFailed("Failed to delete \(remotePath) (exit \(p.terminationStatus))")
        }
    }

    static func listRemoteFiles(remotePath: String = defaultPath) async throws -> [String] {
        guard let megaExec = findMegaExec() else { throw MegaUpError.notInstalled }
        guard isLoggedIn else { throw MegaUpError.notLoggedIn }
        let p = Process()
        p.executableURL = megaExec
        p.arguments = ["ls", "--csv", remotePath]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let start = Date()
        while p.isRunning && Date().timeIntervalSince(start) < 30 {
            try await Task.sleep(for: .milliseconds(500))
        }
        if p.isRunning { p.terminate(); _ = p.waitUntilExit() }
        var filenames: [String] = []
        if let data = try? out.fileHandleForReading.readToEnd(),
           let stdout = String(data: data, encoding: .utf8) {
            let lines = stdout.split(omittingEmptySubsequences: true) { $0.isNewline }
            for line in lines {
                let s = String(line).trimmingCharacters(in: .whitespaces)
                guard !s.isEmpty else { continue }
                filenames.append(s)
            }
        }
        return filenames
    }

    struct UploadResult {
        let remotePath: String
        init(remotePath: String) { self.remotePath = remotePath }
    }

    // MARK: - Upload from local file

    @MainActor
    static func uploadLocalFile(_ localFile: URL, remotePath: String = defaultPath, onProgress: @escaping (ProgressEvent) -> Void) async throws -> UploadResult {
        guard let megaExec = findMegaExec() else { throw MegaUpError.notInstalled }
        guard isLoggedIn else { throw MegaUpError.notLoggedIn }

        let uniqueName = localFile.lastPathComponent
        ThumbnailCache.generateAndCache(fromLocalFile: localFile.path, forRemoteUrl: localFile.absoluteString)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? Int64) ?? 0
        onProgress(.uploading(msg: "Ready \(fmt(fileSize)) — uploading to Mega…", pct: 0))

        let mkDir = Process()
        mkDir.executableURL = megaExec; mkDir.arguments = ["mkdir", "-p", remotePath]
        mkDir.standardOutput = Pipe(); mkDir.standardError = Pipe()
        try mkDir.run(); mkDir.waitUntilExit()

        onProgress(.uploading(msg: "Uploading to Mega… queued", pct: 0))
        let q = Process()
        q.executableURL = megaExec; q.arguments = ["put", "-q", localFile.path, remotePath]
        q.standardOutput = Pipe(); q.standardError = Pipe()
        try q.run()
        let qs = Date()
        while Date().timeIntervalSince(qs) < 10 && q.isRunning { try await Task.sleep(for: .milliseconds(500)) }
        if q.isRunning { q.terminate(); _ = q.waitUntilExit() }
        try await Task.sleep(for: .seconds(2))

        onProgress(.uploading(msg: "Uploading to Mega… 0%", pct: 0))
        let pollStart = Date()
        var lastPct = -1, completed = false

        while true {
            guard Date() < pollStart.addingTimeInterval(7200) else { throw MegaUpError.uploadFailed("Upload timed out") }
            try await Task.sleep(for: .seconds(2))
            let t = Process()
            t.executableURL = megaExec; t.arguments = ["transfers", "--only-uploads", "--path-display-size=500"]
            let out = Pipe(); t.standardOutput = out; t.standardError = Pipe()
            try? t.run()
            let readStart = Date()
            while Date().timeIntervalSince(readStart) < 5 && t.isRunning { try await Task.sleep(for: .milliseconds(200)) }
            if t.isRunning { t.terminate() }

            var transferFound = false
            let outData = try? out.fileHandleForReading.readToEnd()
            if let outData = outData, let stdout = String(data: outData, encoding: .utf8) {
                for line in stdout.split(separator: "\n") {
                    let s = String(line).trimmingCharacters(in: .whitespaces)
                    guard s.contains(uniqueName) else { continue }
                    transferFound = true
                    if let m = try? NSRegularExpression(pattern: "([\\d.]+)%\\s+of").firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)),
                       let r = Range(m.range(at: 1), in: s), let pct = Double(s[r]) {
                        let ipct = Int(pct)
                        if ipct > lastPct { onProgress(.uploading(msg: "Uploading to Mega… \(ipct)%", pct: Double(ipct))); lastPct = ipct }
                    }
                    if s.contains("COMPLETED") { completed = true }
                    else if s.contains("FAILED") { throw MegaUpError.uploadFailed("Mega upload failed") }
                }
            }
            if completed { onProgress(.completed(msg: "Uploaded to Mega: \(remotePath)")); return UploadResult(remotePath: remotePath + uniqueName) }
            if !transferFound {
                let elapsed = Date().timeIntervalSince(pollStart)
                if elapsed > 10 {
                    let check = Process()
                    check.executableURL = megaExec; check.arguments = ["ls", remotePath + uniqueName]
                    check.standardOutput = Pipe(); check.standardError = Pipe()
                    try? check.run()
                    let rs = Date()
                    while Date().timeIntervalSince(rs) < 10 && check.isRunning { try await Task.sleep(for: .milliseconds(500)) }
                    if check.isRunning { check.terminate() }; _ = check.waitUntilExit()
                    if check.terminationStatus == 0 { onProgress(.completed(msg: "Uploaded to Mega: \(remotePath)")); return UploadResult(remotePath: remotePath + uniqueName) }
                }
                if lastPct < 5 { lastPct = 0 }
                let slowPct = min(Int(elapsed / 12), 95)
                if slowPct > lastPct { lastPct = slowPct; onProgress(.uploading(msg: "Uploading to Mega… \(slowPct)%", pct: Double(slowPct))) }
            }
        }
    }

    // MARK: - Upload from URL (download first)

    @MainActor
    static func upload(url: String, remotePath: String = defaultPath, headers: [String: String]? = nil, onProgress: @escaping (ProgressEvent) -> Void) async throws -> UploadResult {
        guard let megaExec = findMegaExec() else { throw MegaUpError.notInstalled }
        guard isLoggedIn else { throw MegaUpError.notLoggedIn }

        let ext = URL(string: url)?.pathExtension ?? "mp4"
        let shortUUID = UUID().uuidString.prefix(8).lowercased()
        let uniqueName = "pmvdl_\(shortUUID).\(ext)"
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(uniqueName)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        // Use URLSession with typed progress
        let delegate = DownloadProgressPEDelegate(onProgress: { pct, msg in onProgress(.downloading(msg: msg, pct: pct)) }, destURL: tempFile)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        try await delegate.performDownload(session: session, request: request)

        ThumbnailCache.generateAndCache(fromLocalFile: tempFile.path, forRemoteUrl: url)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempFile.path)[.size] as? Int64) ?? 0
        onProgress(.uploading(msg: "Downloaded \(fmt(fileSize)) — uploading to Mega…", pct: 0))

        let mkDir = Process()
        mkDir.executableURL = megaExec; mkDir.arguments = ["mkdir", "-p", remotePath]
        mkDir.standardOutput = Pipe(); mkDir.standardError = Pipe()
        try mkDir.run(); mkDir.waitUntilExit()

        onProgress(.uploading(msg: "Uploading to Mega… queued", pct: 0))
        let q = Process()
        q.executableURL = megaExec; q.arguments = ["put", "-q", tempFile.path, remotePath]
        q.standardOutput = Pipe(); q.standardError = Pipe()
        try q.run()
        let qs = Date()
        while Date().timeIntervalSince(qs) < 10 && q.isRunning { try await Task.sleep(for: .milliseconds(500)) }
        if q.isRunning { q.terminate(); _ = q.waitUntilExit() }
        try await Task.sleep(for: .seconds(2))

        onProgress(.uploading(msg: "Uploading to Mega… 0%", pct: 0))
        let pollStart = Date()
        var lastPct = -1, completed = false

        while true {
            guard Date() < pollStart.addingTimeInterval(7200) else { try? FileManager.default.removeItem(at: tempFile); throw MegaUpError.uploadFailed("Upload timed out") }
            try await Task.sleep(for: .seconds(2))
            let t = Process()
            t.executableURL = megaExec; t.arguments = ["transfers", "--only-uploads", "--path-display-size=500"]
            let out = Pipe(); t.standardOutput = out; t.standardError = Pipe()
            try? t.run()
            let readStart = Date()
            while Date().timeIntervalSince(readStart) < 5 && t.isRunning { try await Task.sleep(for: .milliseconds(200)) }
            if t.isRunning { t.terminate() }

            var transferFound = false
            let outData = try? out.fileHandleForReading.readToEnd()
            if let outData = outData, let stdout = String(data: outData, encoding: .utf8) {
                for line in stdout.split(separator: "\n") {
                    let s = String(line).trimmingCharacters(in: .whitespaces)
                    guard s.contains(uniqueName) else { continue }
                    transferFound = true
                    if let m = try? NSRegularExpression(pattern: "([\\d.]+)%\\s+of").firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)),
                       let r = Range(m.range(at: 1), in: s), let pct = Double(s[r]) {
                        let ipct = Int(pct)
                        if ipct > lastPct { onProgress(.uploading(msg: "Uploading to Mega… \(ipct)%", pct: Double(ipct))); lastPct = ipct }
                    }
                    if s.contains("COMPLETED") { completed = true }
                    else if s.contains("FAILED") { try? FileManager.default.removeItem(at: tempFile); throw MegaUpError.uploadFailed("Mega upload failed") }
                }
            }
            if completed { try? FileManager.default.removeItem(at: tempFile); onProgress(.completed(msg: "Uploaded to Mega: \(remotePath)")); return UploadResult(remotePath: remotePath + uniqueName) }
            if !transferFound {
                let elapsed = Date().timeIntervalSince(pollStart)
                if elapsed > 10 {
                    let check = Process()
                    check.executableURL = megaExec; check.arguments = ["ls", remotePath + uniqueName]
                    check.standardOutput = Pipe(); check.standardError = Pipe()
                    try? check.run()
                    let rs = Date()
                    while Date().timeIntervalSince(rs) < 10 && check.isRunning { try await Task.sleep(for: .milliseconds(500)) }
                    if check.isRunning { check.terminate() }; _ = check.waitUntilExit()
                    if check.terminationStatus == 0 { try? FileManager.default.removeItem(at: tempFile); onProgress(.completed(msg: "Uploaded to Mega: \(remotePath)")); return UploadResult(remotePath: remotePath + uniqueName) }
                }
                if lastPct < 5 { lastPct = 0 }
                let slowPct = min(Int(elapsed / 12), 95)
                if slowPct > lastPct { lastPct = slowPct; onProgress(.uploading(msg: "Uploading to Mega… \(slowPct)%", pct: Double(slowPct))) }
            }
        }
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
        do { try? FileManager.default.removeItem(at: destURL); try FileManager.default.moveItem(at: location, to: destURL); continuation?.resume() }
        catch { continuation?.resume(throwing: error) }; continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { continuation?.resume(throwing: error); continuation = nil }
    }
}
