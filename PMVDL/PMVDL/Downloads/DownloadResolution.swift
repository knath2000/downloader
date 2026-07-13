import Foundation

enum DownloadMediaKind: String, Codable, Equatable {
    case direct
    case hls
    case ytDlp
    case audio
}

struct DownloadResolution: Codable, Equatable {
    let requestedUrl: String
    let finalUrl: String
    let result: ExtractResult
    let source: VideoSource
    let title: String
    let mediaKind: DownloadMediaKind
    let headers: [String: String]?
    let sourcePageUrl: String?

    var queueQuality: String {
        switch mediaKind {
        case .direct: return source.isAudio ? "Audio" : "Video"
        case .hls: return "HLS"
        case .ytDlp: return "yt-dlp"
        case .audio: return "Audio"
        }
    }

    var isHLS: Bool { mediaKind == .hls }
    var isAudio: Bool { mediaKind == .audio || source.isAudio }
}

enum DownloadResolutionError: LocalizedError {
    case sourceNotFound(String)
    case providerURLNotResolved(String)
    case pornHubSourceRefreshFailed

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            return "Video source was not found for the selected URL."
        case .providerURLNotResolved(let url):
            return "Provider URL could not be resolved: \(url)"
        case .pornHubSourceRefreshFailed:
            return "PornHub source expired; refresh the video and try again."
        }
    }
}

enum DownloadResolver {
    typealias SourceExtractor = (String) async throws -> VideoSource

    static func resolve(
        requestedUrl url: String,
        in results: [ExtractResult],
        extractor: @escaping SourceExtractor = ScraperEngine.extract
    ) async throws -> DownloadResolution {
        guard let result = results.first(where: { candidate in
            candidate.source?.mp4 == url || candidate.source?.hls.contains(where: { $0.url == url }) == true
        }), var source = result.source else {
            throw DownloadResolutionError.sourceNotFound(url)
        }

        let title = source.title ?? pageTitleFallback(from: result.url) ?? fileName(of: url)
        let qualityEntry = source.hls.first(where: { $0.url == url })
        let qualityKind = qualityEntry?.kind
        let isRequestedHLS = url.localizedCaseInsensitiveContains(".m3u8")
        let isYtDlpSite = source.mp4 == nil && !isRequestedHLS && qualityKind != .direct

        var resolvedUrl: String?
        var resolvedQuality: VideoSource.Quality?
        if qualityEntry?.kind == .pageUrl && isYtDlpSite {
            for candidate in uniqueCandidates([qualityEntry?.sourcePageUrl, url]) {
                if let resolved = try? await extractor(candidate),
                   resolved.mp4 != nil || !resolved.hls.isEmpty {
                    source = resolved
                    if let mp4 = resolved.mp4 {
                        resolvedUrl = mp4
                    } else if let quality = resolved.hls.first(where: { $0.kind != .pageUrl }) {
                        resolvedQuality = quality
                        resolvedUrl = quality.url
                    }
                    break
                }
            }
        }

        if qualityEntry?.kind == .pageUrl, isProviderHost(qualityEntry?.sourcePageUrl ?? url), resolvedUrl == nil {
            throw DownloadResolutionError.providerURLNotResolved(url)
        }

        let finalUrl = resolvedUrl ?? url
        let stillYtDlp = resolvedUrl == nil && isYtDlpSite
        let finalQuality = resolvedQuality ?? source.hls.first(where: { $0.url == finalUrl }) ?? qualityEntry
        let finalIsHLS = finalQuality?.kind == .hlsManifest || finalUrl.localizedCaseInsensitiveContains(".m3u8")
        let mediaKind: DownloadMediaKind
        if source.isAudio {
            mediaKind = .audio
        } else if stillYtDlp {
            mediaKind = .ytDlp
        } else if finalIsHLS {
            mediaKind = .hls
        } else {
            mediaKind = .direct
        }

        return DownloadResolution(
            requestedUrl: url,
            finalUrl: finalUrl,
            result: result,
            source: source,
            title: title,
            mediaKind: mediaKind,
            headers: finalQuality?.headers ?? source.headers(forQualityURL: finalUrl) ?? source.headers(forQualityURL: url),
            sourcePageUrl: finalQuality?.sourcePageUrl
        )
    }

