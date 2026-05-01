import Foundation

/// Wraps yt-dlp CLI to extract videos from any supported site (1700+).
struct YtDlpExtractor: VideoSiteExtractor {
    static func supports(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        return !NativeVideoPageExtractor.supports(url)
            && !M3U8Extractor.supports(url)
    }

    static func extract(fromHTML: String, url: URL) async throws -> VideoSource {
        guard let ytDlpPath = findYTDLPath() else {
            throw ScraperError.toolNotInstalled(name: "yt-dlp", installCmd: "brew install yt-dlp")
        }

        // Use shell redirection to temp files instead of pipes.
        // `readDataToEndOfFile()` and `readabilityHandler` both have buffering issues
        // that truncate large JSON payloads from YouTube — writing to files avoids this.
        // No timeout: let yt-dlp finish naturally; exit code 15 is handled gracefully.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let stdoutPath = NSTemporaryDirectory() + "viddl_yt_out_\(UUID().uuidString).json"
                let stderrPath = NSTemporaryDirectory() + "viddl_yt_err_\(UUID().uuidString).txt"

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                // --no-playlist prevents stalls on playlist-like YouTube pages
                let escapedUrl = url.absoluteString.replacingOccurrences(of: "'", with: "'\\''")
                let cmd = "\(ytDlpPath) --no-playlist --dump-json --no-download --no-warnings '\(escapedUrl)' > \(stdoutPath) 2> \(stderrPath)"
                process.arguments = ["-c", cmd]

                let startTime = Date()

                do {
                    try process.run()
                } catch {
                    cleanup(paths: stdoutPath, stderrPath)
                    continuation.resume(throwing: error)
                    return
                }

                // No timeout — metadata extraction can take several minutes for large channel pages
                process.waitUntilExit()
                let elapsed = Date().timeIntervalSince(startTime)

                // Read complete output from files (guaranteed not truncated)
                let stdoutData = (try? Data(contentsOf: URL(fileURLWithPath: stdoutPath))) ?? Data()
                let stderrData = (try? Data(contentsOf: URL(fileURLWithPath: stderrPath))) ?? Data()
                cleanup(paths: stdoutPath, stderrPath)

                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                let exitCode = process.terminationStatus

                // Always attempt JSON parse regardless of exit code.
                // yt-dlp often writes valid JSON to stdout before exiting with a non-zero code
                // (e.g. code 15 from SIGTERM, or various warnings treated as errors).
                if !stdoutData.isEmpty,
                   let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] {
                    continuation.resume(returning: parseVideoSource(from: json, url: url))
                    return
                }

                // Genuine failure — report elapsed time and path for diagnosis
                let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? "(empty)"
                continuation.resume(throwing: ScraperError.extractionFailed(
                    "yt-dlp exited with code \(exitCode) after \(Int(elapsed))s. Path: \(ytDlpPath)." +
                    (stderr.isEmpty ? "" : " stderr: \(stderr)") +
                    (stdoutStr.count > 0 ? " stdout (first 200): \(String(stdoutStr.prefix(200)))" : "")
                ))
            }
        }
    }

    // MARK: - Parse

    private static func parseVideoSource(from json: [String: Any], url: URL) -> VideoSource {
        // YouTube typically has no direct mp4 URL — bestUrl will be nil.
        // DownloadManager handles this by falling back to `downloadViaYTDLPSite`.
        let bestUrl = (json["url"] as? String)?.nilIfEmpty
            ?? (json["best"] as? String)?.nilIfEmpty
        let title = json["title"] as? String ?? "Unknown"
        let thumbnail = json["thumbnail"] as? String
        let duration = json["duration"] as? TimeInterval
        let uploader = (json["uploader"] as? String)?.nilIfEmpty
        let siteName = (json["extractor"] as? String)?.nilIfEmpty
            ?? (json["extractor_key"] as? String)?.nilIfEmpty
        let isAudio = isAudioOnly(json: json)

        var qualities: [VideoSource.Quality] = []
        if let formats = json["formats"] as? [[String: Any]] {
            var seenIds = Set<String>()
            for fmt in formats {
                let fmtUrl = fmt["url"] as? String
                let fmtId = fmt["format_id"] as? String ?? fmtUrl ?? ""
                if seenIds.contains(fmtId) { continue }
                seenIds.insert(fmtId)

                let vcodec = fmt["vcodec"] as? String ?? "none"
                let ext = fmt["ext"] as? String ?? ""
                if vcodec == "none" && ext != "m3u8" && ext != "mpd" { continue }

                let height = fmt["height"] as? Int ?? 0
                let label: String
                if height > 0 {
                    label = "\(height)p"
                } else {
                    label = ext.uppercased()
                }
                qualities.append(VideoSource.Quality(label: label, url: fmtUrl ?? url.absoluteString))
            }
            let resOrder: [String: Int] = ["HLS": 0, "DASH": 1, "WEBM": 2, "M4A": 3, "WEBA": 4, "MP3": 5]
            qualities.sort { a, b in
                let aRes = Int(a.label.dropLast()) ?? 0
                let bRes = Int(b.label.dropLast()) ?? 0
                if aRes > 0 && bRes > 0 { return aRes > bRes }
                if aRes > 0 { return true }
                if bRes > 0 { return false }
                return (resOrder[a.label] ?? 99) < (resOrder[b.label] ?? 99)
            }
        }

        return VideoSource(
            mp4: bestUrl,
            hls: qualities,
            title: title,
            thumbnail: thumbnail,
            duration: duration,
            uploader: uploader,
            siteName: siteName,
            isAudio: isAudio
        )
    }

    private static func isAudioOnly(json: [String: Any]) -> Bool {
        if let vcodec = json["vcodec"] as? String, vcodec == "none" { return true }
        if let formatNote = json["format_note"] as? String, formatNote == "audio only" { return true }
        return false
    }

    private static func cleanup(paths: String...) {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
    }

    private static func findYTDLPath() -> String? {
        for path in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", "/usr/bin/yt-dlp"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
