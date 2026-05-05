import Foundation


private final class DownloadOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""

    func append(_ value: String) {
        lock.lock()
        output.append(value)
        if output.count > 20_000 {
            output.removeFirst(output.count - 20_000)
        }
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = output
        lock.unlock()
        return snapshot
    }
}

struct HLSDownloader {
    // MARK: - HLS/M3U8 via ffmpeg

    /// Downloads an HLS/m3u8 stream using ffmpeg and saves as .mp4.
    /// Resolves master playlists to a concrete variant before downloading.
    /// Optional headers are passed to ffmpeg for sites that require referer/user-agent.
    /// For LuluStream sources (identified by sourcePageUrl containing "luluvdo" or "luluvid"),
    /// this method re-resolves the stream URL at download time and uses a local segment
    /// download path instead of ffmpeg remote fetch, avoiding 403 errors.
    func downloadHLS(m3u8Url: String, title: String? = nil,
                     headers: [String: String]? = nil,
                     sourcePageUrl: String? = nil,
                     onProgress: @escaping (ProgressEvent) -> Void) async throws -> URL {
        // Check if this is a LuluStream source that needs the local download path
        let isLuluSource = sourcePageUrl?.contains("lulu") == true
        if isLuluSource {
            return try await downloadHLSLuluStream(
                m3u8Url: m3u8Url, title: title,
                sourcePageUrl: sourcePageUrl ?? "",
                headers: headers, onProgress: onProgress
            )
        }

        // Normal HLS: use ffmpeg remote fetch (existing path)
        guard let ffmpeg = VideoProcessor.findFFmpeg() else {
            throw DownloadError.toolNotFound("ffmpeg")
        }

        // Resolve master playlist to a concrete media variant
        let resolvedUrl = try await resolveHlsUrl(m3u8Url, headers: headers)

        // Pre-fetch duration from the concrete media playlist (non-fatal if it fails)
        let totalDuration = try? await fetchHlsDuration(from: resolvedUrl, headers: headers)

        let filename = VideoFileNaming.mp4FileName(title: title, fallback: "hls_video")
        let destFile = DownloadPaths.downloadDir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destFile)

        // Build ffmpeg arguments with optional headers
        var args = ["-y"]
        if let headers = headers, !headers.isEmpty {
            let headerStr = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
            args.append(contentsOf: ["-headers", headerStr])
        }
        args.append(contentsOf: ["-i", resolvedUrl, "-c", "copy", "-movflags", "+faststart", destFile.path])

        let errBuffer = DownloadOutputBuffer()