    static func resolve(
        sourcePageURL: String,
        preferredQualityLabel: String?,
        extractor: @escaping SourceExtractor = ScraperEngine.extract
    ) async throws -> DownloadResolution {
        let source = try await extractor(sourcePageURL)
        let result = ExtractResult(url: sourcePageURL, source: source, error: nil)
        let candidates = source.hls.filter { $0.kind != .pageUrl }
        let selectedURL = candidates.first(where: {
            $0.label.caseInsensitiveCompare(preferredQualityLabel ?? "") == .orderedSame
        })?.url ?? source.mp4 ?? candidates.first?.url ?? source.hls.first?.url
        guard let selectedURL else {
            throw DownloadResolutionError.sourceNotFound(sourcePageURL)
        }
        return try await resolve(requestedUrl: selectedURL, in: [result], extractor: extractor)
    }

    static func refreshForDownloadIfNeeded(
        _ resolution: DownloadResolution,
        extractor: @escaping SourceExtractor = ScraperEngine.extract
    ) async throws -> DownloadResolution {
        guard needsDownloadTimeRefresh(resolution),
              let pageURL = pornHubRefreshPageURL(for: resolution) else {
            return resolution
        }

        let refreshedSource: VideoSource
        do {
            refreshedSource = try await extractor(pageURL)
        } catch {
            throw DownloadResolutionError.pornHubSourceRefreshFailed
        }

        guard refreshedSource.mp4 != nil || !refreshedSource.hls.isEmpty else {
            throw DownloadResolutionError.pornHubSourceRefreshFailed
        }

        return refreshedResolution(
            from: resolution,
            refreshedSource: refreshedSource,
            pageURL: pageURL
        )
    }

    static func refreshForRetry(
        _ resolution: DownloadResolution,
        extractor: @escaping SourceExtractor = ScraperEngine.extract
    ) async throws -> DownloadResolution {
        guard let pageURL = sourcePageURL(for: resolution) else {
            return resolution
        }

        let refreshedSource = try await extractor(pageURL)
        guard refreshedSource.mp4 != nil || !refreshedSource.hls.isEmpty else {
            throw DownloadResolutionError.sourceNotFound(pageURL)
        }

        return refreshedResolution(
            from: resolution,
            refreshedSource: refreshedSource,
            pageURL: pageURL
        )
    }

    static func needsDownloadTimeRefresh(_ resolution: DownloadResolution) -> Bool {
        let values = [
            resolution.requestedUrl,
            resolution.finalUrl,
            resolution.result.url,
            resolution.sourcePageUrl,
            resolution.source.siteName
        ] + resolution.source.hls.compactMap(\.sourcePageUrl)

        return values.contains { value in
            let lower = value?.lowercased() ?? ""
            if lower.contains("pornhub") { return true }
            guard let host = URL(string: lower)?.host else { return false }
            return host == "pornhub.com" || host.hasSuffix(".pornhub.com")
        }
    }

    private static func fileName(of url: String) -> String {
        url.split(separator: "/").last.map(String.init) ?? url
    }

    private static func refreshedResolution(
        from resolution: DownloadResolution,
        refreshedSource: VideoSource,
        pageURL: String
    ) -> DownloadResolution {
        let originalQuality = resolution.source.hls.first { $0.url == resolution.requestedUrl }
            ?? resolution.source.hls.first { $0.url == resolution.finalUrl }
        let selectedQuality = refreshedQuality(
            matching: originalQuality,
            originalMediaKind: resolution.mediaKind,
            in: refreshedSource
        )
        let finalUrl = selectedQuality?.url
            ?? refreshedSource.mp4
            ?? refreshedSource.hls.first(where: { $0.kind == .direct })?.url
            ?? refreshedSource.hls.first?.url
            ?? resolution.finalUrl
        let finalQuality = selectedQuality ?? refreshedSource.hls.first { $0.url == finalUrl }
        let finalIsHLS = finalQuality?.kind == .hlsManifest || finalUrl.localizedCaseInsensitiveContains(".m3u8")
        let mediaKind: DownloadMediaKind
        if refreshedSource.isAudio {
            mediaKind = .audio
        } else if finalIsHLS {
            mediaKind = .hls
        } else {
            mediaKind = .direct
        }
        let refreshedResult = ExtractResult(url: resolution.result.url, source: refreshedSource, error: nil)

        return DownloadResolution(
            requestedUrl: resolution.requestedUrl,
            finalUrl: finalUrl,
            result: refreshedResult,
            source: refreshedSource,
            title: refreshedSource.title ?? resolution.title,
            mediaKind: mediaKind,
            headers: finalQuality?.headers
                ?? refreshedSource.headers(forQualityURL: finalUrl)
                ?? resolution.headers,
            sourcePageUrl: finalQuality?.sourcePageUrl ?? pageURL
        )
    }

