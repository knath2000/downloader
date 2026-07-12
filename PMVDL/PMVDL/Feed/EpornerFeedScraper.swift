import Foundation

struct EpornerFeedScraper: FeedScraper {
    static let supportedHost = "eporner.com"

    private static let baseURL = URL(string: "https://www.eporner.com")!

    static func fetchPage(page: Int) async throws -> [FeedItem] {
        let section = await MainActor.run { FeedViewModel.shared.selectedEpornerSection }
        return try await fetchPage(page: page, section: section)
    }

    static func fetchPage(page: Int, section: EpornerSection) async throws -> [FeedItem] {
        let html = try await fetchHTML(page: page, section: section, usesActiveUploader: true)
        return parseEntries(from: html)
    }

    static func fetchProfilePage(page: Int, section: EpornerSection) async throws -> [FeedItem] {
        let html = try await fetchHTML(page: page, section: section, usesActiveUploader: false)
        return parseEntries(from: html)
    }

    static func fetchSubscriptions() async throws -> [PornHubSubscription] {
        let html = try await fetchHTML(page: 1, section: .subscriptions, usesActiveUploader: false)
        return parseSubscriptions(from: html)
    }

    private static func fetchHTML(page: Int, section: EpornerSection, usesActiveUploader: Bool) async throws -> String {
        let url: URL
        if usesActiveUploader,
           let uploaderBase = await MainActor.run(body: { FeedViewModel.shared.epornerUploaderURL }) {
            var raw = uploaderBase
            if raw.hasSuffix("/") {
                raw.removeLast()
            }
            let pageQuery = page > 1 ? "?p=\(page)" : ""
            guard let uploaderURL = URL(string: "\(raw)/videos\(pageQuery)") else {
                throw FeedScraperError.invalidPage
            }
            url = uploaderURL
        } else {
            guard let sectionURL = section.feedURL(page: page) else {
                throw FeedScraperError.invalidPage
            }
            url = sectionURL
        }

        var request = URLRequest(url: url)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("\(baseURL.absoluteString)/", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 20

        let epornerCookies = (HTTPCookieStorage.shared.cookies ?? [])
            .filter { $0.domain.contains("eporner.com") }
        if !epornerCookies.isEmpty,
           let header = HTTPCookie.requestHeaderFields(with: epornerCookies)["Cookie"] {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedScraperError.invalidPage }
        guard (200...299).contains(http.statusCode) else {
            throw FeedScraperError.network(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw FeedScraperError.invalidPage
        }
        return html
    }

    static func parseEntries(from html: String) -> [FeedItem] {
        if let jsonld = parseFromJSONLD(from: html), !jsonld.isEmpty {
            return jsonld
        }
        return parseHTMLCards(from: html)
    }

    private static func parseFromJSONLD(from html: String) -> [FeedItem]? {
        guard let list = try? decodeJSONLDItemList(from: html), !list.itemListElement.isEmpty else {
            return nil
        }

        let items = list.itemListElement.compactMap { video in
            feedItem(from: video)
        }
        return items.isEmpty ? nil : items
    }

    private static func decodeJSONLDItemList(from html: String) throws -> JSONLDItemList {
        let pattern = #"<script[^>]+type=["']application/ld\+json["'][^>]*>(.*?)</script>"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let scripts = regex.matches(in: html, range: range).compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let scriptRange = Range(match.range(at: 1), in: html) else {
                return nil
            }
            return String(html[scriptRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let script = scripts.first(where: { $0.contains("ItemList") && $0.contains("VideoObject") }) else {
            throw FeedScraperError.missingStructuredData
        }
        guard let data = script.data(using: .utf8) else { throw FeedScraperError.invalidStructuredData }
        return try JSONDecoder().decode(JSONLDItemList.self, from: data)
    }

    private static func feedItem(from video: JSONLDVideoObject) -> FeedItem? {
        guard let id = videoID(from: video.url),
              let url = absoluteURL(video.url),
              let uploadDate = parseDate(video.uploadDate) else {
            return nil
        }

        return FeedItem(
            id: "eporner-\(id)",
            title: video.name,
            url: url,
            thumbnailURL: absoluteURL(video.thumbnailUrl),
            previewURLs: [],
            referer: baseURL.absoluteString,
            uploadDate: uploadDate,
            viewCount: video.interactionStatistic?.userInteractionCount.value ?? 0,
            siteName: supportedHost,
            studio: parseStudio(from: video.name),
            durationSeconds: parseDuration(video.duration),
            categories: [],
            tags: [],
            performers: [],
            qualityLabels: [],
            sourceKind: .siteFeed
        )
    }

    private static func parseStudio(from title: String) -> String? {
        guard let match = title.range(of: #"^\[([^\]]+)\]"#, options: .regularExpression) else {
            return nil
        }
        let value = title[match]
            .dropFirst()
            .dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : String(value)
    }

    private static func videoID(from raw: String) -> String? {
        firstCapture(pattern: #"\/video-([A-Za-z0-9]+)"#, in: raw)
    }

    private static func parseHTMLCards(from html: String) -> [FeedItem] {
        let pattern = #"<a[^>]+href=["'](\/video-[^"']+)["'][^>]*>.*?</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: range)
        var items: [FeedItem] = []
        var seen: Set<String> = []
        for match in matches {
            guard match.numberOfRanges > 1,
                  let pathRange = Range(match.range(at: 1), in: html),
                  let itemRange = Range(match.range, in: html) else {
                continue
            }
            let path = String(html[pathRange])
            guard let id = videoID(from: path),
                  !seen.contains(id),
                  let item = parseHTMLCard(from: String(html[itemRange]), path: path) else {
                continue
            }
            seen.insert(id)
            items.append(item)
        }
        return items
    }

    private static func parseHTMLCard(from segment: String, path: String) -> FeedItem? {
        guard let id = videoID(from: path),
              let url = absoluteURL(path) else { return nil }

        let title = [
            firstCapture(pattern: #"data-title=["']([^"']+)["']"#, in: segment),
            firstCapture(pattern: #"title=["']([^"']+)["']"#, in: segment),
            firstCapture(pattern: #"<img[^>]+alt=["']([^"']+)["']"#, in: segment),
        ].compactMap { $0 }
            .map(decodeHTMLEntities)
            .first { !$0.isEmpty }
            ?? "Eporner video"

        let uploader = uploader(in: segment)
        let thumbnail = [
            firstCapture(pattern: #"data-src=["']([^"']+)["']"#, in: segment),
            firstCapture(pattern: #"src=["']([^"']+)["']"#, in: segment),
        ].compactMap { absoluteURL($0) }
            .first

        return FeedItem(
            id: "eporner-\(id)",
            title: title,
            url: url,
            thumbnailURL: thumbnail,
            previewURLs: [],
            previewVideoURL: nil,
            referer: baseURL.absoluteString,
            uploadDate: Date(),
            viewCount: parseViews(from: segment),
            siteName: supportedHost,
            studio: uploader.name,
            studioURL: uploader.url,
            durationSeconds: parseDuration(rawDuration(in: segment)),
            categories: [],
            tags: [],
            performers: [],
            qualityLabels: [],
            sourceKind: .siteFeed
        )
    }

    static func parseSubscriptions(from html: String) -> [PornHubSubscription] {
        let pattern = #"<a[^>]+href=["'](/(?:profile|channels|pornstar)/[^"']+)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var ordered: [String] = []
        var byURL: [String: PornHubSubscription] = [:]

        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges > 2,
                  let pathRange = Range(match.range(at: 1), in: html),
                  let anchorRange = Range(match.range(at: 2), in: html) else {
                continue
            }
            let rawPath = String(html[pathRange])
            guard let normalizedURL = normalizedUploaderURL(rawPath),
                  let name = subscriptionName(String(html[anchorRange])) else {
                continue
            }
            let key = normalizedURL.lowercased()
            if byURL[key] == nil {
                ordered.append(key)
            }
            byURL[key] = PornHubSubscription(name: name, url: normalizedURL)
        }

        return ordered.compactMap { byURL[$0] }
    }

    static func normalizedUploaderURL(_ raw: String) -> String? {
        guard let path = normalizedUploaderPath(raw),
              isAllowedUploaderPath(path) else { return nil }
        return "\(baseURL.absoluteString)\(path)"
    }

    static func normalizedUploaderPath(_ raw: String) -> String? {
        let decoded = decodeHTMLEntities(raw)
        guard let url = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
              let host = url.host?.lowercased(),
              host == "eporner.com" || host.hasSuffix(".eporner.com") else { return nil }

        let trimmed = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = trimmed.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        if parts.count > 2, parts[2] == "videos" {
            // keep profile/channels/pornstar roots only
            return "/" + parts.prefix(2).joined(separator: "/")
        }
        return "/" + parts.prefix(2).joined(separator: "/")
    }

    private static func isAllowedUploaderPath(_ path: String) -> Bool {
        let parts = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").map(String.init)
        guard parts.count >= 1 else { return false }
        switch parts[0].lowercased() {
        case "profile", "channels", "pornstar":
            return parts.count >= 2
        default:
            return false
        }
    }

    private static func subscriptionName(_ html: String) -> String? {
        let imageAlt = firstCapture(pattern: #"<img[^>]+alt=["']([^"']+)["']"#, in: html)
        let title = firstCapture(pattern: #"title=["']([^"']+)["']"#, in: html)
        let aria = firstCapture(pattern: #"aria-label=["']([^"']+)["']"#, in: html)
        let text = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return [imageAlt, title, aria, text]
            .compactMap { $0 }
            .map(decodeHTMLEntities)
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func uploader(in segment: String) -> (name: String?, url: String?) {
        let pattern = #"href=["'](/(?:profile|channels|pornstar)/[^"']+)["'][^>]*>([^<]+)<"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: segment, range: NSRange(segment.startIndex..<segment.endIndex, in: segment)),
              match.numberOfRanges > 2,
              let pathRange = Range(match.range(at: 1), in: segment),
              let nameRange = Range(match.range(at: 2), in: segment) else {
            return (nil, nil)
        }
        let path = String(segment[pathRange])
        return (decodeHTMLEntities(String(segment[nameRange])), normalizedUploaderURL(path))
    }

    private static func parseDuration(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        if let parsed = ISO8601DurationParser.seconds(from: raw) {
            return parsed
        }

        let trimmed = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = firstCapture(pattern: #"(\d+)m(\d+)s"#, in: trimmed) {
            let parts = match.split(separator: "m")
            if parts.count == 2,
               let minutes = Int(parts[0]),
               let seconds = Int(parts[1]) {
                return minutes * 60 + seconds
            }
        }
        let segments = trimmed.split(separator: ":").compactMap { Int($0) }
        if segments.count == 3 {
            return segments[0] * 3600 + segments[1] * 60 + segments[2]
        }
        if segments.count == 2 {
            return segments[0] * 60 + segments[1]
        }
        return Int(trimmed)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let strict = ISO8601DateFormatter()
        strict.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = strict.date(from: raw) {
            return date
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func parseViews(from segment: String) -> Int {
        let value = firstCapture(pattern: #"(\\d+(?:[.,]\\d+)?[km]?)\s*(?:views|view|VIEWS)"#, in: segment)?
            .replacingOccurrences(of: ",", with: "")
            .lowercased() ?? ""

        if value.hasSuffix("m"), let number = Double(value.dropLast()) {
            return Int(number * 1_000_000)
        }
        if value.hasSuffix("k"), let number = Double(value.dropLast()) {
            return Int(number * 1_000)
        }
        return Int(value) ?? 0
    }

    private static func rawDuration(in segment: String) -> String? {
        return firstCapture(pattern: #"<[^>]*class=["'][^\"']*duration[^\"']*["'][^>]*>([^<]+)<"#, in: segment)
    }

    private static func absoluteURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("//") {
            return "https:\(trimmed)"
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[matchRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
