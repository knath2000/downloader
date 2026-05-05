import Foundation

/// Extracts video sources from supported native pages.
struct NativeVideoPageExtractor: VideoSiteExtractor {

    static func supports(_ url: URL) -> Bool {
        url.host()?.contains("pmvhaven.com") ?? false
    }

    static func extract(fromHTML: String, url: URL) async throws -> VideoSource {
        // If the caller already fetched the page HTML, use it; otherwise fetch it ourselves.
        let pageHtml: String
        if fromHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pageHtml = try await fetchPage(url: url)
        } else {
            pageHtml = fromHTML
        }

        // pmvhaven's CDN (video.pmvhaven.com via Cloudflare) hot-link protects the origin:
        // requests without a `Referer: https://pmvhaven.com/` header are throttled to a few
        // KB/sec, which makes large downloads appear stuck at 0%. Attach the Referer + a
        // browser User-Agent both at the source level (so the bare mp4 URL can pick them up)
        // and on every HLS quality (so quality-keyed lookups work too).
        let siteHeaders: [String: String] = [
            "Referer": "https://pmvhaven.com/",
            "User-Agent": NetworkConstants.chromeUserAgent
        ]
        let pageUrlString = url.absoluteString

        // Extract title and thumbnail from page metadata
        let title = extractTitle(from: pageHtml, pageURL: url)
        let thumbnail = extractThumbnail(from: pageHtml)

