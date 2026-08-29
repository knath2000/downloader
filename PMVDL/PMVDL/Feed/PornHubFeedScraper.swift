import Foundation

struct PornHubFeedScraper: FeedScraper {
    static let supportedHost = "pornhub.com"

    private static let baseURL = URL(string: "https://www.pornhub.com")!

    static func fetchPage(page: Int) async throws -> [FeedItem] {
        let section = await MainActor.run { FeedViewModel.shared.selectedPornHubSection }
        return try await fetchPage(page: page, section: section)
    }

    static func fetchPage(page: Int, section: PornHubSection) async throws -> [FeedItem] {
        let html = try await fetchHTML(page: page, section: section, usesActiveUploader: true)
        return parseEntries(from: html)
    }

    static func fetchProfilePage(page: Int, section: PornHubSection) async throws -> [FeedItem] {
        let html = try await fetchHTML(page: page, section: section, usesActiveUploader: false)
        return parseEntries(from: html)
    }

    static func fetchSubscriptions() async throws -> [PornHubSubscription] {
        let html = try await fetchHTML(page: 1, section: .subscriptions, usesActiveUploader: false)
        return parseSubscriptions(from: html)
    }

    private static func fetchHTML(page: Int, section: PornHubSection, usesActiveUploader: Bool) async throws -> String {
        let url: URL
        if usesActiveUploader,
           let uploaderBase = await MainActor.run(body: { FeedViewModel.shared.pornHubUploaderURL }) {
            var raw = uploaderBase
            if raw.hasSuffix("/") {
                raw.removeLast()
            }
            let pageQuery = page > 1 ? "?page=\(page)" : ""
            guard let uploaderURL = URL(string: "\(raw)/videos\(pageQuery)") else { throw FeedScraperError.invalidPage }
            url = uploaderURL
        } else {
            guard let sectionURL = section.feedURL(page: page) else { throw FeedScraperError.invalidPage }
            url = sectionURL
        }

        var request = URLRequest(url: url)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("\(baseURL.absoluteString)/", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 20

        let pornhubCookies = (HTTPCookieStorage.shared.cookies ?? [])
            .filter { $0.domain.contains("pornhub.com") }
        if !pornhubCookies.isEmpty,
           let cookieHeader = HTTPCookie.requestHeaderFields(with: pornhubCookies)["Cookie"] {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedScraperError.invalidPage }
        guard (200...299).contains(http.statusCode) else { throw FeedScraperError.network(http.statusCode) }
        guard let html = String(data: data, encoding: .utf8) else { throw FeedScraperError.invalidPage }
        return html
    }

    /// Fetches a single video page and returns its real title, reusing the same
    /// headers/cookies as the feed requests. Returns `nil` on any failure or when no
    /// usable title is found.
    static func fetchVideoPageTitle(viewkey: String) async throws -> String? {
        guard let url = URL(string: "\(baseURL.absoluteString)/view_video.php?viewkey=\(viewkey)") else {
            throw FeedScraperError.invalidPage
        }

        var request = URLRequest(url: url)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("\(baseURL.absoluteString)/", forHTTPHeaderField: "Referer")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 20

        let pornhubCookies = (HTTPCookieStorage.shared.cookies ?? [])
            .filter { $0.domain.contains("pornhub.com") }
        if !pornhubCookies.isEmpty,
           let cookieHeader = HTTPCookie.requestHeaderFields(with: pornhubCookies)["Cookie"] {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else { return nil }
        guard let html = String(data: data, encoding: .utf8) else { return nil }

        guard let raw = NativeVideoPageExtractor.extractTitle(from: html, pageURL: url),
              !raw.isEmpty else { return nil }
        return raw
            .replacingOccurrences(of: " - Pornhub.com", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: " | Pornhub.com", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseEntries(from html: String) -> [FeedItem] {
        let pattern = #"<li[^>]+class=["'][^"']*pcVideoListItem[^"']*["'][^>]*>.*?</li>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let segments = regex.matches(in: html, range: range).compactMap { match in
            Range(match.range, in: html).map { String(html[$0]) }
        }
        return segments.compactMap { feedItem(from: $0) }
    }

    static func parseSubscriptions(from html: String) -> [PornHubSubscription] {
        let pattern = #"<a[^>]+href=["'](/(?:model|pornstar|channels|user)/[^"']+)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var order: [String] = []
        var subscriptionsByURL: [String: PornHubSubscription] = [:]

        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges > 2,
                  let pathRange = Range(match.range(at: 1), in: html),
                  let anchorRange = Range(match.range, in: html) else { continue }

            guard let url = normalizedUploaderURL(String(html[pathRange])) else { continue }

            let anchorHTML = String(html[anchorRange])
            guard let name = subscriptionName(from: anchorHTML) else { continue }

            let key = url.lowercased()
            let subscription = PornHubSubscription(name: name, url: url)
            if let existing = subscriptionsByURL[key] {
                if subscriptionNameScore(name) > subscriptionNameScore(existing.name) {
                    subscriptionsByURL[key] = subscription
                }
            } else {
                order.append(key)
                subscriptionsByURL[key] = subscription
            }
        }

        return order.compactMap { subscriptionsByURL[$0] }
    }

    private static func feedItem(from segment: String) -> FeedItem? {
        guard let viewkey = firstCapture(pattern: #"data-video-vkey=["']([^"']+)["']"#, in: segment) else { return nil }
        let url = "\(baseURL.absoluteString)/view_video.php?viewkey=\(viewkey)"

        let title = [
            firstCapture(pattern: #"href=["']/view_video\.php[^"']+["'][^>]*title=["']([^"']+)["']"#, in: segment),
            firstCapture(pattern: #"<a[^>]+title=["']([^"']+)["'][^>]*>"#, in: segment),
        ].compactMap { $0 }.first
            .map { decodeHTMLEntities($0) } ?? ""
        guard !title.isEmpty else { return nil }

        let thumbURL = [
            firstCapture(pattern: #"data-image=["']([^"']+)["']"#, in: segment),
            firstCapture(pattern: #"data-mediumthumb=["']([^"']+)["']"#, in: segment),
            firstCapture(pattern: #"<img[^>]+src=["'](https://[^"']*phncdn\.com[^"']+)["']"#, in: segment),
        ].compactMap { $0 }.compactMap(absoluteURL).first
        let previewVideoURL = firstCapture(pattern: #"data-mediabook=["']([^"']+)["']"#, in: segment)
            .map { decodeHTMLEntities($0) }
            .flatMap { $0.hasPrefix("http") ? $0 : nil }

        let durationRaw = firstCapture(pattern: #"<var[^>]+class=["'][^"']*duration[^"']*["'][^>]*>([^<]+)<"#, in: segment) ?? ""
        let viewsRaw = firstCapture(pattern: #"<span[^>]+class=["'][^"']*views[^"']*["'][^>]*>\s*<var[^>]*>([^<]+)</var>"#, in: segment)
            ?? firstCapture(pattern: #"class=["'][^"']*views[^"']*["'][^>]*>.*?<var[^>]*>([^<]+)<"#, in: segment)
            ?? ""
        let uploader = uploader(in: segment)
        let addedRaw = firstCapture(pattern: #"<var[^>]+class=["'][^"']*added[^"']*["'][^>]*>([^<]+)</var>"#, in: segment)
        let uploadDate = addedRaw.map { HQPornerFeedScraper.resolveUploadDate(from: decodeHTMLEntities($0)) } ?? Date()

        return FeedItem(
            id: "pornhub-\(viewkey)",
            title: title,
            url: url,
            thumbnailURL: thumbURL,
            previewURLs: [],
            previewVideoURL: previewVideoURL,
            referer: baseURL.absoluteString,
            uploadDate: uploadDate,
            uploadDateIsApproximate: addedRaw == nil,
            viewCount: parseViews(viewsRaw),
            siteName: supportedHost,
            studio: uploader.isPerformer ? nil : uploader.name,
            studioURL: uploader.url,
            durationSeconds: parseDuration(durationRaw),
            categories: parseCategories(from: segment),
            tags: parseTags(from: segment),
            performers: uploader.isPerformer ? [uploader.name].compactMap { $0 } : [],
            sourceKind: .siteFeed
        )
    }

    private static func uploader(in segment: String) -> (name: String?, url: String?, isPerformer: Bool) {
        let pattern = #"href=["'](/(?:model|pornstar|channels|user)/[^"']+)["'][^>]*>([^<]+)<"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (nil, nil, false)
        }
        let range = NSRange(segment.startIndex..<segment.endIndex, in: segment)
        guard let match = regex.firstMatch(in: segment, range: range),
              match.numberOfRanges > 2,
              let pathRange = Range(match.range(at: 1), in: segment),
              let nameRange = Range(match.range(at: 2), in: segment) else {
            return (nil, nil, false)
        }
        let path = String(segment[pathRange])
        return (
            decodeHTMLEntities(String(segment[nameRange])),
            normalizedUploaderURL(path),
            path.hasPrefix("/pornstar/") || path.hasPrefix("/model/") || path.hasPrefix("/user/")
        )
    }

    static func normalizedUploaderURL(_ raw: String) -> String? {
        guard let path = normalizedUploaderPath(raw),
              isAllowedUploaderPath(path) else { return nil }
        return "\(baseURL.absoluteString)\(path)"
    }

    private static func normalizedUploaderPath(_ raw: String) -> String? {
        let decoded = decodeHTMLEntities(raw)
        guard let url = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
              let host = url.host?.lowercased(),
              host == "pornhub.com" || host.hasSuffix(".pornhub.com") else { return nil }

        let trimmed = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var parts = trimmed.split(separator: "/").map(String.init)
        if parts.last == "videos" {
            parts.removeLast()
        }
        guard parts.count >= 2 else { return nil }
        return "/" + parts.prefix(2).joined(separator: "/")
    }

    private static func isAllowedUploaderPath(_ path: String) -> Bool {
        let parts = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").map(String.init)
        guard parts.count == 2 else { return false }
        switch parts[0].lowercased() {
        case "model", "pornstar", "channels":
            return true
        case "user":
            return !blockedUserPaths.contains(parts[1].lowercased())
        default:
            return false
        }
    }

    private static func subscriptionName(from html: String) -> String? {
        let imageAlt = firstCapture(pattern: #"<img[^>]+alt=["']([^"']+)["']"#, in: html)
        let title = firstCapture(pattern: #"title=["']([^"']+)["']"#, in: html)
        let ariaLabel = firstCapture(pattern: #"aria-label=["']([^"']+)["']"#, in: html)
        let text = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return [imageAlt, title, ariaLabel, text]
            .compactMap { $0 }
            .map(decodeHTMLEntities)
            .map { $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(sanitizedSubscriptionName)
            .max { subscriptionNameScore($0) < subscriptionNameScore($1) }
    }

    private static func sanitizedSubscriptionName(_ value: String) -> String? {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        guard !genericSubscriptionLabels.contains(name.lowercased()) else { return nil }

        for suffix in ["'s Avatar", "’s Avatar"] where name.localizedCaseInsensitiveContains(suffix) {
            name = name.replacingOccurrences(of: suffix, with: "", options: [.caseInsensitive])
        }
        if name.lowercased().hasSuffix(" avatar"), name.count > " avatar".count {
            name.removeLast(" avatar".count)
            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !name.isEmpty,
              !genericSubscriptionLabels.contains(name.lowercased()) else { return nil }
        return name
    }

    private static func subscriptionNameScore(_ value: String) -> Int {
        var score = min(value.count, 80)
        if value.contains(" ") { score += 20 }
        if value.contains("-") || value.contains("_") { score -= 10 }
        return score
    }

    private static let blockedUserPaths: Set<String> = [
        "discover",
        "edit",
        "logout",
        "search"
    ]

    private static let genericSubscriptionLabels: Set<String> = [
        "avatar",
        "channel avatar",
        "gifs",
        "model avatar",
        "photos",
        "playlists",
        "videos"
    ]

    private static func parseCategories(from segment: String) -> [String] {
        linkedLabels(pattern: #"href=["']/category/[^"']+["'][^>]*>([^<]+)<"#, in: segment)
    }

    private static func parseTags(from segment: String) -> [String] {
        linkedLabels(pattern: #"href=["']/tags/[^"']+["'][^>]*>([^<]+)<"#, in: segment)
    }

    private static func linkedLabels(pattern: String, in segment: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(segment.startIndex..<segment.endIndex, in: segment)
        var seen = Set<String>()
        return regex.matches(in: segment, range: range).compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let labelRange = Range(match.range(at: 1), in: segment) else { return nil }
            let label = decodeHTMLEntities(String(segment[labelRange]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seen.insert(label.lowercased()).inserted else { return nil }
            return label
        }
    }

    private static func parseDuration(_ raw: String) -> Int? {
        let parts = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":")
            .compactMap { Int($0) }
        switch parts.count {
        case 2:
            return parts[0] * 60 + parts[1]
        case 3:
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default:
            return nil
        }
    }

    private static func parseViews(_ raw: String) -> Int {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ",", with: "")
        if value.hasSuffix("m"), let number = Double(value.dropLast()) {
            return Int(number * 1_000_000)
        }
        if value.hasSuffix("k"), let number = Double(value.dropLast()) {
            return Int(number * 1_000)
        }
        return Int(value) ?? 0
    }

    private static func absoluteURL(_ raw: String) -> String? {
        let decoded = decodeHTMLEntities(raw)
        if decoded.hasPrefix("//") {
            return "https:\(decoded)"
        }
        return URL(string: decoded, relativeTo: baseURL)?.absoluteURL.absoluteString
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
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct JSONLDItemList: Decodable {
    let itemListElement: [JSONLDVideoObject]
}
