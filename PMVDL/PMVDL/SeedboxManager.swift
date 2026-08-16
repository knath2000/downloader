import Foundation

enum SeedboxError: LocalizedError {
    case notInstalled
    case notConfigured
    case headRequestFailed
    case invalidSourceURL
    case transferFailed(String)
    case hlsUnsupported

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "rclone is not installed: brew install rclone"
        case .notConfigured:
            return "Seedbox is not configured."
        case .headRequestFailed:
            return "Source URL did not provide a Content-Length. WebDAV PUT needs a known file size."
        case .invalidSourceURL:
            return "Source URL is invalid."
        case .transferFailed(let message):
            return message
        case .hlsUnsupported:
            return "HLS seedbox transfers require local assembly before upload."
        }
    }
}

enum SeedboxTransferMode {
    case rclone(remoteName: String, remotePath: String)
    case webdav(baseURL: URL, user: String, password: String, remotePath: String, allowSelfSigned: Bool = false)
}

private actor WebDAVDirectoryCache {
    static let shared = WebDAVDirectoryCache()

    private var confirmed: Set<String> = []

    func contains(_ key: String) -> Bool {
        confirmed.contains(key)
    }

    func insert(_ key: String) {
        confirmed.insert(key)
    }
}

final class SeedboxManager {
    private static let minimumDirectMediaBytes: Int64 = 1_024

    private let mode: SeedboxTransferMode

    init(mode: SeedboxTransferMode) {
        self.mode = mode
    }

    static var isRcloneAvailable: Bool {
        findRclone() != nil
    }

    static func reconnectConfiguredWebDAV() async {
        let defaults = UserDefaults.standard
        SecureStore.migrateLegacyString("seedboxWebdavPassword", to: "seedboxWebdavPassword")
        guard defaults.string(forKey: "seedboxTransferMode") == "webdav",
              let urlString = defaults.string(forKey: "seedboxWebdavURL"),
              let baseURL = URLTrustPolicy.validated(urlString),
              baseURL.scheme?.lowercased() == "https",
              let user = defaults.string(forKey: "seedboxWebdavUser"),
              let password = SecureStore.string(forKey: "seedboxWebdavPassword") ?? defaults.string(forKey: "seedboxWebdavPassword"),
              !password.isEmpty else { return }

        let remotePath = defaults.string(forKey: "seedboxRemotePath") ?? "/"
        let allowSelfSigned = defaults.bool(forKey: "seedboxWebdavAllowSelfSigned")
        do {
            try await SeedboxManager(mode: .webdav(
                baseURL: baseURL,
                user: user,
                password: password,
                remotePath: remotePath,
                allowSelfSigned: allowSelfSigned
            )).testConnection()
        } catch {
            NSLog("VidDL WebDAV startup check failed: %@", error.localizedDescription)
        }
    }

    static func isRcloneConfigured(remoteName: String) -> Bool {
        let trimmed = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let rclone = findRclone() else { return false }
        let result = try? SubprocessRunner.runBlocking(
            executable: rclone,
            arguments: ["config", "show", trimmed],
            timeout: 5
        )
        return result?.exitStatus == 0
    }

    @discardableResult
    func upload(
        sourceURL: URL,
        filename: String,
        headers: [String: String]? = nil,
        progressHandler: @escaping (Double) -> Void,
        metricsHandler: @escaping (DownloadTransferMetrics) -> Void = { _ in }
    ) async throws -> String {
        switch mode {
        case .rclone(let remoteName, let remotePath):
            return try await uploadViaRcloneRcat(
                sourceURL: sourceURL,
                remoteName: remoteName,
                remotePath: remotePath,
                filename: filename,
                headers: headers,
                progressHandler: progressHandler
            )
        case .webdav(let baseURL, let user, let password, let remotePath, let allowSelfSigned):
            return try await uploadViaWebDAVPut(
                sourceURL: sourceURL,
                webdavBase: baseURL,
                remotePath: remotePath,
                filename: filename,
                user: user,
                password: password,
                headers: headers,
                allowSelfSigned: allowSelfSigned,
                progressHandler: progressHandler,
                metricsHandler: metricsHandler
            )
        }
    }

