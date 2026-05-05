import AppKit
import Foundation

struct HTMLThumbnailMetadataExtractor {
    static func extractThumbnailURL(from html: String, pageURL: URL) -> String? {
        let candidates: [String?] = [
            metaContent(for: "og:image", in: html),
            metaContent(for: "og:image:url", in: html),
            metaContent(for: "twitter:image", in: html),
            metaContent(for: "twitter:image:src", in: html),
            linkHref(rel: "image_src", in: html),
            videoPoster(in: html),
            jwPlayerImage(in: html),
            jsonLDThumbnailURL(in: html)
        ]

        for candidate in candidates.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard !candidate.isEmpty else { continue }
            if let absolute = absoluteURLString(candidate, relativeTo: pageURL) {
                return absolute
            }
        }
        return nil
    }

    private static func metaContent(for key: String, in html: String) -> String? {
        for tag in tags(named: "meta", in: html) {
            let tagKey = attribute(name: "property", in: tag) ?? attribute(name: "name", in: tag)
            guard tagKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key.lowercased() else { continue }
            if let content = attribute(name: "content", in: tag) {
                return content
            }
        }
        return nil
    }

    private static func linkHref(rel: String, in html: String) -> String? {
        for tag in tags(named: "link", in: html) {
            guard let relValue = attribute(name: "rel", in: tag) else { continue }
            let tokens = relValue.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.contains(rel.lowercased()) else { continue }
            if let href = attribute(name: "href", in: tag) {
                return href
            }
        }
        return nil
    }

    private static func videoPoster(in html: String) -> String? {
        for tag in tags(named: "video", in: html) {
            if let poster = attribute(name: "poster", in: tag) {
                return poster
            }
        }
        return nil
    }

    private static func jwPlayerImage(in html: String) -> String? {
        let patterns = [
            #"image\s*:\s*["']([^"']+)["']"#,
            #"poster\s*:\s*["']([^"']+)["']"#,
            #"thumbnail\s*:\s*["']([^"']+)["']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            return String(html[range])
        }
        return nil
    }

    private static func jsonLDThumbnailURL(in html: String) -> String? {
        let pattern = #""thumbnailUrl"\s*:\s*(?:\[\s*)?"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    private static func tags(named name: String, in html: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "<\(escaped)\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            guard let range = Range($0.range, in: html) else { return nil }
            return String(html[range])
        }
    }

    private static func attribute(name: String, in tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\(escaped)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }

        for index in 1...3 {
            let matchRange = match.range(at: index)
            guard matchRange.location != NSNotFound,
                  let range = Range(matchRange, in: tag) else { continue }
            return String(tag[range])
        }
        return nil
    }

    private static func absoluteURLString(_ candidate: String, relativeTo pageURL: URL) -> String? {
        let decoded = candidate
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if decoded.hasPrefix("//"), let scheme = pageURL.scheme {
            return "\(scheme):\(decoded)"
        }
        if let absolute = URL(string: decoded), absolute.scheme != nil {
            return absolute.absoluteString
        }
        return URL(string: decoded, relativeTo: pageURL)?.absoluteURL.absoluteString
    }
}

struct LibraryThumbnailResolution: Equatable {
    enum Source: String, Equatable {
        case storedThumbnailURL
        case pageMetadata
        case scraperMetadata
        case mediaFrame
    }

    let thumbnailURL: String?
    let image: NSImage?
    let source: Source

    static func == (lhs: LibraryThumbnailResolution, rhs: LibraryThumbnailResolution) -> Bool {
        lhs.thumbnailURL == rhs.thumbnailURL && lhs.source == rhs.source
    }
}

struct LibraryThumbnailResolver {
    typealias HTMLFetcher = (URL) async throws -> String
    typealias SourceExtractor = (String) async throws -> VideoSource
    typealias ImageDownloader = (String, String?, String?) async throws -> NSImage
    typealias FrameGenerator = (String) async throws -> NSImage

