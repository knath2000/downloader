import Foundation

/// Wraps yt-dlp CLI to extract videos from any supported site (1700+).
struct YtDlpExtractor: VideoSiteExtractor {
    private static let directMediaExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv"]

    static func supports(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        return !NativeVideoPageExtractor.supports(url)
            && !M3U8Extractor.supports(url)
    }

    static func extract(fromHTML: String, url: URL) async throws -> VideoSource {
        guard let ytDlpPath = findYTDLPath() else {
            throw ScraperError.toolNotInstalled(name: "yt-dlp", installCmd: "brew install yt-dlp")
        }

        // Keep redirecting to temp files so large YouTube JSON cannot be truncated by pipe capture.
        let stdoutPath = NSTemporaryDirectory() + "viddl_yt_out_\(UUID().uuidString).json"
        let stderrPath = NSTemporaryDirectory() + "viddl_yt_err_\(UUID().uuidString).txt"
        let escapedUrl = url.absoluteString.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "\(ytDlpPath) --no-playlist --dump-json --no-download --no-warnings '\(escapedUrl)' > \(stdoutPath) 2> \(stderrPath)"
        let startTime = Date()
        let result: SubprocessResult
        do {
            result = try await SubprocessRunner.run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", cmd]
            )
        } catch {
            cleanup(paths: stdoutPath, stderrPath)
            throw error
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let stdoutData = (try? Data(contentsOf: URL(fileURLWithPath: stdoutPath))) ?? Data()
        let stderrData = (try? Data(contentsOf: URL(fileURLWithPath: stderrPath))) ?? Data()
        cleanup(paths: stdoutPath, stderrPath)

        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if !stdoutData.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] {
            return parseVideoSource(from: json, url: url)
        }

        let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? "(empty)"
        throw ScraperError.extractionFailed(
            "yt-dlp exited with code \(result.exitStatus) after \(Int(elapsed))s. Path: \(ytDlpPath)." +
            (stderr.isEmpty ? "" : " stderr: \(stderr)") +
            (stdoutStr.count > 0 ? " stdout (first 200): \(String(stdoutStr.prefix(200)))" : "")
        )
    }

    // MARK: - Parse

    private static func parseVideoSource(from json: [String: Any], url: URL) -> VideoSource {
        // YouTube typically has no direct mp4 URL — bestUrl will be nil.
        // DownloadManager handles this by falling back to `downloadViaYTDLPSite`.
        let rawBestUrl = (json["url"] as? String)?.nilIfEmpty
            ?? (json["best"] as? String)?.nilIfEmpty
        let bestUrl = rawBestUrl.flatMap { isHLSURL($0) ? nil : $0 }
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
                guard let fmtUrl = (fmt["url"] as? String)?.nilIfEmpty else { continue }
                let kind: VideoSource.Kind
                if isHLSFormat(fmt, urlString: fmtUrl) {
                    kind = .hlsManifest
                } else if isDirectMediaFormat(fmt, urlString: fmtUrl) {
                    kind = .direct
                } else {
                    continue
                }

                let fmtId = fmt["format_id"] as? String ?? fmtUrl
                if seenIds.contains(fmtId) { continue }
                seenIds.insert(fmtId)

                let ext = fmt["ext"] as? String ?? ""
                guard hasVideo(fmt) else { continue }

                let height = fmt["height"] as? Int ?? 0
                let label = qualityLabel(height: height, ext: ext, kind: kind)
                let headers = headers(for: fmt, json: json, pageURL: url)
                qualities.append(VideoSource.Quality(label: label, url: fmtUrl, kind: kind, headers: headers, sourcePageUrl: url.absoluteString))
            }
            qualities.sort { a, b in
                let aRes = resolution(from: a.label)
                let bRes = resolution(from: b.label)
                if aRes > 0 && bRes > 0 { return aRes > bRes }
                if aRes > 0 { return true }
                if bRes > 0 { return false }
                let aKind = kindRank(a.kind)
                let bKind = kindRank(b.kind)
                if aKind != bKind { return aKind < bKind }
                return a.label < b.label
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

    private static func isHLSURL(_ urlString: String) -> Bool {
        urlString.localizedCaseInsensitiveContains(".m3u8")
    }

    private static func isHLSFormat(_ fmt: [String: Any], urlString: String) -> Bool {
        let ext = (fmt["ext"] as? String ?? "").lowercased()
        let proto = (fmt["protocol"] as? String ?? "").lowercased()
        return ext == "m3u8" || proto.contains("m3u8") || isHLSURL(urlString)
    }

    private static func isDirectMediaFormat(_ fmt: [String: Any], urlString: String) -> Bool {
        let ext = (fmt["ext"] as? String ?? URL(string: urlString)?.pathExtension ?? "").lowercased()
        let proto = (fmt["protocol"] as? String ?? "").lowercased()
        return directMediaExtensions.contains(ext) && (proto.isEmpty || proto == "http" || proto == "https")
    }

    private static func hasVideo(_ fmt: [String: Any]) -> Bool {
        if let vcodec = (fmt["vcodec"] as? String)?.lowercased(), vcodec != "none" {
            return true
        }
        return (fmt["height"] as? Int ?? 0) > 0
    }

    private static func qualityLabel(height: Int, ext: String, kind: VideoSource.Kind) -> String {
        let base = height > 0 ? "\(height)p" : ext.uppercased()
        switch kind {
        case .direct:
            let suffix = ext.isEmpty ? "Video" : ext.uppercased()
            return "\(base) \(suffix)"
        case .hlsManifest:
            return "\(base) HLS"
        case .pageUrl:
            return base
        }
    }

    private static func headers(for fmt: [String: Any], json: [String: Any], pageURL: URL) -> [String: String] {
        var headers = stringHeaders(json["http_headers"])
        for (key, value) in stringHeaders(fmt["http_headers"]) {
            headers[key] = value
        }
        ensureHeader("Referer", value: pageURL.absoluteString, in: &headers)
        ensureHeader("User-Agent", value: NetworkConstants.chromeUserAgent, in: &headers)
        return headers
    }

    private static func stringHeaders(_ value: Any?) -> [String: String] {
        guard let raw = value as? [String: Any] else { return [:] }
        var headers: [String: String] = [:]
        for (key, value) in raw {
            if let string = value as? String, !string.isEmpty {
                headers[key] = string
            }
        }
        return headers
    }

    private static func ensureHeader(_ name: String, value: String, in headers: inout [String: String]) {
        if !headers.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            headers[name] = value
        }
    }

    private static func resolution(from label: String) -> Int {
        guard let match = try? NSRegularExpression(pattern: #"^(\d+)p"#).firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let range = Range(match.range(at: 1), in: label) else {
            return 0
        }
        return Int(label[range]) ?? 0
    }

    private static func kindRank(_ kind: VideoSource.Kind) -> Int {
        switch kind {
        case .direct: return 0
        case .hlsManifest: return 1
        case .pageUrl: return 2
        }
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
        ToolLocator.find("yt-dlp")?.path
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
