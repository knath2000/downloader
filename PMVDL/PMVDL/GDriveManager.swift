import Foundation

enum GDriveError: LocalizedError {
    case notInstalled, notConfigured, invalidSourceURL, uploadFailed(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "rclone not installed: brew install rclone"
        case .notConfigured: return "Google Drive remote not configured: run rclone config"
        case .invalidSourceURL: return "Source URL is invalid."
        case .uploadFailed(let m): return m
        }
    }
}

struct GDriveManager {
    static var isAvailable: Bool { findRclone() != nil }

    static func isConfigured(remoteName: String = "gdrive") -> Bool {
        guard let rclone = findRclone() else { return false }
        let result = try? SubprocessRunner.runBlocking(
            executable: rclone,
            arguments: ["config", "show", remoteName],
            timeout: 5
        )
        return result?.exitStatus == 0
    }

    private static func findRclone() -> URL? {
        ToolLocator.find("rclone")
    }

    static func rcloneDestination(remoteName: String, remotePath: String, filename: String) -> String {
        "\(remoteName):\(normalizedRclonePath(remotePath))\(filename)"
    }

    static func rcloneRcatArguments(remoteName: String, remotePath: String, filename: String) -> [String] {
        ["rcat", rcloneDestination(remoteName: remoteName, remotePath: remotePath, filename: filename)]
    }

    static func normalizedRclonePath(_ remotePath: String) -> String {
        let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "/" {
            return ""
        }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    static func isGoogleDriveQuotaError(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("quota exceeded")
            || lowercased.contains("rate limit")
            || lowercased.contains("user rate limit exceeded")
            || lowercased.contains("rate_limit_exceeded")
            || (lowercased.contains("error 403") && lowercased.contains("queries"))
    }

    static func userFacingRcloneFailureMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isGoogleDriveQuotaError(trimmed) else { return trimmed }
        return "Google Drive rate limit hit. Wait a minute and retry this upload. \(trimmed)"
    }

    @discardableResult
    static func uploadLocalFile(_ localFile: URL, remoteName: String = "gdrive", remotePath: String = "VidDL/", onProgress: @escaping (ProgressEvent) -> Void) async throws -> String {
        guard let rclone = findRclone() else { throw GDriveError.notInstalled }
        guard isConfigured(remoteName: remoteName) else { throw GDriveError.notConfigured }

        let uniqueName = VideoFileNaming.mp4FileName(
            title: localFile.deletingPathExtension().lastPathComponent,
            fallback: localFile.lastPathComponent
        )
        let remoteDest = rcloneDestination(remoteName: remoteName, remotePath: remotePath, filename: uniqueName)

        onProgress(.verifying(msg: "Verifying video…", pct: 0))
        try await VideoProcessor.verifyForUpload(localFile)

        ThumbnailCache.generateAndCache(fromLocalFile: localFile.path, forRemoteUrl: localFile.absoluteString)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? Int64) ?? 0
        onProgress(.uploading(msg: "Ready \(MegaManager.fmt(fileSize)) — uploading to Google Drive…", pct: 0))

        onProgress(.uploading(msg: "Uploading to Google Drive… 0%", pct: 0))

        var lastUploadPct = -1
        let progressHandler: (String) -> Void = { text in
            if let pct = DownloadProgressParsers.rclonePercent(from: text),
               pct > lastUploadPct {
                lastUploadPct = pct
                DispatchQueue.main.async { onProgress(.uploading(msg: "Uploading to Google Drive… \(pct)%", pct: Double(pct))) }
            }
        }