        onProgress(.downloading(msg: "Downloading HLS… starting…", pct: 0))
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                executable: ffmpeg,
                arguments: args,
                timeout: 7200,
                stderrHandler: { text in
                    errBuffer.append(text)
                    if let event = DownloadProgressParsers.ffmpegProgressEvent(from: text, totalDuration: totalDuration) {
                        onProgress(event)
                    }
                }
            )
        } catch SubprocessRunnerError.timedOut {
            throw DownloadError.timedOut
        }
        if !result.stderr.isEmpty {
            errBuffer.append(result.stderr)
        }

        guard result.exitStatus == 0,
              FileManager.default.fileExists(atPath: destFile.path) else {
            throw DownloadError.downloadFailed("ffmpeg exit \(result.exitStatus): \(summarizeToolError(errBuffer.string()))")
        }

        onProgress(.completed(msg: "Download complete"))
        return destFile
    }

    /// LuluStream-specific HLS download path.
    /// Re-resolves the stream URL from the embed page, fetches segments locally via URLSession,
    /// and uses ffmpeg only for local muxing (no remote network fetch from ffmpeg).
    /// For AE S-128 encrypted streams, downloads the key and builds a local .m3u8 playlist.
    private func downloadHLSLuluStream(m3u8Url: String, title: String? = nil,
                                       sourcePageUrl: String, headers: [String: String]? = nil,
                                       onProgress: @escaping (ProgressEvent) -> Void) async throws -> URL {
        // Prefer the extracted URL. Refresh is only a fallback if the chosen URL is stale.
        let candidateUrls = [m3u8Url, try? await LuluStreamExtractor.refreshHlsUrl(from: sourcePageUrl, headers: headers)]
            .compactMap { $0 }

        // Fetch the media playlist
        onProgress(.downloading(msg: "Downloading playlist…", pct: 0))
        var playlistText: String?
        var activeUrl: String?
        var fetchError: Error?
        for candidate in candidateUrls {
            do {
                let text = try await fetchPlaylistText(candidate, headers: headers)
                playlistText = text
                activeUrl = candidate
                break
            } catch {
                fetchError = error
            }
        }
        guard var playlistTextUnwrapped = playlistText, let activeUrlUnwrapped = activeUrl else {
            throw fetchError ?? DownloadError.downloadFailed("Failed to fetch LuluStream playlist")
        }

        // If master playlist, resolve to media variant
        let resolvedUrl: String
        if playlistTextUnwrapped.contains("#EXT-X-STREAM-INF") {
            resolvedUrl = try await resolveHlsUrl(activeUrlUnwrapped, headers: headers)
            playlistTextUnwrapped = try await fetchPlaylistText(resolvedUrl, headers: headers)
        } else {
            resolvedUrl = activeUrlUnwrapped
        }

        guard let baseURL = URL(string: resolvedUrl) else {
            throw DownloadError.downloadFailed("Invalid URL")
        }

        // Check for AES-128 encryption
        let isEncrypted = playlistTextUnwrapped.contains("#EXT-X-KEY")

        if isEncrypted {
            onProgress(.downloading(msg: "Encrypted stream detected…", pct: 5))
            return try await downloadEncryptedHLS(
                playlistText: playlistTextUnwrapped,
                baseURL: baseURL,
                destFile: DownloadPaths.downloadDir.appendingPathComponent(VideoFileNaming.mp4FileName(title: title, fallback: "lulustream_video")),
                headers: headers,
                onProgress: onProgress
            )
        } else {
            // Unencrypted: use the existing fast concat path
            return try await downloadAndConcatHLS(
                playlistText: playlistTextUnwrapped,
                baseURL: baseURL,
                destFile: DownloadPaths.downloadDir.appendingPathComponent(VideoFileNaming.mp4FileName(title: title, fallback: "lulustream_video")),
                headers: headers,
                onProgress: onProgress
            )
        }
    }

    /// Download AES-128 encrypted HLS: fetch segments + keys, build a local .m3u8, mux with ffmpeg.
    private func downloadEncryptedHLS(playlistText: String, baseURL: URL,
                                      destFile: URL, headers: [String: String]?,
                                      onProgress: @escaping (ProgressEvent) -> Void) async throws -> URL {
        try? FileManager.default.removeItem(at: destFile)

        // Create temp dir for all artifacts
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddl_enc_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let segLines = playlistText.components(separatedBy: .newlines)

        struct EncryptedSegment {
            let uri: String
            let segId: Int
            let keyId: Int?
            let ivHex: String?
            let sequence: Int
        }

        // Parse the playlist and capture the active key/IV for each segment.
        var keyUrls: [(uri: String, keyId: Int)] = []
        var segUrls: [EncryptedSegment] = []
        var keyIdCounter = 0
        var segIdCounter = 0
        var currentKeyId: Int? = nil
        var currentIVHex: String? = nil
        var mediaSequence = 0

        for line in segLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                if let seq = Int(trimmed.replacingOccurrences(of: "#EXT-X-MEDIA-SEQUENCE:", with: "")) {
                    mediaSequence = seq
                }
            } else if trimmed.hasPrefix("#EXT-X-KEY:") {
                guard let uri = extractAttribute(from: trimmed, attribute: "URI") else {
                    throw DownloadError.downloadFailed("HLS KEY directive found but no URI attribute. Playlist line: \(trimmed)")
                }
                let localKeyName = "key_\(keyIdCounter).bin"
                let keyUrl = URL(string: uri, relativeTo: baseURL)?.absoluteString ?? uri
                keyUrls.append((uri: keyUrl, keyId: keyIdCounter))
                currentKeyId = keyIdCounter
                currentIVHex = extractAttribute(from: trimmed, attribute: "IV")
                keyIdCounter += 1
                let _ = localKeyName
            } else if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                let segUrl = URL(string: trimmed, relativeTo: baseURL)?.absoluteString ?? trimmed
                segUrls.append(
                    EncryptedSegment(
                        uri: segUrl,
                        segId: segIdCounter,
                        keyId: currentKeyId,
                        ivHex: currentIVHex,
                        sequence: mediaSequence + segIdCounter
                    )
                )
                segIdCounter += 1
            }
        }

        guard !segUrls.isEmpty else {
            throw DownloadError.downloadFailed("No HLS segments found in encrypted playlist")
        }

        // Download key files
        onProgress(.downloading(msg: "Fetching decryption key…", pct: 10))
        var keyFileMap: [Int: URL] = [:]
        for (uri, keyId) in keyUrls {
            guard let keyUrl = URL(string: uri) else {
                throw DownloadError.downloadFailed("Invalid key URL in KEY directive: URI=\(uri)")
            }
            var req = URLRequest(url: keyUrl)
            req.timeoutInterval = 15
            if let headers = headers {
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            }
            let keyData = try await validatedData(
                for: req,
                kind: "HLS key",
                minimumBytes: 16
            )
            let localKeyPath = tempDir.appendingPathComponent(String(format: "key_%d.bin", keyId))
            try keyData.write(to: localKeyPath)
            keyFileMap[keyId] = localKeyPath
        }

        // Download encrypted segments.
        onProgress(.downloading(msg: "Downloading encrypted segments…", pct: 20))
        var encryptedSegPaths: [URL] = []
        for (i, segInfo) in segUrls.enumerated() {
            guard let segUrl = URL(string: segInfo.uri) else {
                throw DownloadError.downloadFailed("Invalid segment URL: \(segInfo.uri)")
            }
            var req = URLRequest(url: segUrl)
            req.timeoutInterval = 60
            if let headers = headers {
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            }
            let data = try await validatedData(
                for: req,
                kind: "HLS segment",
                minimumBytes: 1024,
                disallowHTML: true
            )
            let segFile = tempDir.appendingPathComponent(String(format: "seg_%04d.ts", segInfo.segId))
            try data.write(to: segFile)
            encryptedSegPaths.append(segFile)

            let pct = min(80, 20 + Double(i + 1) / Double(segUrls.count) * 55)
            onProgress(.downloading(msg: String(format: "Segments %d/%d (%.0f%%)", i + 1, segUrls.count, pct), pct: pct))
        }

        // Decrypt the encrypted transport stream segments locally.
        onProgress(.downloading(msg: "Decrypting segments…", pct: 82))
        var decryptedSegPaths: [URL] = []
        for (idx, segInfo) in segUrls.enumerated() {
            guard let keyId = segInfo.keyId, let keyPath = keyFileMap[keyId] else {
                throw DownloadError.downloadFailed("Missing HLS key for segment \(segInfo.segId)")
            }
            let keyData = try Data(contentsOf: keyPath)
            let encData = try Data(contentsOf: encryptedSegPaths[idx])
            let ivData = try EncryptedHLSDecoder.ivData(from: segInfo.ivHex, sequence: segInfo.sequence)
            let decData = try EncryptedHLSDecoder.decryptAES128CBC(data: encData, key: keyData, iv: ivData)
            let decFile = tempDir.appendingPathComponent(String(format: "dec_%04d.ts", segInfo.segId))
            try decData.write(to: decFile)
            decryptedSegPaths.append(decFile)
        }

        // Use the existing concat/remux path on decrypted TS files.
        onProgress(.downloading(msg: "Remuxing decrypted segments…", pct: 95))
        return try await muxLocalSegmentsConcat(
            segPaths: decryptedSegPaths,
            destFile: destFile,
            onProgress: onProgress
        )
    }

    /// Download unencrypted HLS: fetch segments, concat with ffmpeg.
    private func downloadAndConcatHLS(playlistText: String, baseURL: URL,
                                      destFile: URL, headers: [String: String]?,
                                      onProgress: @escaping (ProgressEvent) -> Void) async throws -> URL {
        // Parse the playlist: collect segment lines
        let segLines = playlistText.components(separatedBy: .newlines)
        var segInfos: [(segId: Int, url: URL)] = []
        var segId = 0
        for line in segLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                if let segUrl = URL(string: trimmed, relativeTo: baseURL) {
                    segInfos.append((segId: segId, url: segUrl))
                }
                segId += 1
            }
        }

        guard !segInfos.isEmpty else {
            throw DownloadError.downloadFailed("No HLS segments found in playlist")
        }

        // Temp dir for segments
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddl_plain_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Download segments
        var downloadedPaths: [URL] = []
        for (i, segInfo) in segInfos.enumerated() {
            var req = URLRequest(url: segInfo.url)
            req.timeoutInterval = 60
            if let headers = headers {
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            } else {
                req.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
            }

            let (data, _) = try await URLSession.shared.data(for: req)
            let segFile = tempDir.appendingPathComponent(String(format: "seg_%04d.ts", segInfo.segId))
            try data.write(to: segFile)
            downloadedPaths.append(segFile)

            let pct = min(94, Double(i + 1) / Double(segInfos.count) * 100)
            onProgress(.downloading(msg: String(format: "Segments %d/%d (%.0f%%)", i + 1, segInfos.count, pct), pct: pct))
        }

        // Concat & mux
        return try await muxLocalSegmentsConcat(
            segPaths: downloadedPaths,
            destFile: destFile,
            onProgress: onProgress
        )
    }

    /// Extract an attribute value from an HLS directive.
    /// e.g. extractAttribute(from: #EXT-X-KEY:METHOD=AES-128,URI="https://...", attribute: "URI") -> "https://..."
    private func extractAttribute(from line: String, attribute: String) -> String? {
        let pattern = attribute + #"\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[range])
    }

    /// Replace an attribute value in an HLS directive line.
    private func replaceAttributeInLine(_ line: String, attribute: String, value: String) -> String {
        let pattern = attribute + #"\s*=\s*"[^"]*""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line) else {
            return line
        }
        let replacement = #"\#(attribute)="\#(value)""#
        var updated = line
        updated.replaceSubrange(range, with: replacement)
        return updated
    }

    /// Concatenate segments and remux to MP4 using ffmpeg concat demuxer.
    private func muxLocalSegmentsConcat(segPaths: [URL], destFile: URL,
                                        onProgress: @escaping (ProgressEvent) -> Void) async throws -> URL {
        try? FileManager.default.removeItem(at: destFile)

        guard let ffmpeg = VideoProcessor.findFFmpeg() else {
            throw DownloadError.toolNotFound("ffmpeg")
        }

        // Write concat list
        let concatContent = segPaths.map { "file '\($0.path)'" }.joined(separator: "\n")
        let concatFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddl_concat_\(UUID().uuidString.prefix(8)).txt")
        try concatContent.write(to: concatFile, atomically: true, encoding: .utf8)

        onProgress(.downloading(msg: "Concatenating…", pct: 95))

        let result = try await SubprocessRunner.run(
            executable: ffmpeg,
            arguments: [
            "-y", "-f", "concat", "-safe", "0",
            "-i", concatFile.path,
            "-c", "copy", "-movflags", "+faststart",
            destFile.path
            ],
            timeout: 7200
        )

        // Clean up temp files
        try? FileManager.default.removeItem(at: concatFile)
        for seg in segPaths {
            try? FileManager.default.removeItem(at: seg)
        }

        guard result.exitStatus == 0,
              FileManager.default.fileExists(atPath: destFile.path) else {
            throw DownloadError.downloadFailed(
                "Unencrypted HLS concat/mux failed (exit \(result.exitStatus)). " +
                "ffmpeg stderr: \(result.stderr.prefix(500))"
            )
        }

        return destFile
    }

    /// Fetch playlist text with proper headers.
    private func fetchPlaylistText(_ url: String, headers: [String: String]?) async throws -> String {
        guard let urlObj = URL(string: url) else { throw DownloadError.downloadFailed("Invalid URL") }
        var request = URLRequest(url: urlObj)
        request.timeoutInterval = 30
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        } else {
            request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DownloadError.downloadFailed("Failed to decode playlist")
        }
        return text
    }

    private func validatedData(for request: URLRequest, kind: String,
                               minimumBytes: Int? = nil,
                               disallowHTML: Bool = false) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.downloadFailed("\(kind) request did not return an HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DownloadError.downloadFailed(
                "\(kind) request failed with HTTP \(httpResponse.statusCode) for \(request.url?.absoluteString ?? "unknown URL")"
            )
        }
        if disallowHTML,
           let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           contentType.contains("text/html") {
            throw DownloadError.downloadFailed(
                "\(kind) request returned HTML for \(request.url?.absoluteString ?? "unknown URL")"
            )
        }
        if let minimumBytes, data.count < minimumBytes {
            throw DownloadError.downloadFailed(
                "\(kind) response was too small (\(data.count) bytes) for \(request.url?.absoluteString ?? "unknown URL")"
            )
        }
        return data
    }

    /// Resolve a master HLS playlist URL to a concrete media variant URL.
    /// If the URL is already a media playlist, returns it unchanged.
    private func resolveHlsUrl(_ url: String, headers: [String: String]? = nil) async throws -> String {
        guard let urlObj = URL(string: url) else { return url }
        var request = URLRequest(url: urlObj)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        if let headers = headers { headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) } }
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else { return url }

        // If it has #EXT-X-STREAM-INF, it's a master playlist
        guard text.contains("#EXT-X-STREAM-INF") else { return url }

        // Pick the highest quality variant
        var bestUrl: String?
        var bestHeight = 0
        let lines = text.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            guard line.hasPrefix("#EXT-X-STREAM-INF"), i + 1 < lines.count else { continue }
            if let match = NSRegularExpression.firstNumberGroup(in: line, pattern: "RESOLUTION=\\d+x(\\d+)"),
               let h = Int(match), h > bestHeight {
                bestHeight = h
                bestUrl = lines[i + 1].trimmingCharacters(in: .whitespaces)
            }
        }

        guard let variant = bestUrl else { return url }
        // Resolve relative URLs against the master playlist base
        if let variantURL = URL(string: variant, relativeTo: urlObj) {
            return variantURL.absoluteString
        }
        return variant
    }

    private func summarizeToolError(_ output: String) -> String {
        let usefulLines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("frame=") && !$0.hasPrefix("size=") }
            .prefix(4)
        let summary = usefulLines.joined(separator: " ")
        return summary.isEmpty ? "No ffmpeg error output captured." : String(summary.prefix(500))
    }

    /// Fetch the total duration from a concrete HLS media playlist by summing EXTINF entries.
    private func fetchHlsDuration(from url: String, headers: [String: String]? = nil) async throws -> TimeInterval? {
        guard let urlObj = URL(string: url) else { return nil }
        var request = URLRequest(url: urlObj)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        if let headers = headers { headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) } }
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var total: TimeInterval = 0
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("#EXTINF:"), let value = Double(String(line.dropFirst(8)).split(separator: ",").first ?? "") {
                total += value
            }
        }
        return total > 0 ? total : nil
    }
}