    private static func refreshedQuality(
        matching originalQuality: VideoSource.Quality?,
        originalMediaKind: DownloadMediaKind,
        in source: VideoSource
    ) -> VideoSource.Quality? {
        guard let originalQuality else {
            if originalMediaKind == .hls {
                return source.hls.first { $0.kind == .hlsManifest } ?? source.hls.first
            }
            return source.hls.first { $0.kind == .direct && $0.url == source.mp4 }
                ?? source.hls.first { $0.kind == .direct }
        }

        if let exact = source.hls.first(where: {
            $0.kind == originalQuality.kind &&
                $0.label.caseInsensitiveCompare(originalQuality.label) == .orderedSame
        }) {
            return exact
        }

        let originalHeight = qualityHeight(from: originalQuality.label)
        if originalHeight > 0,
           let sameHeight = source.hls.first(where: {
               $0.kind == originalQuality.kind && qualityHeight(from: $0.label) == originalHeight
           }) {
            return sameHeight
        }

        switch originalQuality.kind {
        case .direct:
            return source.hls.first { $0.kind == .direct }
        case .hlsManifest:
            return source.hls.first { $0.kind == .hlsManifest }
        case .pageUrl:
            return source.hls.first { $0.kind != .pageUrl }
        }
    }

    private static func pornHubRefreshPageURL(for resolution: DownloadResolution) -> String? {
        let originalQuality = resolution.source.hls.first { $0.url == resolution.requestedUrl }
            ?? resolution.source.hls.first { $0.url == resolution.finalUrl }
        return uniqueCandidates([
            resolution.sourcePageUrl,
            originalQuality?.sourcePageUrl,
            resolution.result.url,
            resolution.requestedUrl,
            resolution.finalUrl
        ]).first(where: isPornHubPageURL)
    }

    private static func sourcePageURL(for resolution: DownloadResolution) -> String? {
        uniqueCandidates([
            resolution.result.url,
            resolution.sourcePageUrl
        ] + resolution.source.hls.compactMap(\.sourcePageUrl)).first { value in
            guard let url = URL(string: value) else { return false }
            return !isMediaURL(url)
        }
    }

    private static func isPornHubPageURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let host = url.host?.lowercased(),
              host == "pornhub.com" || host.hasSuffix(".pornhub.com"),
              !isMediaURL(url) else {
            return false
        }
        return true
    }

    /// Derives a human-readable title from the page URL when the extractor didn't supply one.
    /// Returns nil if the URL itself is a media file (e.g. the bare HLS URL was passed as the page URL).
    private static func pageTitleFallback(from urlString: String) -> String? {
        guard let url = URL(string: urlString), !isMediaURL(url) else { return nil }
        let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard let last = components.last else { return nil }

        var slug = last
        // Strip trailing hex ID segment common on PMVHaven: _<24 lowercase hex chars>
        if let range = slug.range(of: "_[0-9a-f]{24}$", options: .regularExpression) {
            slug = String(slug[slug.startIndex..<range.lowerBound])
        }
        slug = slug.replacingOccurrences(of: "_", with: " ")
                   .replacingOccurrences(of: "-", with: " ")
                   .trimmingCharacters(in: .whitespacesAndNewlines)
        return slug.isEmpty ? nil : slug.capitalized
    }

    private static func isMediaURL(_ url: URL) -> Bool {
        let mediaExtensions: Set<String> = ["mp4", "m3u8", "mov", "m4v", "mkv", "webm", "avi", "ts"]
        return mediaExtensions.contains(url.pathExtension.lowercased())
    }

    private static func uniqueCandidates(_ candidates: [String?]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates.compactMap({ $0 }) where seen.insert(candidate).inserted {
            result.append(candidate)
        }
        return result
    }

    private static func isProviderHost(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        let hosts = [
            "streamtape.com", "streamtape.net",
            "mixdrop.ag", "mixdrop.co", "mixdrop.sx", "mixdrop.pw", "m1xdrop.click",
            "doodstream.com", "doodstream.org", "dood.wf", "dood.pm", "dood.la", "dood.to",
            "dood.sh", "dood.ws", "dood.one", "dood.watch", "playmogo.com", "vidara.so"
        ]
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func qualityHeight(from label: String) -> Int {
        guard let match = try? NSRegularExpression(
            pattern: #"(\d+)p"#,
            options: [.caseInsensitive]
        ).firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
              let range = Range(match.range(at: 1), in: label) else {
            return 0
        }
        return Int(label[range]) ?? 0
    }
}