    @discardableResult
    func uploadFile(
        at localURL: URL,
        filename: String,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> String {
        switch mode {
        case .rclone(let remoteName, let remotePath):
            let trimmed = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw SeedboxError.notConfigured }
            guard let rclone = Self.findRclone() else { throw SeedboxError.notInstalled }
            guard Self.isRcloneConfigured(remoteName: trimmed) else { throw SeedboxError.notConfigured }

            let destination = Self.rcloneDestination(remoteName: trimmed, remotePath: remotePath, filename: filename)
            var lastPct = -1
            let progressParse: (String) -> Void = { text in
                if let pct = DownloadProgressParsers.rclonePercent(from: text), pct > lastPct {
                    lastPct = pct
                    progressHandler(Double(pct) / 100.0)
                }
            }

            let result = try await SubprocessRunner.run(
                executable: rclone,
                arguments: ["copyto", localURL.path, destination, "--progress", "--transfers=1", "-v"],
                timeout: 7200,
                stdoutHandler: progressParse,
                stderrHandler: progressParse
            )

            if result.exitStatus != 0 {
                let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SeedboxError.transferFailed(message.isEmpty ? "rclone copyto failed (exit \(result.exitStatus))." : message)
            }

            progressHandler(1.0)
            return destination

        case .webdav(let baseURL, let user, let password, let remotePath, let allowSelfSigned):
            let destinationURL = Self.webDAVFileURL(baseURL: baseURL, remotePath: remotePath, filename: filename)
            try await ensureWebDAVDirectory(baseURL: baseURL, remotePath: remotePath, user: user, password: password, allowSelfSigned: allowSelfSigned)

            var putRequest = URLRequest(url: destinationURL)
            putRequest.httpMethod = "PUT"
            putRequest.timeoutInterval = 7200
            putRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            setBasicAuth(user: user, password: password, request: &putRequest)

            let delegate = WebDAVUploadDelegate(contentLength: -1, allowedHost: baseURL.host, allowSelfSigned: allowSelfSigned, progressHandler: progressHandler)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            session.uploadTask(with: putRequest, fromFile: localURL).resume()
            try await delegate.waitForCompletion()
            progressHandler(1.0)
            return destinationURL.absoluteString
        }
    }

