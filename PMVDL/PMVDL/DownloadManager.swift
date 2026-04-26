import Foundation
import AppKit
import CommonCrypto

/// Unified local download pipeline: direct URLs, HLS streams, yt-dlp sites (YouTube), audio-only, subtitles.
@MainActor
class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    let downloadDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads/VidDL")

    private init() {
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
    }

    // MARK: - Subtitle Settings

    var subtitlesEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "downloadSubtitles") }
        set { UserDefaults.standard.set(newValue, forKey: "downloadSubtitles") }
    }

    var embeddedSubsMode: Bool {
        get { UserDefaults.standard.bool(forKey: "embeddedSubsMode") }
        set { UserDefaults.standard.set(newValue, forKey: "embeddedSubsMode") }
    }

    // MARK: - yt-dlp site download (for YouTube etc.)

    /// Download via yt-dlp directly. Works for ANY yt-dlp supported site.
    /// Used when no direct URL is available (e.g. YouTube).
    func downloadViaYTDLPSite(pageUrl: String, title: String? = nil,
                              preferredFormat: String = "mp4",
                              onProgress: @escaping (String) -> Void) async throws -> URL {
        guard let ytDlp = findYTDLPath() else {
            throw DownloadError.toolNotFound("yt-dlp")
        }

        let baseName = sanitizeFilename(title ?? URL(string: pageUrl)?.host ?? "video")
        let uniqueTag = UUID().uuidString.prefix(8).lowercased()
        let outPattern = downloadDir.appendingPathComponent("\(baseName)_\(uniqueTag).%(ext)s").path

        var args = ["--no-playlist", "--merge-output-format", preferredFormat, "-o", outPattern]

        if subtitlesEnabled {
            if embeddedSubsMode {
                args.append("--embed-subs")
            } else {
                args.append(contentsOf: ["--write-subs", "--sub-lang", "en,ja,zh,ko,es,fr"])
            }
        }

        args.append(pageUrl)

        let ext = Pipe()
        let errPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlp)
        process.arguments = args
        process.standardOutput = ext
        process.standardError = errPipe

        parseYTDLPSProgress(from: errPipe, onProgress: onProgress)

        try process.run()
        onProgress("Downloading via yt-dlp…")
        let start = Date()
        while process.isRunning {
            if Date().timeIntervalSince(start) > 7200 {
                process.terminate()
                throw DownloadError.timedOut
            }
            try await Task.sleep(for: .seconds(1))
        }

        // Find the downloaded file
        if let file = findDownloadedFile(in: downloadDir, prefix: "\(baseName)_\(uniqueTag)") {
            return downloadDir.appendingPathComponent(file)
        }

        throw DownloadError.downloadFailed("yt-dlp completed but output file not found")
    }

    // MARK: - Direct download (URLSession)

    /// Download a direct video URL to the local Downloads/VidDL folder.
    func downloadDirect(url: String, title: String? = nil,
                        onProgress: @escaping (String) -> Void) async throws -> URL {
        let filename = sanitizeFilename(title ?? URL(string: url)?.pathComponents.last ?? "video")
        let ext = URL(string: url)?.pathExtension ?? "mp4"
        let destFile = downloadDir.appendingPathComponent("\(filename).\(ext)")

        let delegate = DownloadProgressDelegate(onProgress: onProgress, destURL: destFile)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 120
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        try await delegate.performDownload(session: session, request: request)

        return destFile
    }

    /// Download a direct video URL with a progress delegate that reports numeric percent.
    func downloadDirectWithDelegate(url: String, title: String? = nil,
                                     delegate: QueueDownloadProgressDelegate) async throws -> URL {
        let filename = sanitizeFilename(title ?? URL(string: url)?.pathComponents.last ?? "video")
        let ext = URL(string: url)?.pathExtension ?? "mp4"
        let destFile = downloadDir.appendingPathComponent("\(filename).\(ext)")
        delegate.destURL = destFile
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 120
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        try await delegate.performDownload(session: session, request: request)

        return destFile
    }

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

        let filename = sanitizeFilename(title ?? "hls_video")
        let destFile = downloadDir.appendingPathComponent("\(filename).mp4")
        try? FileManager.default.removeItem(at: destFile)

        // Build ffmpeg arguments with optional headers
        var args = ["-y"]
        if let headers = headers, !headers.isEmpty {
            let headerStr = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
            args.append(contentsOf: ["-headers", headerStr])
        }
        args.append(contentsOf: ["-i", resolvedUrl, "-c", "copy", "-movflags", "+faststart", destFile.path])

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = args
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe

        onProgress(.downloading(msg: "Downloading HLS… starting…", pct: 0))
        parseProgress(from: errPipe, totalDuration: totalDuration, onProgress: onProgress)

        try process.run()
        let start = Date()
        while process.isRunning {
            if Date().timeIntervalSince(start) > 7200 {
                process.terminate()
                throw DownloadError.timedOut
            }
            try await Task.sleep(for: .seconds(1))
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destFile.path) else {
            throw DownloadError.downloadFailed("ffmpeg exit \(process.terminationStatus)")
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
                destFile: downloadDir.appendingPathComponent(sanitizeFilename(title ?? "lulustream_video") + ".mp4"),
                headers: headers,
                onProgress: onProgress
            )
        } else {
            // Unencrypted: use the existing fast concat path
            return try await downloadAndConcatHLS(
                playlistText: playlistTextUnwrapped,
                baseURL: baseURL,
                destFile: downloadDir.appendingPathComponent(sanitizeFilename(title ?? "lulustream_video") + ".mp4"),
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
            .appendingPathComponent("pmvdl_enc_\(UUID().uuidString.prefix(8))")
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
            let ivData = try hlsIVData(from: segInfo.ivHex, sequence: segInfo.sequence)
            let decData = try aes128CBCDecrypt(data: encData, key: keyData, iv: ivData)
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
            .appendingPathComponent("pmvdl_plain_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Download segments
        var downloadedPaths: [URL] = []
        for (i, segInfo) in segInfos.enumerated() {
            var req = URLRequest(url: segInfo.url)
            req.timeoutInterval = 60
            if let headers = headers {
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            } else {
                req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
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

    private func hlsIVData(from ivHex: String?, sequence: Int) throws -> Data {
        if let ivHex, !ivHex.isEmpty {
            let stripped = ivHex.hasPrefix("0x") ? String(ivHex.dropFirst(2)) : ivHex
            guard stripped.count <= 32, stripped.count % 2 == 0 else {
                throw DownloadError.downloadFailed("Invalid HLS IV: \(ivHex)")
            }
            var bytes = Data()
            bytes.reserveCapacity(16)
            var index = stripped.startIndex
            while index < stripped.endIndex {
                let next = stripped.index(index, offsetBy: 2)
                guard let byte = UInt8(stripped[index..<next], radix: 16) else {
                    throw DownloadError.downloadFailed("Invalid HLS IV: \(ivHex)")
                }
                bytes.append(byte)
                index = next
            }
            if bytes.count < 16 {
                bytes.insert(contentsOf: Array(repeating: 0, count: 16 - bytes.count), at: 0)
            }
            return bytes
        }

        var seq = UInt64(sequence)
        var iv = Data(count: 16)
        for i in 0..<8 {
            iv[15 - i] = UInt8(seq & 0xff)
            seq >>= 8
        }
        return iv
    }

    private func aes128CBCDecrypt(data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw DownloadError.downloadFailed("Invalid AES-128 key/IV size")
        }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var outLength: size_t = 0
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBytes.baseAddress,
                            kCCKeySizeAES128,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress,
                            data.count,
                            outBytes.baseAddress,
                            outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw DownloadError.downloadFailed("AES-128 decrypt failed")
        }
        out.removeSubrange(outLength..<out.count)
        return out
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
            .appendingPathComponent("pmvdl_concat_\(UUID().uuidString.prefix(8)).txt")
        try concatContent.write(to: concatFile, atomically: true, encoding: .utf8)

        onProgress(.downloading(msg: "Concatenating…", pct: 95))

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-y", "-f", "concat", "-safe", "0",
            "-i", concatFile.path,
            "-c", "copy", "-movflags", "+faststart",
            destFile.path
        ]
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        while process.isRunning {
            try await Task.sleep(for: .seconds(0.2))
        }

        // Collect stderr for diagnostics
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errOutput = String(data: errData, encoding: .utf8) ?? ""

        // Clean up temp files
        try? FileManager.default.removeItem(at: concatFile)
        for seg in segPaths {
            try? FileManager.default.removeItem(at: seg)
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destFile.path) else {
            throw DownloadError.downloadFailed(
                "Unencrypted HLS concat/mux failed (exit \(process.terminationStatus)). " +
                "ffmpeg stderr: \(errOutput.prefix(500))"
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
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
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
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
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

    /// Parse ffmpeg stderr for progress. Reads capture groups (not the full match) to
    /// avoid trailing whitespace, and uses out_time_ms fallback when duration is unknown.
    private func parseProgress(from pipe: Pipe, totalDuration: TimeInterval?, onProgress: @escaping (ProgressEvent) -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else {
                handle.readabilityHandler = nil; return
            }
            if let match = try? NSRegularExpression(
                pattern: "time=(\\d+):(\\d+):(\\d+\\.\\d+)"
            ).firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) {
                // Read capture groups directly — avoids trailing whitespace that breaks Double()
                guard let range1 = Range(match.range(at: 1), in: str),
                      let range2 = Range(match.range(at: 2), in: str),
                      let range3 = Range(match.range(at: 3), in: str),
                      let h = Double(str[range1]),
                      let m = Double(str[range2]),
                      let ms = Double(str[range3]) else { return }

                let elapsed = h * 3600 + m * 60 + ms

                let pct: Double
                if let dur = totalDuration, dur > 0 {
                    pct = min(99.0, elapsed / dur * 100)
                } else {
                    // No duration known — use elapsed time with a reasonable cap
                    // so progress still moves instead of staying at 0.
                    let estimatedTotalMs: Int64 = 30 * 60 * 1000 // 30 min estimate
                    let elapsedMs = Int64(elapsed * 1000)
                    pct = min(99.0, Double(elapsedMs) / Double(estimatedTotalMs) * 100)
                }

                let timeStr = String(format: "%02d:%02d:%05.2f", Int(h), Int(m), ms)
                onProgress(.downloading(msg: "Downloading HLS… \(timeStr) \(pct == 0 ? "0" : String(format: "%.1f", pct))%", pct: pct))
            }
        }
    }

    /// Fetch the total duration from a concrete HLS media playlist by summing EXTINF entries.
    private func fetchHlsDuration(from url: String, headers: [String: String]? = nil) async throws -> TimeInterval? {
        guard let urlObj = URL(string: url) else { return nil }
        var request = URLRequest(url: urlObj)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
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

    // MARK: - Audio-only via yt-dlp

    /// Download audio-only using yt-dlp --extract-audio.
    func downloadAudio(pageUrl: String, title: String? = nil,
                       format: String = "mp3",
                       onProgress: @escaping (String) -> Void) async throws -> URL {
        guard let ytDlp = findYTDLPath() else {
            throw DownloadError.toolNotFound("yt-dlp")
        }
        let baseName = sanitizeFilename(title ?? "audio")
        let uniqueTag = UUID().uuidString.prefix(8).lowercased()
        let outPattern = downloadDir.appendingPathComponent("\(baseName)_\(uniqueTag).%(ext)s").path

        let ext = Pipe()
        let errPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlp)
        process.arguments = [
            "--extract-audio", "--audio-format", format,
            "--audio-quality", "0", "--no-playlist",
            "-o", outPattern, "--progress", pageUrl
        ]
        process.standardOutput = ext
        process.standardError = errPipe

        try process.run()
        onProgress("Downloading audio…")
        let start = Date()
        while process.isRunning {
            if Date().timeIntervalSince(start) > 7200 {
                process.terminate()
                throw DownloadError.timedOut
            }
            try await Task.sleep(for: .seconds(1))
        }

        if let file = findDownloadedFile(in: downloadDir, prefix: "\(baseName)_\(uniqueTag)") {
            return downloadDir.appendingPathComponent(file)
        }

        throw DownloadError.downloadFailed("yt-dlp completed but output file not found")
    }

    // MARK: - Download with subtitles via yt-dlp

    /// Download video with subtitles using yt-dlp.
    func downloadWithSubtitles(pageUrl: String, title: String? = nil,
                               onProgress: @escaping (String) -> Void) async throws -> URL {
        guard let ytDlp = findYTDLPath() else {
            throw DownloadError.toolNotFound("yt-dlp")
        }
        let baseName = sanitizeFilename(title ?? "video")
        let uniqueTag = UUID().uuidString.prefix(8).lowercased()
        let outPattern = downloadDir.appendingPathComponent("\(baseName)_\(uniqueTag).%(ext)s").path

        var args = ["--no-playlist", "--merge-output-format", "mp4", "-o", outPattern]
        if subtitlesEnabled {
            if embeddedSubsMode {
                args.append("--embed-subs")
            } else {
                args.append(contentsOf: ["--write-subs", "--sub-lang", "en,ja,zh,ko,es,fr"])
            }
        }
        args.append(pageUrl)

        let ext = Pipe()
        let errPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlp)
        process.arguments = args
        process.standardOutput = ext
        process.standardError = errPipe

        try process.run()
        onProgress("Downloading with subtitles…")
        let start = Date()
        while process.isRunning {
            if Date().timeIntervalSince(start) > 7200 {
                process.terminate()
                throw DownloadError.timedOut
            }
            try await Task.sleep(for: .seconds(1))
        }

        if let file = findDownloadedFile(in: downloadDir, prefix: "\(baseName)_\(uniqueTag)") {
            return downloadDir.appendingPathComponent(file)
        }

        throw DownloadError.downloadFailed("yt-dlp completed but output file not found")
    }

    // MARK: - yt-dlp progress parsing

    private func parseYTDLPSProgress(from pipe: Pipe, onProgress: @escaping (String) -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else {
                handle.readabilityHandler = nil; return
            }
            if let match = try? NSRegularExpression(
                pattern: "\\[download\\]\\s+([\\d.]+)%.*at\\s+([\\d.]+\\w+/s)"
            ).firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) {
                let range = Range(match.range, in: str)!
                onProgress("Downloading… \(str[range])")
            } else if let match2 = try? NSRegularExpression(
                pattern: "\\[download\\]\\s+100%\\s+of\\s+([\\d.]+\\w+)"
            ).firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) {
                let range2 = Range(match2.range, in: str)!
                onProgress("Downloading… \(str[range2])")
            }
        }
    }

    // MARK: - Helpers

    private func findDownloadedFile(in dir: URL, prefix: String) -> String? {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .first { $0.hasPrefix(prefix) }
    }

    private func sanitizeFilename(_ title: String) -> String {
        let set = CharacterSet.alphanumerics.union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_.'()"))
        var cleaned = title.components(separatedBy: set.inverted).joined()
        if cleaned.isEmpty {
            cleaned = "video_\(UUID().uuidString.prefix(8).lowercased())"
        }
        return String(cleaned.prefix(50).trimmingCharacters(in: .whitespaces))
    }

    private func findYTDLPath() -> String? {
        for p in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// Reveal downloaded file in Finder.
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Errors

enum DownloadError: LocalizedError {
    case toolNotFound(String)
    case downloadFailed(String)
    case timedOut
    case directoryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "\(name) not found. Run: brew install \(name)"
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .timedOut:
            return "Download timed out (2 hours)"
        case .directoryNotFound(let dir):
            return "Directory not found: \(dir)"
        }
    }
}

// MARK: - Direct download with queue progress

final class QueueDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    let queueId: UUID
    let onProgress: (Double) -> Void
    var destURL: URL

    init(queueId: UUID, onProgress: @escaping (Double) -> Void) {
        self.queueId = queueId; self.onProgress = onProgress
        self.destURL = URL(fileURLWithPath: "/tmp/pmvdldummy")
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
        let pct = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100.0
        onProgress(pct)
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