        // Find MP4 URLs
        let mp4Urls = pageHtml.matches(for: #"\"(https?://[^\s\"]+\.mp4)\""#)
        let mp4Url = mp4Urls.first

        // Find HLS URLs
        let hlsUrls = pageHtml.matches(for: #"\"(https?://[^\s\"]+\.m3u8)\""#)

        let mainBase = mp4Url.map { $0 + "/" }
        var seen = Set<String>()
        var hls: [VideoSource.Quality] = []
        var masterUrl: String?

        let resOrder = ["2160p": 0, "1440p": 1, "1080p": 2, "720p": 3, "480p": 4, "360p": 5]

        for u in hlsUrls {
            guard !seen.contains(u) else { continue }
            seen.insert(u)

            if let resMatch = u.range(of: "/(\\d+p)\\.m3u8$", options: .regularExpression),
               let mainBase, u.hasPrefix(mainBase) {
                let raw = u[resMatch]
                let res = String(raw.dropFirst().dropLast(6))
                hls.append(VideoSource.Quality(
                    label: res, url: u, kind: .hlsManifest,
                    headers: siteHeaders, sourcePageUrl: pageUrlString
                ))
            } else if u.hasSuffix("/master.m3u8"), let mainBase, u.hasPrefix(mainBase) {
                masterUrl = u
            }
        }

        hls.sort { a, b in
            (resOrder[a.label] ?? 99) < (resOrder[b.label] ?? 99)
        }

        if let masterUrl {
            hls.append(VideoSource.Quality(
                label: "master", url: masterUrl, kind: .hlsManifest,
                headers: siteHeaders, sourcePageUrl: pageUrlString
            ))
        }

        guard mp4Url != nil || !hls.isEmpty else {
            throw VideoExtractorError.noVideoSources
        }

        return VideoSource(mp4: mp4Url, hls: hls, title: title, thumbnail: thumbnail,
                           siteName: "NativeVideoPage", headers: siteHeaders)
    }

    // MARK: - Network

    private static func fetchPage(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw VideoExtractorError.network(
                NSError(domain: "VidDL", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to decode page"])
            )
        }
        return html
    }

    // MARK: - Title extraction

    /// Cascade: og:title → twitter:title → <title> tag → <h1> → URL slug fallback
    static func extractTitle(from html: String, pageURL: URL) -> String? {
        if let og = metaContent(for: "og:title", in: html), !og.isEmpty {
            return cleanTitle(og)
        }
        if let tw = metaContent(for: "twitter:title", in: html), !tw.isEmpty {
            return cleanTitle(tw)
        }
        if let t = tagContent(tag: "title", in: html), !t.isEmpty {
            return cleanTitle(t)
        }
        if let h = tagContent(tag: "h1", in: html), !h.isEmpty {
            return cleanTitle(h)
        }
        return fallbackTitle(from: pageURL)
    }

    // MARK: - Thumbnail extraction

    /// Cascade: og:image → twitter:image
    static func extractThumbnail(from html: String) -> String? {
        if let og = metaContent(for: "og:image", in: html), !og.isEmpty { return og }
        if let tw = metaContent(for: "twitter:image", in: html), !tw.isEmpty { return tw }
        return nil
    }

    // MARK: - HTML parsing helpers

    /// Extracts the `content` attribute of the first `<meta>` tag whose `property` or `name`
    /// attribute equals `key`. Works regardless of attribute order.
    static func metaContent(for key: String, in html: String) -> String? {
        // Match any <meta ... > tag that mentions the key
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let tagPattern = "<meta[^>]+(?:property|name)=[\"']\\s*\(escaped)\\s*[\"'][^>]*>"
        guard let regex = try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let tagRange = Range(match.range, in: html) else { return nil }
        let tag = String(html[tagRange])
        return attribute(name: "content", in: tag)
    }

    /// Extracts the value of a named attribute from a single HTML tag string.
    static func attribute(name: String, in tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        // Handles both double and single quotes
        let pattern = "\(escaped)=[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let r = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[r])
    }

    /// Extracts the text content between the first opening and closing tag of `tag`.
    static func tagContent(tag: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escaped)[^>]*>([\\s\\S]*?)</\(escaped)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[r])
    }

    // MARK: - Title cleaning

    /// Strips HTML tags, decodes entities, trims site suffixes, whitespace.
    static func cleanTitle(_ raw: String) -> String? {
        var s = stripTags(raw)
        s = decodeBasicHTMLEntities(s)
        // Strip common PMVHaven page-title suffixes like " - PMVHaven" or " | PMVHaven"
        let suffixes = [" - PMVHaven", " | PMVHaven", " – PMVHaven", " — PMVHaven",
                        " - pmvhaven", " | pmvhaven"]
        for suffix in suffixes {
            if s.lowercased().hasSuffix(suffix.lowercased()) {
                s = String(s.dropLast(suffix.count))
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    static func stripTags(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                              withTemplate: "")
    }

    static func decodeBasicHTMLEntities(_ s: String) -> String {
        var result = s
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&#x27;", "'"), ("&#x2F;", "/")
        ]
        for (entity, char) in entities {
            result = result.replacingOccurrences(of: entity, with: char,
                                                 options: .caseInsensitive)
        }
        // Numeric decimal entities &#NNN;
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let r = Range(match.range, in: result),
                      let nr = Range(match.range(at: 1), in: result),
                      let codepoint = UInt32(result[nr]),
                      let scalar = Unicode.Scalar(codepoint) else { continue }
                result.replaceSubrange(r, with: String(scalar))
            }
        }
        return result
    }

    // MARK: - URL slug fallback

    /// Converts the last non-ID path component of a PMVHaven URL into a human-readable title.
    /// e.g. `/video/appetite_69b359ef6f11592f7f502f61` → "Appetite"
    static func fallbackTitle(from url: URL) -> String? {
        // PMVHaven paths look like /video/<slug>_<24-char-hex-id>
        // We want the slug part before the ID.
        let components = url.pathComponents.filter { $0 != "/" }
        guard let last = components.last else { return nil }

        // Strip trailing hex ID (underscore + 24 hex chars)
        var slug = last
        if let range = slug.range(of: "_[0-9a-f]{24}$", options: .regularExpression) {
            slug = String(slug[slug.startIndex..<range.lowerBound])
        }

        // Replace separators with spaces and capitalise
        slug = slug.replacingOccurrences(of: "_", with: " ")
                   .replacingOccurrences(of: "-", with: " ")
        slug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty else { return nil }
        return slug.capitalized
    }
}
