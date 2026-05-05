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

    var errorDescription: String? {
        switch self {
        case .sourceNotFound:
            return "Video source was not found for the selected URL."
        case .providerURLNotResolved(let url):
            return "Provider URL could not be resolved: \(url)"
        }
    }
}

enum DownloadResolver {
    static func resolve(requestedUrl url: String, in results: [ExtractResult]) async throws -> DownloadResolution {
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
                if let resolved = try? await ScraperEngine.extract(from: candidate),
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

    private static func fileName(of url: String) -> String {
        url.split(separator: "/").last.map(String.init) ?? url
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
        return [
            "streamtape.com", "streamtape.net",
            "mixdrop.ag", "mixdrop.co", "mixdrop.sx", "mixdrop.pw", "m1xdrop.click",
            "doodstream.com", "doodstream.org", "dood.wf", "dood.pm", "dood.la", "dood.to",
            "dood.sh", "dood.ws", "dood.one", "dood.watch", "playmogo.com"
        ].contains(host)
    }
}