        return try await verifiedUploadOutcome(
            destination: remoteDest,
            expectedSize: fileSize,
            allowUnknownSize: false,
            onVerifying: {
                onProgress(.verifying(msg: "Checking Google Drive…", pct: 99))
            },
            upload: {
                _ = try await retryingQuotaLimitedUpload(
                    onRetry: { attempt, delay in
                        let pct = max(0, lastUploadPct)
                        onProgress(.uploading(
                            msg: "Google Drive rate limit hit; retry \(attempt) in \(Int(delay))s…",
                            pct: Double(pct)
                        ))
                    },
                    operation: {
                        let result: SubprocessResult
                        do {
                            result = try await SubprocessRunner.run(
                                executable: rclone,
                                arguments: ["copyto", localFile.path, remoteDest, "--progress", "--fast-list", "--transfers=1", "-v"],
                                timeout: 7200,
                                stdoutHandler: progressHandler,
                                stderrHandler: progressHandler
                            )
                        } catch SubprocessRunnerError.timedOut {
                            throw GDriveError.uploadFailed("Upload timed out")
                        }

                        if result.exitStatus != 0 {
                            throw GDriveError.uploadFailed(
                                rcloneFailureMessage(
                                    result: result,
                                    fallback: "Upload failed (exit \(result.exitStatus))"
                                )
                            )
                        }
                        return result
                    }
                )
            },
            verify: {
                try await verifyRemoteFile(destination: remoteDest, expectedSize: fileSize, allowUnknownSize: false)
            }
        )
    }

    @discardableResult
    static func uploadStream(
        sourceURL: URL,
        remoteName: String = "gdrive",
        remotePath: String = "VidDL/",
        filename: String,
        headers: [String: String]? = nil,
        onRetry: @escaping (Int, TimeInterval) -> Void = { _, _ in },
        onVerifying: @escaping () -> Void = {},
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        let contentLength = await fetchContentLength(url: sourceURL, headers: headers)
        let expectedSize = contentLength > 0 ? contentLength : nil
        let destination = rcloneDestination(remoteName: remoteName, remotePath: remotePath, filename: filename)
        return try await verifiedUploadOutcome(
            destination: destination,
            expectedSize: expectedSize,
            allowUnknownSize: expectedSize == nil,
            onVerifying: onVerifying,
            upload: {
                _ = try await retryingQuotaLimitedUpload(onRetry: onRetry) {
                    try await uploadStreamOnce(
                        sourceURL: sourceURL,
                        remoteName: remoteName,
                        remotePath: remotePath,
                        filename: filename,
                        headers: headers,
                        expectedBytes: contentLength,
                        onProgress: onProgress
                    )
                }
            },
            verify: {
                try await verifyRemoteFile(
                    destination: destination,
                    expectedSize: expectedSize,
                    allowUnknownSize: expectedSize == nil
                )
            }
        )
    }

    @discardableResult
    private static func uploadStreamOnce(
        sourceURL: URL,
        remoteName: String = "gdrive",
        remotePath: String = "VidDL/",
        filename: String,
        headers: [String: String]? = nil,
        expectedBytes: Int64,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        let trimmed = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GDriveError.notConfigured }
        guard let rclone = findRclone() else { throw GDriveError.notInstalled }
        guard isConfigured(remoteName: trimmed) else { throw GDriveError.notConfigured }

        let destination = rcloneDestination(remoteName: trimmed, remotePath: remotePath, filename: filename)
        let process = Process()
        process.executableURL = rclone
        process.arguments = rcloneRcatArguments(remoteName: trimmed, remotePath: remotePath, filename: filename)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stderrBuffer = GDriveLockedDataBuffer()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
            }
        }

        try process.run()
        var didClosePipe = false
        defer {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if !didClosePipe {
                try? stdinPipe.fileHandleForWriting.close()
            }
        }

        do {
            let request = sourceRequest(url: sourceURL, headers: headers)
            try await streamSource(
                request: request,
                expectedBytes: expectedBytes,
                onChunk: { data in stdinPipe.fileHandleForWriting.write(data) },
                onProgress: onProgress
            )
            try stdinPipe.fileHandleForWriting.close()
            didClosePipe = true
        } catch {
            process.terminate()
            throw error
        }

        let deadline = Date().addingTimeInterval(7200)
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            if Date() > deadline {
                process.terminate()
                throw GDriveError.uploadFailed("Google Drive stream timed out.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            stderrBuffer.append(remainingStderr)
        }

        if process.terminationStatus != 0 {
            let message = stderrBuffer.string().trimmingCharacters(in: .whitespacesAndNewlines)
            throw GDriveError.uploadFailed(message.isEmpty ? "rclone rcat failed (exit \(process.terminationStatus))." : message)
        }

        onProgress(1.0)
        return destination
    }

    @discardableResult
    static func uploadHLSStream(
        m3u8URL: URL,
        remoteName: String = "gdrive",
        remotePath: String = "VidDL/",
        filename: String,
        headers: [String: String]? = nil,
        onRetry: @escaping (Int, TimeInterval) -> Void = { _, _ in },
        onVerifying: @escaping () -> Void = {},
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        let destination = rcloneDestination(remoteName: remoteName, remotePath: remotePath, filename: filename)
        return try await verifiedUploadOutcome(
            destination: destination,
            expectedSize: nil,
            allowUnknownSize: true,
            onVerifying: onVerifying,
            upload: {
                _ = try await retryingQuotaLimitedUpload(onRetry: onRetry) {
                    try await uploadHLSStreamOnce(
                        m3u8URL: m3u8URL,
                        remoteName: remoteName,
                        remotePath: remotePath,
                        filename: filename,
                        headers: headers,
                        onProgress: onProgress
                    )
                }
            },
            verify: {
                try await verifyRemoteFile(destination: destination, expectedSize: nil, allowUnknownSize: true)
            }
        )
    }

    @discardableResult
    private static func uploadHLSStreamOnce(
        m3u8URL: URL,
        remoteName: String = "gdrive",
        remotePath: String = "VidDL/",
        filename: String,
        headers: [String: String]? = nil,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        let trimmed = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GDriveError.notConfigured }
        guard let rclone = findRclone() else { throw GDriveError.notInstalled }
        guard isConfigured(remoteName: trimmed) else { throw GDriveError.notConfigured }
        guard let ffmpeg = VideoProcessor.findFFmpeg() else {
            throw GDriveError.uploadFailed("ffmpeg not found. Install via: brew install ffmpeg")
        }

        let resolvedURL = try await resolveHLSURL(m3u8URL.absoluteString, headers: headers)
        let totalDuration = try? await fetchHLSDuration(from: resolvedURL, headers: headers)
        let destination = rcloneDestination(remoteName: trimmed, remotePath: remotePath, filename: filename)

        var ffmpegHeaderArgs: [String] = []
        if let headers, !headers.isEmpty {
            let headerString = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
            ffmpegHeaderArgs = ["-headers", headerString]
        }

        let ffmpegProcess = Process()
        ffmpegProcess.executableURL = ffmpeg
        ffmpegProcess.arguments = ["-y"] + ffmpegHeaderArgs + ["-i", resolvedURL, "-c", "copy", "-f", "mpegts", "-"]

        let rcloneProcess = Process()
        rcloneProcess.executableURL = rclone
        rcloneProcess.arguments = rcloneRcatArguments(remoteName: trimmed, remotePath: remotePath, filename: filename)

        let transferPipe = Pipe()
        ffmpegProcess.standardOutput = transferPipe
        rcloneProcess.standardInput = transferPipe

        let transferActivity = GDriveLockedTransferActivity()
        let ffmpegStderrPipe = Pipe()
        ffmpegProcess.standardError = ffmpegStderrPipe
        ffmpegStderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if let event = DownloadProgressParsers.ffmpegProgressEvent(from: text, totalDuration: totalDuration),
               event.phase == .downloading {
                if event.percent > 0 {
                    transferActivity.mark()
                }
                onProgress(min(0.99, event.percent / 100.0))
            }
        }

        let rcloneStdoutPipe = Pipe()
        rcloneProcess.standardOutput = rcloneStdoutPipe
        rcloneStdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8),
                  let pct = DownloadProgressParsers.rclonePercent(from: text),
                  pct > 0 else { return }
            transferActivity.mark()
        }

        let rcloneStderrPipe = Pipe()
        let rcloneErrBuffer = GDriveLockedDataBuffer()
        rcloneProcess.standardError = rcloneStderrPipe
        rcloneStderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            rcloneErrBuffer.append(data)
            if let text = String(data: data, encoding: .utf8),
               let pct = DownloadProgressParsers.rclonePercent(from: text),
               pct > 0 {
                transferActivity.mark()
            }
        }

        do {
            try rcloneProcess.run()
            try ffmpegProcess.run()
            try? transferPipe.fileHandleForWriting.close()
        } catch {
            if rcloneProcess.isRunning { rcloneProcess.terminate() }
            if ffmpegProcess.isRunning { ffmpegProcess.terminate() }
            throw error
        }

        defer {
            ffmpegStderrPipe.fileHandleForReading.readabilityHandler = nil
            rcloneStdoutPipe.fileHandleForReading.readabilityHandler = nil
            rcloneStderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        let deadline = Date().addingTimeInterval(7200)
        let startupNoDataDeadline = Date().addingTimeInterval(45)
        while ffmpegProcess.isRunning || rcloneProcess.isRunning {
            if Task.isCancelled {
                ffmpegProcess.terminate()
                rcloneProcess.terminate()
                throw CancellationError()
            }
            if Date() > deadline {
                ffmpegProcess.terminate()
                rcloneProcess.terminate()
                throw GDriveError.uploadFailed("Google Drive HLS stream timed out.")
            }
            if !transferActivity.hasActivity && Date() > startupNoDataDeadline {
                ffmpegProcess.terminate()
                rcloneProcess.terminate()
                throw GDriveError.uploadFailed("HLS stream produced no data for Google Drive upload. Try local download for this provider.")
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        if ffmpegProcess.terminationStatus != 0 {
            throw GDriveError.uploadFailed("ffmpeg failed (exit \(ffmpegProcess.terminationStatus)). HLS URL may be inaccessible or expired.")
        }

        let remainingStderr = rcloneStderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            rcloneErrBuffer.append(remainingStderr)
        }
        if rcloneProcess.terminationStatus != 0 {
            let message = rcloneErrBuffer.string().trimmingCharacters(in: .whitespacesAndNewlines)
            throw GDriveError.uploadFailed(message.isEmpty ? "rclone rcat failed for HLS stream." : message)
        }

        onProgress(1.0)
        return destination
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

        let delegate = GDUploadProgressDelegate(onProgress: onProgress, destURL: tempFile)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        try await delegate.performDownload(session: session, request: request)

        onProgress("Verifying downloaded video…")
        try await VideoProcessor.verifyForUpload(tempFile)

        ThumbnailCache.generateAndCache(fromLocalFile: tempFile.path, forRemoteUrl: url)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempFile.path)[.size] as? Int64) ?? 0
        onProgress("Downloaded \(MegaManager.fmt(fileSize)) — uploading to Google Drive…")

        let remoteDest = "\(remoteName):\(uploadRemotePath)\(uniqueName)"
        onProgress("Uploading to Google Drive… 0%")

        var lastUploadPct = -1
        let progressHandler: (String) -> Void = { text in
            if let pct = DownloadProgressParsers.rclonePercent(from: text),
               pct > lastUploadPct {
                lastUploadPct = pct
                DispatchQueue.main.async { onProgress("Uploading to Google Drive… \(pct)%") }
            }
        }

        return try await verifiedUploadOutcome(
            destination: remoteDest,
            expectedSize: fileSize,
            allowUnknownSize: false,
            onVerifying: {
                onProgress("Checking Google Drive…")
            },
            upload: {
                _ = try await retryingQuotaLimitedUpload(
                    onRetry: { attempt, delay in
                        onProgress("Google Drive rate limit hit; retry \(attempt) in \(Int(delay))s…")
                    },
                    operation: {
                        let result: SubprocessResult
                        do {
                            result = try await SubprocessRunner.run(
                                executable: rclone,
                                arguments: ["copyto", tempFile.path, remoteDest, "--progress", "--fast-list", "--transfers=1", "-v"],
                                timeout: 7200,
                                stdoutHandler: progressHandler,
                                stderrHandler: progressHandler
                            )
                        } catch SubprocessRunnerError.timedOut {
                            throw GDriveError.uploadFailed("Upload timed out")
                        }

                        if result.exitStatus != 0 {
                            throw GDriveError.uploadFailed(
                                rcloneFailureMessage(
                                    result: result,
                                    fallback: "Upload failed (exit \(result.exitStatus))"
                                )
                            )
                        }
                        return result
                    }
                )
            },
            verify: {
                try await verifyRemoteFile(destination: remoteDest, expectedSize: fileSize, allowUnknownSize: false)
            }
        )
    }

}