    var fetchHTML: HTMLFetcher
    var extractSource: SourceExtractor
    var downloadImage: ImageDownloader
    var generateFrame: FrameGenerator

    static let live = LibraryThumbnailResolver(
        fetchHTML: Self.liveFetchHTML,
        extractSource: { try await ScraperEngine.extract(from: $0) },
        downloadImage: { imageURL, identity, referer in
            try await ThumbnailCache.downloadAndCacheImage(
                fromImageURL: imageURL,
                cacheIdentity: identity,
                referer: referer
            )
        },
        generateFrame: { mediaURL in
            try await ThumbnailCache.generateAndCache(fromRemoteURL: mediaURL)
        }
    )

    static func liveFetchHTML(pageURL: URL) async throws -> String {
        var request = URLRequest(url: pageURL)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer = originReferer(for: pageURL) {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw ThumbnailError.httpStatus(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw VideoExtractorError.network(
                NSError(
                    domain: "VidDL",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to decode thumbnail page HTML"]
                )
            )
        }
        return html
    }

    static func isLikelyPageURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "http" || scheme == "https" else { return false }

        let ext = url.pathExtension.lowercased()
        let mediaExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "m3u8", "ts", "mp3", "m4a"]
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "avif"]
        return !mediaExtensions.contains(ext) && !imageExtensions.contains(ext)
    }

    static func mediaFallbackURL(for item: LibraryItem) -> String? {
        if let mp4 = item.mp4Url?.trimmingCharacters(in: .whitespacesAndNewlines), !mp4.isEmpty {
            return mp4
        }
        return item.hlsUrls.first(where: { $0.kind != .pageUrl })?.url
    }

    func resolveThumbnailURL(for item: LibraryItem) async -> LibraryThumbnailResolution? {
        if let thumbnailURL = item.thumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !thumbnailURL.isEmpty {
            return LibraryThumbnailResolution(thumbnailURL: thumbnailURL, image: nil, source: .storedThumbnailURL)
        }

        if Self.isLikelyPageURL(item.url), let pageURL = URL(string: item.url) {
            do {
                let html = try await fetchHTML(pageURL)
                if let thumbnailURL = HTMLThumbnailMetadataExtractor.extractThumbnailURL(from: html, pageURL: pageURL) {
                    return LibraryThumbnailResolution(thumbnailURL: thumbnailURL, image: nil, source: .pageMetadata)
                }
            } catch {
                // Fall through to scraper metadata; page fetch failures should not break Library rendering.
            }

            do {
                let source = try await extractSource(item.url)
                if let thumbnailURL = source.thumbnail?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !thumbnailURL.isEmpty {
                    return LibraryThumbnailResolution(thumbnailURL: thumbnailURL, image: nil, source: .scraperMetadata)
                }
            } catch {
                // Fall through to media-frame fallback.
            }
        }

        if let mediaURL = Self.mediaFallbackURL(for: item) {
            return LibraryThumbnailResolution(thumbnailURL: mediaURL, image: nil, source: .mediaFrame)
        }

        return nil
    }

    func loadThumbnail(for item: LibraryItem) async throws -> LibraryThumbnailResolution {
        guard let resolution = await resolveThumbnailURL(for: item),
              let candidate = resolution.thumbnailURL else {
            throw ThumbnailError.noThumbnailCandidate
        }

        switch resolution.source {
        case .storedThumbnailURL, .pageMetadata, .scraperMetadata:
            let image = try await downloadImage(candidate, candidate, item.url)
            return LibraryThumbnailResolution(thumbnailURL: candidate, image: image, source: resolution.source)
        case .mediaFrame:
            let image = try await generateFrame(candidate)
            return LibraryThumbnailResolution(thumbnailURL: nil, image: image, source: .mediaFrame)
        }
    }

    private static func originReferer(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)/"
    }
}