    @discardableResult
    func uploadHLS(
        m3u8URL: URL,
        filename: String,
        headers: [String: String]?,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> String {
        guard let ffmpeg = VideoProcessor.findFFmpeg() else {
            throw SeedboxError.transferFailed("ffmpeg not found. Install via: brew install ffmpeg")
        }

        let resolvedURL = try await resolveHLSURL(m3u8URL.absoluteString, headers: headers)
        let totalDuration = try? await fetchHLSDuration(from: resolvedURL, headers: headers)

        var ffmpegHeaderArgs: [String] = []
        if let headers, !headers.isEmpty {
            let headerString = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
            ffmpegHeaderArgs = ["-headers", headerString]
        }

        let tsFilename: String
        if filename.hasSuffix(".mp4") || filename.hasSuffix(".mkv") || filename.hasSuffix(".mov") {
            tsFilename = String(filename.dropLast(4)) + ".ts"
        } else {
            tsFilename = filename + ".ts"
        }

        switch mode {
        case .rclone(let remoteName, let remotePath):
            let ffmpegArgs = ["-y"] + ffmpegHeaderArgs + ["-i", resolvedURL, "-c", "copy", "-f", "mpegts", "-"]
            return try await uploadHLSViaRcloneRcat(
                ffmpegArgs: ffmpegArgs,
                ffmpegPath: ffmpeg,
                remoteName: remoteName,
                remotePath: remotePath,
                filename: tsFilename,
                totalDuration: totalDuration,
                progressHandler: progressHandler
            )
        case .webdav(let baseURL, let user, let password, let remotePath, let allowSelfSigned):
            let ffmpegArgs = ["-y"] + ffmpegHeaderArgs + ["-i", resolvedURL, "-c", "copy", "-movflags", "+faststart"]
            let mp4Filename: String
            if filename.hasSuffix(".ts") {
                mp4Filename = String(filename.dropLast(3)) + ".mp4"
            } else if filename.hasSuffix(".mkv") || filename.hasSuffix(".mov") {
                mp4Filename = String(filename.dropLast(4)) + ".mp4"
            } else {
                mp4Filename = filename
            }
            return try await uploadHLSViaWebDAVPut(
                ffmpegArgs: ffmpegArgs,
                ffmpegPath: ffmpeg,
                webdavBase: baseURL,
                remotePath: remotePath,
                filename: mp4Filename,
                user: user,
                password: password,
                allowSelfSigned: allowSelfSigned,
                totalDuration: totalDuration,
                progressHandler: progressHandler
            )
        }
    }

    func preflight(filename: String) async throws {
        switch mode {
        case .rclone(let remoteName, let remotePath):
            let trimmed = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw SeedboxError.notConfigured }
            guard Self.isRcloneAvailable else { throw SeedboxError.notInstalled }
            guard Self.isRcloneConfigured(remoteName: trimmed) else {
                throw SeedboxError.transferFailed("rclone remote '\(trimmed)' not found in config. Run: rclone config")
            }
            guard let rclone = Self.findRclone() else { throw SeedboxError.notInstalled }

            let destination = Self.rcloneDirectory(remoteName: trimmed, remotePath: remotePath)
            let result = try await SubprocessRunner.run(
                executable: rclone,
                arguments: ["lsd", destination],
                timeout: 15
            )
            if result.exitStatus != 0 {
                let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SeedboxError.transferFailed("Cannot reach seedbox remote '\(trimmed)': \(message)")
            }

        case .webdav(let baseURL, let user, let password, let remotePath, let allowSelfSigned):
            let dirURL = Self.webDAVDirectoryURL(baseURL: baseURL, remotePath: remotePath)
            var propfind = URLRequest(url: dirURL)
            propfind.httpMethod = "PROPFIND"
            propfind.timeoutInterval = 15
            propfind.setValue("0", forHTTPHeaderField: "Depth")
            setBasicAuth(user: user, password: password, request: &propfind)

            let (_, propResponse) = try await webDAVData(for: propfind, baseURL: baseURL, allowSelfSigned: allowSelfSigned)
            if let http = propResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                if http.statusCode == 404 || http.statusCode == 409 {
                    try await ensureWebDAVDirectory(baseURL: baseURL, remotePath: remotePath, user: user, password: password, allowSelfSigned: allowSelfSigned)
                } else {
                    throw SeedboxError.transferFailed("Cannot reach WebDAV path \(dirURL.absoluteString) (HTTP \(http.statusCode)). Check URL and credentials.")
                }
            }

            let probeFilename = ".viddl_probe_\(UUID().uuidString.prefix(8))"
            let probeURL = Self.webDAVFileURL(baseURL: baseURL, remotePath: remotePath, filename: probeFilename)
            let probeBody = Data("viddl".utf8)

            var put = URLRequest(url: probeURL)
            put.httpMethod = "PUT"
            put.timeoutInterval = 15
            put.httpBody = probeBody
            put.setValue(String(probeBody.count), forHTTPHeaderField: "Content-Length")
            put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            setBasicAuth(user: user, password: password, request: &put)

            let (_, putResponse) = try await webDAVData(for: put, baseURL: baseURL, allowSelfSigned: allowSelfSigned)
            guard let putHTTP = putResponse as? HTTPURLResponse, (200..<300).contains(putHTTP.statusCode) else {
                let status = (putResponse as? HTTPURLResponse)?.statusCode ?? -1
                let destinationURL = Self.webDAVFileURL(baseURL: baseURL, remotePath: remotePath, filename: filename)
                throw SeedboxError.transferFailed("Seedbox rejected test write (HTTP \(status)). Cannot PUT to \(destinationURL.path). Check server write permissions.")
            }

            var delete = URLRequest(url: probeURL)
            delete.httpMethod = "DELETE"
            delete.timeoutInterval = 10
            setBasicAuth(user: user, password: password, request: &delete)
            _ = try? await webDAVData(for: delete, baseURL: baseURL, allowSelfSigned: allowSelfSigned)
        }
    }

    func testConnection() async throws {
        try await preflight(filename: ".viddl_connection_test")
    }

    func remoteSize(filename: String) async throws -> Int64? {
        switch mode {
        case .rclone(let remoteName, let remotePath):
            let trimmed = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw SeedboxError.notConfigured }
            guard let rclone = Self.findRclone() else { throw SeedboxError.notInstalled }
            let destination = Self.rcloneDestination(remoteName: trimmed, remotePath: remotePath, filename: filename)
            let result = try await SubprocessRunner.run(
                executable: rclone,
                arguments: ["size", "--json", destination],
                timeout: 15
            )
            guard result.exitStatus == 0,
                  let data = result.stdout.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if let bytes = object["bytes"] as? Int64 { return bytes }
            if let bytes = object["bytes"] as? Int { return Int64(bytes) }
            if let bytes = object["bytes"] as? Double { return Int64(bytes) }
            return nil

        case .webdav(let baseURL, let user, let password, let remotePath, let allowSelfSigned):
            let destinationURL = Self.webDAVFileURL(baseURL: baseURL, remotePath: remotePath, filename: filename)
            var request = URLRequest(url: destinationURL)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 15
            setBasicAuth(user: user, password: password, request: &request)
            let (_, response) = try await webDAVData(for: request, baseURL: baseURL, allowSelfSigned: allowSelfSigned)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 404 { return nil }
            guard (200..<300).contains(http.statusCode) else { return nil }
            if let length = http.value(forHTTPHeaderField: "Content-Length"), let bytes = Int64(length) {
                return bytes
            }
            return response.expectedContentLength > 0 ? response.expectedContentLength : nil
        }
    }

    func verifyRemoteFile(filename: String) async throws {
        guard let size = try await remoteSize(filename: filename), size > 0 else {
            throw SeedboxError.transferFailed("Seedbox did not confirm the uploaded file. Retry the transfer after checking the remote path.")
        }
    }

    static func safeResumedFilename(filename: String, queueId: UUID) -> String {
        let ns = filename as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        let suffix = String(queueId.uuidString.prefix(8)).lowercased()
        let value = "\(base) (resumed \(suffix))"
        return ext.isEmpty ? value : "\(value).\(ext)"
    }

    @discardableResult
    static func uploadLocalFile(
        _ localFile: URL,
        remoteName: String,
        remotePath: String,
        remoteFileName: String? = nil,
        onProgress: @escaping (ProgressEvent) -> Void
    ) async throws -> String {
        let trimmed = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SeedboxError.notConfigured }
        guard let rclone = findRclone() else { throw SeedboxError.notInstalled }
        guard isRcloneConfigured(remoteName: trimmed) else { throw SeedboxError.notConfigured }

        let uniqueName = VideoFileNaming.mp4FileName(
            title: remoteFileName ?? localFile.deletingPathExtension().lastPathComponent,
            fallback: localFile.lastPathComponent
        )
        let destination = rcloneDestination(remoteName: trimmed, remotePath: remotePath, filename: uniqueName)

        onProgress(.verifying(msg: "Verifying video…"))
        try await VideoProcessor.verifyForUpload(localFile)
        ThumbnailCache.generateAndCache(fromLocalFile: localFile.path, forRemoteUrl: localFile.absoluteString)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? Int64) ?? 0
        onProgress(.uploading(msg: "Ready \(MegaManager.fmt(fileSize)) — uploading to seedbox…", pct: 0))

        var lastUploadPct = -1
        let progressHandler: (String) -> Void = { text in
            guard let pct = DownloadProgressParsers.rclonePercent(from: text), pct > lastUploadPct else { return }
            lastUploadPct = pct
            onProgress(.uploading(msg: "Uploading to seedbox… \(pct)%", pct: Double(pct)))
        }

        let result = try await SubprocessRunner.run(
            executable: rclone,
            arguments: ["copyto", localFile.path, destination, "--progress", "--fast-list", "--transfers=1", "-v"],
            timeout: 7200,
            stdoutHandler: progressHandler,
            stderrHandler: progressHandler
        )

        if result.exitStatus != 0 {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SeedboxError.transferFailed(message.isEmpty ? "rclone copyto failed (exit \(result.exitStatus))." : message)
        }

        onProgress(.completed(msg: "Uploaded to seedbox: \(destination)"))
        return destination
    }

    private func uploadViaRcloneRcat(
        sourceURL: URL,
        remoteName: String,
        remotePath: String,
        filename: String,
        headers: [String: String]?,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> String {
        let trimmed = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SeedboxError.notConfigured }
        guard let rclone = Self.findRclone() else { throw SeedboxError.notInstalled }
        guard Self.isRcloneConfigured(remoteName: trimmed) else { throw SeedboxError.notConfigured }

        let contentLength = await fetchContentLength(url: sourceURL, headers: headers)
        try Self.validateKnownMediaLength(contentLength)
        let destination = Self.rcloneDestination(remoteName: trimmed, remotePath: remotePath, filename: filename)

        let process = Process()
        process.executableURL = rclone
        process.arguments = ["rcat", destination]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stderrBuffer = LockedDataBuffer()

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
                expectedBytes: contentLength,
                onChunk: { data in stdinPipe.fileHandleForWriting.write(data) },
                progressHandler: progressHandler
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
                throw SeedboxError.transferFailed("rclone rcat timed out.")
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
            throw SeedboxError.transferFailed(message.isEmpty ? "rclone rcat failed (exit \(process.terminationStatus))." : message)
        }

        progressHandler(1.0)
        return destination
    }

    private func uploadViaWebDAVPut(
        sourceURL: URL,
        webdavBase: URL,
        remotePath: String,
        filename: String,
        user: String,
        password: String,
        headers: [String: String]?,
        allowSelfSigned: Bool,
        progressHandler: @escaping (Double) -> Void,
        metricsHandler: @escaping (DownloadTransferMetrics) -> Void
    ) async throws -> String {
        if MediaRequestHeaders.requiresInitialRange(for: sourceURL) {
            return try await uploadUnknownLengthSourceViaWebDAV(
                sourceURL: sourceURL,
                webdavBase: webdavBase,
                remotePath: remotePath,
                filename: filename,
                user: user,
                password: password,
                headers: headers,
                allowSelfSigned: allowSelfSigned,
                progressHandler: progressHandler
            )
        }

        let contentLength = await fetchContentLength(url: sourceURL, headers: headers)
        try Self.validateKnownMediaLength(contentLength)
        guard contentLength > 0 else {
            return try await uploadUnknownLengthSourceViaWebDAV(
                sourceURL: sourceURL,
                webdavBase: webdavBase,
                remotePath: remotePath,
                filename: filename,
                user: user,
                password: password,
                headers: headers,
                allowSelfSigned: allowSelfSigned,
                progressHandler: progressHandler
            )
        }

        let destinationURL = Self.webDAVFileURL(baseURL: webdavBase, remotePath: remotePath, filename: filename)
        try await ensureWebDAVDirectory(baseURL: webdavBase, remotePath: remotePath, user: user, password: password, allowSelfSigned: allowSelfSigned)

        var putRequest = URLRequest(url: destinationURL)
        putRequest.httpMethod = "PUT"
        putRequest.timeoutInterval = 7200
        putRequest.setValue(String(contentLength), forHTTPHeaderField: "Content-Length")
        putRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        setBasicAuth(user: user, password: password, request: &putRequest)

        guard let streams = Self.boundStreams(bufferSize: 1_024 * 1_024) else {
            throw SeedboxError.transferFailed("Could not create upload streams.")
        }

        let delegate = WebDAVUploadDelegate(contentLength: contentLength, allowedHost: webdavBase.host, allowSelfSigned: allowSelfSigned, progressHandler: progressHandler, metricsHandler: metricsHandler)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        putRequest.httpBodyStream = streams.input
        delegate.bodyStream = streams.input
        let uploadTask = session.uploadTask(withStreamedRequest: putRequest)

        streams.output.open()
        uploadTask.resume()

        do {
            let request = sourceRequest(url: sourceURL, headers: headers)
            try await streamSource(
                request: request,
                expectedBytes: contentLength,
                onChunk: { data in try Self.write(data, to: streams.output) },
                progressHandler: { _ in }
            )
            streams.output.close()
        } catch {
            streams.output.close()
            uploadTask.cancel()
            let streamError: Error
            do {
                try await delegate.waitForCompletion()
                streamError = error
            } catch let uploadError {
                streamError = SeedboxError.transferFailed("WebDAV streamed upload failed: \(uploadError.localizedDescription). Source stream error: \(error.localizedDescription)")
            }
            NSLog("VidDL WebDAV streamed upload failed for %@: %@; retrying with a temporary local file.", sourceURL.absoluteString, streamError.localizedDescription)
            return try await uploadUnknownLengthSourceViaWebDAV(
                sourceURL: sourceURL,
                webdavBase: webdavBase,
                remotePath: remotePath,
                filename: filename,
                user: user,
                password: password,
                headers: headers,
                allowSelfSigned: allowSelfSigned,
                progressHandler: progressHandler
            )
        }

        try await delegate.waitForCompletion()
        progressHandler(1.0)
        return destinationURL.absoluteString
    }

    private func uploadUnknownLengthSourceViaWebDAV(
        sourceURL: URL,
        webdavBase: URL,
        remotePath: String,
        filename: String,
        user: String,
        password: String,
        headers: [String: String]?,
        allowSelfSigned: Bool,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> String {
        let stagedFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddl_webdav_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stagedFile) }

        if MediaRequestHeaders.requiresInitialRange(for: sourceURL) {
            try await downloadRangeRequiredSource(
                sourceURL: sourceURL,
                headers: headers,
                destination: stagedFile
            )
        } else {
            let (downloadURL, response) = try await URLSession.shared.download(for: sourceRequest(url: sourceURL, headers: headers))
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw SeedboxError.transferFailed("Source download failed before WebDAV upload.")
            }
            try Self.validateMediaResponse(http)
            try FileManager.default.moveItem(at: downloadURL, to: stagedFile)
        }

        progressHandler(0.05)
        let destinationURL = Self.webDAVFileURL(baseURL: webdavBase, remotePath: remotePath, filename: filename)
        try await ensureWebDAVDirectory(baseURL: webdavBase, remotePath: remotePath, user: user, password: password, allowSelfSigned: allowSelfSigned)

        var putRequest = URLRequest(url: destinationURL)
        putRequest.httpMethod = "PUT"
        putRequest.timeoutInterval = 7200
        putRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        setBasicAuth(user: user, password: password, request: &putRequest)

        let fileSize = (try? stagedFile.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? -1
        try Self.validateStagedMediaFile(size: fileSize)
        putRequest.setValue(String(fileSize), forHTTPHeaderField: "Content-Length")

        let delegate = WebDAVUploadDelegate(contentLength: fileSize, allowedHost: webdavBase.host, allowSelfSigned: allowSelfSigned) { progress in
            progressHandler(0.05 + progress * 0.95)
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        session.uploadTask(with: putRequest, fromFile: stagedFile).resume()
        try await delegate.waitForCompletion()
        progressHandler(1.0)
        return destinationURL.absoluteString
    }

    private func downloadRangeRequiredSource(
        sourceURL: URL,
        headers: [String: String]?,
        destination: URL
    ) async throws {
        guard let curl = ToolLocator.find("curl") else {
            throw SeedboxError.transferFailed("curl is required for this CDN source.")
        }

        var arguments = [
            "--fail",
            "--location",
            "--http1.1",
            "--retry", "2",
            "--connect-timeout", "30",
            "--max-time", "7200",
            "--range", "0-",
            "--user-agent", NetworkConstants.chromeUserAgent,
            "--output", destination.path
        ]
        for (key, value) in MediaRequestHeaders.sanitized(headers) where key.caseInsensitiveCompare("Range") != .orderedSame {
            arguments += ["--header", "\(key): \(value)"]
        }
        arguments.append(sourceURL.absoluteString)

        let result = try await SubprocessRunner.run(executable: curl, arguments: arguments, timeout: 7_300)
        guard result.exitStatus == 0 else {
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SeedboxError.transferFailed(reason.isEmpty ? "CDN download failed (curl exit \(result.exitStatus))." : reason)
        }
    }

    private func uploadHLSViaRcloneRcat(
        ffmpegArgs: [String],
        ffmpegPath: URL,
        remoteName: String,
        remotePath: String,
        filename: String,
        totalDuration: TimeInterval?,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> String {
        let trimmed = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SeedboxError.notConfigured }
        guard let rclone = Self.findRclone() else { throw SeedboxError.notInstalled }
        guard Self.isRcloneConfigured(remoteName: trimmed) else { throw SeedboxError.notConfigured }

        let destination = Self.rcloneDestination(remoteName: trimmed, remotePath: remotePath, filename: filename)

        let ffmpegProcess = Process()
        ffmpegProcess.executableURL = ffmpegPath
        ffmpegProcess.arguments = ffmpegArgs

        let rcloneProcess = Process()
        rcloneProcess.executableURL = rclone
        rcloneProcess.arguments = ["rcat", destination]

        let transferPipe = Pipe()
        ffmpegProcess.standardOutput = transferPipe
        rcloneProcess.standardInput = transferPipe
        let transferActivity = LockedTransferActivity()

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
                progressHandler(min(0.99, event.percent / 100.0))
            }
        }

        let rcloneStdoutPipe = Pipe()
        rcloneProcess.standardOutput = rcloneStdoutPipe
        rcloneStdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            if let pct = DownloadProgressParsers.rclonePercent(from: text), pct > 0 {
                transferActivity.mark()
            }
        }

        let rcloneStderrPipe = Pipe()
        rcloneProcess.standardError = rcloneStderrPipe
        let rcloneErrBuffer = LockedDataBuffer()
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
                throw SeedboxError.transferFailed("HLS transfer timed out.")
            }
            if !transferActivity.hasActivity && Date() > startupNoDataDeadline {
                ffmpegProcess.terminate()
                rcloneProcess.terminate()
                throw SeedboxError.transferFailed("HLS stream produced no data for seedbox upload. Try local materialization for this provider.")
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        if ffmpegProcess.terminationStatus != 0 {
            throw SeedboxError.transferFailed("ffmpeg failed (exit \(ffmpegProcess.terminationStatus)). HLS URL may be inaccessible or expired.")
        }

        let remainingStderr = rcloneStderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            rcloneErrBuffer.append(remainingStderr)
        }
        if rcloneProcess.terminationStatus != 0 {
            let message = rcloneErrBuffer.string().trimmingCharacters(in: .whitespacesAndNewlines)
            throw SeedboxError.transferFailed(message.isEmpty ? "rclone rcat failed for HLS stream." : message)
        }

        progressHandler(1.0)
        return destination
    }

    private func uploadHLSViaWebDAVPut(
        ffmpegArgs: [String],
        ffmpegPath: URL,
        webdavBase: URL,
        remotePath: String,
        filename: String,
        user: String,
        password: String,
        allowSelfSigned: Bool,
        totalDuration: TimeInterval?,
        progressHandler: @escaping (Double) -> Void
    ) async throws -> String {
        let destinationURL = Self.webDAVFileURL(baseURL: webdavBase, remotePath: remotePath, filename: filename)
        try await ensureWebDAVDirectory(baseURL: webdavBase, remotePath: remotePath, user: user, password: password, allowSelfSigned: allowSelfSigned)

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddl_hls_\(UUID().uuidString.prefix(8)).mp4")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        var toFileArgs = ffmpegArgs
        if toFileArgs.last == "-" {
            toFileArgs[toFileArgs.count - 1] = tempFile.path
        } else {
            toFileArgs.append(tempFile.path)
        }

        progressHandler(0.01)
        let ffmpegResult = try await SubprocessRunner.run(
            executable: ffmpegPath,
            arguments: toFileArgs,
            timeout: 7200,
            stderrHandler: { text in
                if let event = DownloadProgressParsers.ffmpegProgressEvent(from: text, totalDuration: totalDuration),
                   event.phase == .downloading {
                    progressHandler(min(0.70, event.percent / 100.0 * 0.70))
                }
            }
        )

        guard ffmpegResult.exitStatus == 0,
              FileManager.default.fileExists(atPath: tempFile.path) else {
            throw SeedboxError.transferFailed("ffmpeg failed (exit \(ffmpegResult.exitStatus)). HLS URL may be inaccessible or expired.")
        }

        progressHandler(0.71)
        var putRequest = URLRequest(url: destinationURL)
        putRequest.httpMethod = "PUT"
        putRequest.timeoutInterval = 7200
        putRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        setBasicAuth(user: user, password: password, request: &putRequest)

        let fileSize = (try? tempFile.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? -1
        let delegate = WebDAVUploadDelegate(contentLength: fileSize, allowedHost: webdavBase.host, allowSelfSigned: allowSelfSigned) { progress in
            progressHandler(0.71 + progress * 0.29)
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        session.uploadTask(with: putRequest, fromFile: tempFile).resume()
        try await delegate.waitForCompletion()

        progressHandler(1.0)
        return destinationURL.absoluteString
    }

    private func fetchContentLength(url: URL, headers: [String: String]?) async -> Int64 {
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

    private static func validateKnownMediaLength(_ contentLength: Int64) throws {
        guard contentLength < 0 || contentLength >= minimumDirectMediaBytes else {
            throw SeedboxError.transferFailed("Source returned only \(contentLength) bytes, not a playable video.")
        }
    }

    private static func validateMediaResponse(_ response: HTTPURLResponse) throws {
        let mimeType = response.mimeType?.lowercased() ?? ""
        if mimeType.hasPrefix("text/") || mimeType.contains("json") || mimeType.contains("xml") {
            throw SeedboxError.transferFailed("Source returned \(mimeType), not video media.")
        }
        try validateKnownMediaLength(response.expectedContentLength)
    }

    private static func validateStagedMediaFile(size: Int64) throws {
        guard size >= minimumDirectMediaBytes else {
            throw SeedboxError.transferFailed("Source download produced only \(size) bytes, not a playable video.")
        }
    }

    private func streamSource(
        request: URLRequest,
        expectedBytes: Int64,
        onChunk: @escaping (Data) throws -> Void,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        let delegate = SeedboxSourceStreamDelegate(expectedBytes: expectedBytes, onChunk: onChunk) { progress in
            progressHandler(progress)
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await delegate.perform(session: session, request: request)
    }

    private func sourceRequest(url: URL, headers: [String: String]?) -> URLRequest {
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

    private func resolveHLSURL(_ url: String, headers: [String: String]?) async throws -> String {
        guard let urlObj = URL(string: url) else { return url }
        var request = URLRequest(url: urlObj)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

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

    private func fetchHLSDuration(from url: String, headers: [String: String]?) async throws -> TimeInterval? {
        guard let urlObj = URL(string: url) else { return nil }
        var request = URLRequest(url: urlObj)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

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

    private func webDAVData(for request: URLRequest, baseURL: URL, allowSelfSigned: Bool) async throws -> (Data, URLResponse) {
        let delegate = SeedboxTLSDelegate(host: baseURL.host, allowSelfSigned: allowSelfSigned)
        return try await delegate.data(for: request)
    }

    private func ensureWebDAVDirectory(baseURL: URL, remotePath: String, user: String, password: String, allowSelfSigned: Bool) async throws {
        let parts = remotePath.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        let cacheKey = "\(baseURL.absoluteString)|\(user)|\(parts.joined(separator: "/"))"
        if await WebDAVDirectoryCache.shared.contains(cacheKey) { return }

        var current = baseURL
        for part in parts {
            current.appendPathComponent(part, isDirectory: true)
            var request = URLRequest(url: current)
            request.httpMethod = "MKCOL"
            request.timeoutInterval = 15
            setBasicAuth(user: user, password: password, request: &request)
            let (_, response) = try await webDAVData(for: request, baseURL: baseURL, allowSelfSigned: allowSelfSigned)
            guard let http = response as? HTTPURLResponse else { throw SeedboxError.transferFailed("WebDAV MKCOL failed.") }
            if !(200..<300).contains(http.statusCode), http.statusCode != 405, http.statusCode != 409 {
                throw SeedboxError.transferFailed("WebDAV directory creation returned \(http.statusCode).")
            }
        }
        await WebDAVDirectoryCache.shared.insert(cacheKey)
    }

    private func setBasicAuth(user: String, password: String, request: inout URLRequest) {
        let credentials = Data("\(user):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
    }

    private static func findRclone() -> URL? {
        ToolLocator.find("rclone")
    }

    private static func rcloneDestination(remoteName: String, remotePath: String, filename: String) -> String {
        let path = normalizedRclonePath(remotePath)
        return "\(remoteName):\(path)\(filename)"
    }

    private static func rcloneDirectory(remoteName: String, remotePath: String) -> String {
        "\(remoteName):\(normalizedRclonePath(remotePath))"
    }

    private static func normalizedRclonePath(_ remotePath: String) -> String {
        let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "/" {
            return ""
        }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    private static func webDAVDirectoryURL(baseURL: URL, remotePath: String) -> URL {
        var url = baseURL
        for part in remotePath.split(separator: "/").map(String.init).filter({ !$0.isEmpty }) {
            url.appendPathComponent(part, isDirectory: true)
        }
        return url
    }

    private static func webDAVFileURL(baseURL: URL, remotePath: String, filename: String) -> URL {
        var url = webDAVDirectoryURL(baseURL: baseURL, remotePath: remotePath)
        url.appendPathComponent(filename, isDirectory: false)
        return url
    }

    private static func boundStreams(bufferSize: Int) -> (input: InputStream, output: OutputStream)? {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreateBoundPair(nil, &readStream, &writeStream, bufferSize)
        guard let input = readStream?.takeRetainedValue(),
              let output = writeStream?.takeRetainedValue() else {
            return nil
        }
        return (input as InputStream, output as OutputStream)
    }

    private static func write(_ data: Data, to stream: OutputStream) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = stream.write(base.advanced(by: offset), maxLength: data.count - offset)
                if written > 0 {
                    offset += written
                } else if written == 0 {
                    if let error = stream.streamError {
                        throw SeedboxError.transferFailed(error.localizedDescription)
                    }
                    if stream.streamStatus == .closed || stream.streamStatus == .error {
                        throw SeedboxError.transferFailed("Upload stream closed before the transfer finished.")
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                } else {
                    throw SeedboxError.transferFailed(stream.streamError?.localizedDescription ?? "Upload stream write failed.")
                }
            }
        }
    }
}

private final class SeedboxSourceStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let onChunk: (Data) throws -> Void
    private let progressHandler: (Double) -> Void
    private let lock = NSLock()
    private var receivedBytes: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var storedError: Error?

    init(expectedBytes: Int64, onChunk: @escaping (Data) throws -> Void, progressHandler: @escaping (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.onChunk = onChunk
        self.progressHandler = progressHandler
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
            complete(.failure(SeedboxError.transferFailed("Source URL returned HTTP \(http.statusCode).")))
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
                progressHandler(min(0.99, Double(receivedBytes) / Double(expectedBytes)))
            }
        } catch {
            storedError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let storedError {
            complete(.failure(storedError))
        } else if let error, (error as NSError).code != NSURLErrorCancelled {
            complete(.failure(error))
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

final class SeedboxTLSDelegate: NSObject, URLSessionTaskDelegate {
    private let host: String?
    private let allowSelfSigned: Bool

    init(host: String?, allowSelfSigned: Bool) {
        self.host = host?.lowercased()
        self.allowSelfSigned = allowSelfSigned
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        SeedboxTLSTrust.handle(challenge, host: host, allowSelfSigned: allowSelfSigned, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        SeedboxTLSTrust.handle(challenge, host: host, allowSelfSigned: allowSelfSigned, completionHandler: completionHandler)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                defer { session.finishTasksAndInvalidate() }
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { continuation in
            session.downloadTask(with: request) { url, response, error in
                defer { session.finishTasksAndInvalidate() }
                if let error {
                    continuation.resume(throwing: error)
                } else if let url, let response {
                    continuation.resume(returning: (url, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
    }

    func upload(for request: URLRequest, from data: Data) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { continuation in
            session.uploadTask(with: request, from: data) { data, response, error in
                defer { session.finishTasksAndInvalidate() }
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { continuation in
            session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                defer { session.finishTasksAndInvalidate() }
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
    }
}

private enum SeedboxTLSTrust {
    static func handle(_ challenge: URLAuthenticationChallenge, host: String?, allowSelfSigned: Bool, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard allowSelfSigned,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == host,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private final class WebDAVUploadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let contentLength: Int64
    private let progressHandler: (Double) -> Void
    private let metricsHandler: (DownloadTransferMetrics) -> Void
    private let allowedHost: String?
    private let allowSelfSigned: Bool
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var completedResult: Result<Void, Error>?
    private let startedAt = Date()
    var bodyStream: InputStream?

    init(contentLength: Int64, allowedHost: String? = nil, allowSelfSigned: Bool = false, progressHandler: @escaping (Double) -> Void, metricsHandler: @escaping (DownloadTransferMetrics) -> Void = { _ in }) {
        self.contentLength = contentLength
        self.allowedHost = allowedHost?.lowercased()
        self.allowSelfSigned = allowSelfSigned
        self.progressHandler = progressHandler
        self.metricsHandler = metricsHandler
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        SeedboxTLSTrust.handle(challenge, host: allowedHost, allowSelfSigned: allowSelfSigned, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        SeedboxTLSTrust.handle(challenge, host: allowedHost, allowSelfSigned: allowSelfSigned, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        completionHandler(bodyStream)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let total = totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : contentLength
        let elapsed = max(Date().timeIntervalSince(startedAt), 0.01)
        metricsHandler(DownloadTransferMetrics(
            bytesDownloaded: totalBytesSent,
            totalBytes: total > 0 ? total : nil,
            bytesPerSecond: Double(totalBytesSent) / elapsed
        ))
        if total > 0 {
            progressHandler(min(0.99, Double(totalBytesSent) / Double(total)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            complete(.failure(error))
        } else if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            complete(.failure(SeedboxError.transferFailed("WebDAV server returned \(http.statusCode).")))
        } else {
            complete(.success(()))
        }
    }

    func waitForCompletion() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let completedResult {
                lock.unlock()
                switch completedResult {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            switch result {
            case .success:
                continuation.resume()
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        } else {
            completedResult = result
            lock.unlock()
        }
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

private final class LockedTransferActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivityAt: Date?

    var hasActivity: Bool {
        lock.lock()
        let hasActivity = lastActivityAt != nil
        lock.unlock()
        return hasActivity
    }

    func mark() {
        lock.lock()
        lastActivityAt = Date()
        lock.unlock()
    }
}