extension GDriveManager {
    struct RcloneRemoteFileStat: Decodable {
        let isDir: Bool
        let size: Int64?

        enum CodingKeys: String, CodingKey {
            case isDir = "IsDir"
            case size = "Size"
        }
    }

    static func retryingQuotaLimitedUpload<T>(
        onRetry: @escaping (Int, TimeInterval) -> Void,
        operation: () async throws -> T
    ) async throws -> T {
        let delays: [UInt64] = [15_000_000_000, 45_000_000_000]
        var attempt = 0

        while true {
            do {
                return try await operation()
            } catch GDriveError.uploadFailed(let message) where isGoogleDriveQuotaError(message) {
                guard attempt < delays.count else {
                    throw GDriveError.uploadFailed(userFacingRcloneFailureMessage(message))
                }
                let delay = delays[attempt]
                attempt += 1
                onRetry(attempt, TimeInterval(delay) / 1_000_000_000)
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    static func verifiedUploadOutcome(
        destination: String,
        expectedSize: Int64?,
        allowUnknownSize: Bool,
        onVerifying: () -> Void,
        upload: () async throws -> Void,
        verify: () async throws -> Void
    ) async throws -> String {
        do {
            try await upload()
            onVerifying()
            try await verify()
            return destination
        } catch GDriveError.uploadFailed(let message) where isGoogleDriveQuotaError(message) {
            onVerifying()
            do {
                try await verify()
                return destination
            } catch {
                throw GDriveError.uploadFailed(userFacingRcloneFailureMessage(message))
            }
        }
    }

    static func verifyRemoteFile(destination: String, expectedSize: Int64?, allowUnknownSize: Bool) async throws {
        guard let rclone = findRclone() else { throw GDriveError.notInstalled }
        let result = try await SubprocessRunner.run(
            executable: rclone,
            arguments: rcloneVerifyArguments(destination: destination),
            timeout: 60
        )
        guard result.exitStatus == 0 else {
            throw GDriveError.uploadFailed(
                rcloneFailureMessage(
                    result: result,
                    fallback: "Google Drive upload check failed (exit \(result.exitStatus))."
                )
            )
        }
        try validateRemoteFileStat(result.stdout, expectedSize: expectedSize, allowUnknownSize: allowUnknownSize)
    }

    static func rcloneVerifyArguments(destination: String) -> [String] {
        ["lsjson", destination, "--stat", "--files-only", "--no-mimetype", "--no-modtime"]
    }

    static func validateRemoteFileStat(_ json: String, expectedSize: Int64?, allowUnknownSize: Bool) throws {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let stat = try? JSONDecoder().decode(RcloneRemoteFileStat.self, from: data) else {
            throw GDriveError.uploadFailed("Google Drive upload check returned invalid file metadata.")
        }
        guard !stat.isDir else {
            throw GDriveError.uploadFailed("Google Drive upload check found a folder instead of the uploaded file.")
        }
        guard let size = stat.size else {
            throw GDriveError.uploadFailed("Google Drive upload check did not return a file size.")
        }
        if let expectedSize {
            guard size == expectedSize else {
                throw GDriveError.uploadFailed("Google Drive upload check found \(MegaManager.fmt(size)), expected \(MegaManager.fmt(expectedSize)).")
            }
        } else if allowUnknownSize {
            guard size > 0 else {
                throw GDriveError.uploadFailed("Google Drive upload check found an empty file.")
            }
        } else {
            throw GDriveError.uploadFailed("Google Drive upload check requires an expected file size.")
        }
    }

    static func rcloneFailureMessage(result: SubprocessResult, fallback: String) -> String {
        let message = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return userFacingRcloneFailureMessage(message.isEmpty ? fallback : message)
    }
    static func fetchContentLength(url: URL, headers: [String: String]?) async -> Int64 {
        var request = sourceRequest(url: url, headers: headers)
        request.httpMethod = "HEAD"
        request.setValue(nil, forHTTPHeaderField: "Range")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode) else {
            return -1
        }
        if let value = http.value(forHTTPHeaderField: "Content-Length"), let length = Int64(value) {
            return length
        }
        return response.expectedContentLength
    }

    static func streamSource(
        request: URLRequest,
        expectedBytes: Int64,
        onChunk: @escaping (Data) throws -> Void,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let delegate = GDriveSourceStreamDelegate(expectedBytes: expectedBytes, onChunk: onChunk, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await delegate.perform(session: session, request: request)
    }

    static func sourceRequest(url: URL, headers: [String: String]?) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if MediaRequestHeaders.requiresInitialRange(for: url),
           request.value(forHTTPHeaderField: "Range") == nil {
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        }
        return request
    }

    static func resolveHLSURL(_ url: String, headers: [String: String]?) async throws -> String {
        guard let urlObj = URL(string: url) else { return url }
        var request = sourceRequest(url: urlObj, headers: headers)
        request.timeoutInterval = 15

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let text = String(data: data, encoding: .utf8),
              text.contains("#EXT-X-STREAM-INF") else {
            return url
        }

        var bestURL: String?
        var bestHeight = 0
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            guard line.hasPrefix("#EXT-X-STREAM-INF"), index + 1 < lines.count else { continue }
            if let match = NSRegularExpression.firstNumberGroup(in: line, pattern: "RESOLUTION=\\d+x(\\d+)"),
               let height = Int(match), height > bestHeight {
                bestHeight = height
                bestURL = lines[index + 1].trimmingCharacters(in: .whitespaces)
            }
        }

        guard let variant = bestURL else { return url }
        return URL(string: variant, relativeTo: urlObj)?.absoluteString ?? variant
    }

    static func fetchHLSDuration(from url: String, headers: [String: String]?) async throws -> TimeInterval? {
        guard let urlObj = URL(string: url) else { return nil }
        var request = sourceRequest(url: urlObj, headers: headers)
        request.timeoutInterval = 15

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var total: TimeInterval = 0
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("#EXTINF:") {
            if let value = Double(String(line.dropFirst(8)).split(separator: ",").first ?? "") {
                total += value
            }
        }

        return total > 0 ? total : nil
    }
}

private final class GDriveSourceStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let onChunk: (Data) throws -> Void
    private let onProgress: (Double) -> Void
    private let lock = NSLock()
    private var receivedBytes: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var storedError: Error?

    init(expectedBytes: Int64, onChunk: @escaping (Data) throws -> Void, onProgress: @escaping (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.onChunk = onChunk
        self.onProgress = onProgress
    }

    func perform(session: URLSession, request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            complete(.failure(GDriveError.uploadFailed("Source URL returned HTTP \(http.statusCode).")))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try onChunk(data)
            receivedBytes += Int64(data.count)
            if expectedBytes > 0 {
                onProgress(min(0.99, Double(receivedBytes) / Double(expectedBytes)))
            }
        } catch {
            storedError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let storedError {
            complete(.failure(storedError))
        } else if let error {
            complete(.failure(error))
        } else {
            complete(.success(()))
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }
}

private final class GDriveLockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let value = String(data: data, encoding: .utf8) ?? ""
        lock.unlock()
        return value
    }
}

private final class GDriveLockedTransferActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    var hasActivity: Bool {
        lock.lock()
        let value = active
        lock.unlock()
        return value
    }

    func mark() {
        lock.lock()
        active = true
        lock.unlock()
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
