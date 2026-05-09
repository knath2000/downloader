import Foundation

protocol FeedScraper {
    static var supportedHost: String { get }
    static func fetchPage(page: Int) async throws -> [FeedItem]
}

enum FeedScraperError: LocalizedError {
    case unsupportedSite(String)
    case invalidPage
    case missingStructuredData
    case invalidStructuredData
    case network(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSite(let host): return "Feed is not available for \(host)."
        case .invalidPage: return "The feed page could not be loaded."
        case .missingStructuredData: return "The feed page did not include video metadata."
        case .invalidStructuredData: return "The feed metadata could not be decoded."
        case .network(let status): return "Feed request failed with HTTP \(status)."
        }
    }
}

struct AllPornStreamFeedScraper: FeedScraper {
    static let supportedHost = "allpornstream.com"

    private static let baseURL = URL(string: "https://allpornstream.com")!

    static func fetchPage(page: Int) async throws -> [FeedItem] {
        let html = try await fetchHTML(page: page)
        let list = try decodeItemList(from: html)
        let previews = previewMap(for: list.itemListElement, html: html)
        return list.itemListElement.compactMap { video in
            feedItem(from: video, previewURLs: previews[video.url] ?? [])
        }
    }

    private static func fetchHTML(page: Int) async throws -> String {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw FeedScraperError.invalidPage
        }
        if page > 1 {
            components.queryItems = [URLQueryItem(name: "page", value: "\(page)")]
        }
        guard let url = components.url else { throw FeedScraperError.invalidPage }

        var request = URLRequest(url: url)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedScraperError.invalidPage }
        guard (200...299).contains(http.statusCode) else { throw FeedScraperError.network(http.statusCode) }
        guard let html = String(data: data, encoding: .utf8) else { throw FeedScraperError.invalidPage }
        return html
    }

    private static func decodeItemList(from html: String) throws -> JSONLDItemList {
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
        do {
            return try JSONDecoder().decode(JSONLDItemList.self, from: data)
        } catch {
            throw FeedScraperError.invalidStructuredData
        }
    }

    private static func feedItem(from video: JSONLDVideoObject, previewURLs: [String]) -> FeedItem? {
        guard let uploadDate = parseDate(video.uploadDate),
              let fullURL = fullPostURL(relative: video.url),
              let id = postID(from: video.url) else {
            return nil
        }
        return FeedItem(
            id: id,
            title: video.name,
            url: fullURL,
            thumbnailURL: previewURLs.first,
            previewURLs: previewURLs,
            uploadDate: uploadDate,
            viewCount: video.interactionStatistic?.userInteractionCount.value ?? 0,
            siteName: supportedHost,
            studio: studio(from: video.name)
        )
    }

    private static func fullPostURL(relative: String) -> String? {
        URL(string: relative, relativeTo: baseURL)?.absoluteString
    }

    private static func postID(from relative: String) -> String? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let postIndex = parts.firstIndex(of: "post"),
              parts.indices.contains(postIndex + 1) else {
            return nil
        }
        return parts[postIndex + 1]
    }

    private static func studio(from title: String) -> String? {
        guard let match = title.range(of: #"^\[([^\]]+)\]"#, options: .regularExpression) else {
            return nil
        }
        let value = title[match]
            .dropFirst()
            .dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func parseDate(_ raw: String) -> Date? {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractionalSeconds.date(from: raw) {
            return date
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func previewMap(for videos: [JSONLDVideoObject], html: String) -> [String: [String]] {
        var output: [String: [String]] = [:]
        for video in videos {
            guard let cardRange = cardRange(for: video, html: html) else { continue }
            let segment = String(html[cardRange])
            let previews = thumbnailURLs(in: segment)
            if !previews.isEmpty {
                output[video.url] = previews
            }
        }
        return output
    }

    private static func cardRange(for video: JSONLDVideoObject, html: String) -> Range<String.Index>? {
        let tokens = [
            "data-href=\"\(video.url)\"",
            "data-slug=\"\(video.url)\""
        ]

        guard let tokenRange = tokens.compactMap({ html.range(of: $0) }).first else {
            return nil
        }

        let end = html.range(of: "data-thumb-id=", range: tokenRange.upperBound..<html.endIndex)?.lowerBound ?? html.endIndex
        return tokenRange.lowerBound..<end
    }

    private static func thumbnailURLs(in html: String) -> [String] {
        if let dataImages = dataImagesAttribute(in: html) {
            let thumbnails = proxiedThumbnailURLs(for: allDirectImageURLs(in: decodeHTMLEntities(dataImages)))
            if !thumbnails.isEmpty { return thumbnails }
        }

        let encodedPattern = #"https%3A%2F%2F[^"'\s,&<>]+\.(?:jpg|jpeg|png|webp)"#
        let encoded = allMatches(pattern: encodedPattern, in: html)
            .compactMap(\.removingPercentEncoding)
        let encodedThumbnails = proxiedThumbnailURLs(for: encoded)
        if !encodedThumbnails.isEmpty {
            return encodedThumbnails
        }

        return proxiedThumbnailURLs(for: allDirectImageURLs(in: decodeHTMLEntities(html)))
    }

    private static func dataImagesAttribute(in html: String) -> String? {
        let pattern = #"data-images=["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[matchRange])
    }

    private static func allDirectImageURLs(in html: String) -> [String] {
        let directPattern = #"https://[^"'\s,&<>\]]+\.(?:jpg|jpeg|png|webp)(?:\?[^"'\s,&<>\]]*)?"#
        return allMatches(pattern: directPattern, in: html)
    }

    private static func proxiedThumbnailURL(for sourceURL: String) -> String? {
        guard sourceURL.hasPrefix("http"),
              !sourceURL.hasPrefix("\(baseURL.absoluteString)/api/images") else {
            return sourceURL
        }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/images"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "src", value: sourceURL),
            URLQueryItem(name: "width", value: "384"),
            URLQueryItem(name: "quality", value: "60")
        ]
        return components?.url?.absoluteString
    }

    private static func proxiedThumbnailURLs(for sourceURLs: [String]) -> [String] {
        var output: [String] = []
        for sourceURL in sourceURLs {
            guard let thumbnail = proxiedThumbnailURL(for: sourceURL),
                  !output.contains(thumbnail) else { continue }
            output.append(thumbnail)
        }
        return output
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        allMatches(pattern: pattern, in: text).first
    }

    private static func allMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}

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

private struct JSONLDItemList: Decodable {
    let itemListElement: [JSONLDVideoObject]
}

struct RentryFeedScraper: FeedScraper {
    static let supportedHost = "rentry.co/OnlyFan420"

    private static let pageURL = URL(string: "https://rentry.co/OnlyFan420")!
    private static let videoHosts: Set<String> = [
        "luluvid.com", "luluvdo.com", "lulustream.com",
        "vidara.so",
        "playmogo.com", "doodstream.com", "dood.wf"
    ]

    static func fetchPage(page: Int) async throws -> [FeedItem] {
        guard page == 1 else { return [] }
        let html = try await fetchHTML()
        return parseEntries(from: html)
    }

    private static func fetchHTML() async throws -> String {
        var request = URLRequest(url: pageURL)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://rentry.co", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedScraperError.invalidPage }
        guard (200...299).contains(http.statusCode) else { throw FeedScraperError.network(http.statusCode) }
        guard let html = String(data: data, encoding: .utf8) else { throw FeedScraperError.invalidPage }
        return html
    }

    private static func parseEntries(from html: String) -> [FeedItem] {
        let datePattern = #"<span[^>]*color:yellow[^>]*>(\d{1,2}\s+[A-Za-z]+\s+\d{4})\s*--"#
        guard let dateRegex = try? NSRegularExpression(pattern: datePattern, options: [.caseInsensitive]) else {
            return []
        }

        let htmlRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let dateMatches = dateRegex.matches(in: html, range: htmlRange)
        guard !dateMatches.isEmpty else { return [] }

        return dateMatches.enumerated().flatMap { index, match -> [FeedItem] in
            guard match.numberOfRanges > 1,
                  let dateRange = Range(match.range(at: 1), in: html),
                  let uploadDate = parseDate(String(html[dateRange])),
                  let sectionStart = Range(match.range, in: html)?.upperBound else {
                return []
            }

            let sectionEnd: String.Index
            if dateMatches.indices.contains(index + 1),
               let nextRange = Range(dateMatches[index + 1].range, in: html) {
                sectionEnd = nextRange.lowerBound
            } else {
                sectionEnd = html.endIndex
            }

            return parseLinks(in: String(html[sectionStart..<sectionEnd]), uploadDate: uploadDate)
        }
    }

    private static func parseLinks(in section: String, uploadDate: Date) -> [FeedItem] {
        let pattern = #"<a\s+class=["']external["']\s+href=["']([^"']+)["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(section.startIndex..<section.endIndex, in: section)
        return regex.matches(in: section, range: range).compactMap { match in
            guard match.numberOfRanges > 2,
                  let hrefRange = Range(match.range(at: 1), in: section),
                  let innerRange = Range(match.range(at: 2), in: section) else {
                return nil
            }

            let href = decodeHTMLEntities(String(section[hrefRange]))
            guard let videoURL = URL(string: href),
                  let host = normalizedHost(videoURL.host),
                  videoHosts.contains(host),
                  let thumbnailURL = thumbnailURL(in: String(section[innerRange])),
                  let id = id(for: videoURL, host: host) else {
                return nil
            }

            let title = title(in: String(section[innerRange]))
            guard !title.isEmpty else { return nil }

            return FeedItem(
                id: id,
                title: title,
                url: videoURL.absoluteString,
                thumbnailURL: thumbnailURL,
                uploadDate: uploadDate,
                viewCount: 0,
                siteName: supportedHost,
                studio: studio(from: title)
            )
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let padded = raw.split(separator: " ", maxSplits: 1).map(String.init)
        let value = padded.first?.count == 1 && padded.count == 2 ? "0\(padded[0]) \(padded[1])" : raw
        let date = ["dd MMMM yyyy", "dd MMM yyyy"].compactMap { format -> Date? in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter.date(from: value)
        }.first
        guard let date else { return nil }
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard let host else { return nil }
        return host.lowercased().replacingOccurrences(of: "www.", with: "")
    }

    private static func id(for url: URL, host: String) -> String? {
        let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty {
            return "\(host):\(last)"
        }
        return url.absoluteString.isEmpty ? nil : url.absoluteString
    }

    private static func thumbnailURL(in innerHTML: String) -> String? {
        let pattern = #"<img[^>]+src=["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(innerHTML.startIndex..<innerHTML.endIndex, in: innerHTML)
        guard let match = regex.firstMatch(in: innerHTML, range: range),
              match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: innerHTML) else {
            return nil
        }
        return decodeHTMLEntities(String(innerHTML[matchRange]))
    }

    private static func title(in innerHTML: String) -> String {
        let textBeforeImage = innerHTML.components(separatedBy: "<img").first ?? innerHTML
        let tagPattern = #"<[^>]+>"#
        let stripped = (try? NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive]))?
            .stringByReplacingMatches(
                in: textBeforeImage,
                range: NSRange(textBeforeImage.startIndex..<textBeforeImage.endIndex, in: textBeforeImage),
                withTemplate: ""
            ) ?? textBeforeImage
        return decodeHTMLEntities(stripped)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func studio(from title: String) -> String? {
        guard let range = title.range(of: #"^([\w][\w\s&'.]*\w)\s+-\s+"#, options: .regularExpression) else {
            return nil
        }
        let value = title[range]
            .replacingOccurrences(of: #"\s+-\s+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

struct HQPornerFeedScraper: FeedScraper {
    static let supportedHost = "hqporner.com"

    private static let baseURL = URL(string: "https://hqporner.com")!

    static func fetchPage(page: Int) async throws -> [FeedItem] {
        let html = try await fetchHTML(page: page)
        return parseEntries(from: html)
    }

    static func parseEntries(from html: String, now: Date = Date()) -> [FeedItem] {
        cardSegments(in: html).compactMap { segment in
            guard segment.contains("/hdporn/"),
                  let rawPath = firstCapture(pattern: #"href=["'](/hdporn/[^"']+)["']"#, in: segment),
                  let url = absoluteURL(rawPath),
                  let id = firstCapture(pattern: #"/hdporn/(\d+)-"#, in: rawPath) else {
                return nil
            }

            let title = title(in: segment)
            guard !title.isEmpty else { return nil }
            let thumb = thumbnailURL(in: segment)
            let previews = previewURLs(in: segment)

            return FeedItem(
                id: "hqporner-\(id)",
                title: title,
                url: url,
                thumbnailURL: thumb,
                previewURLs: previews,
                referer: "\(baseURL.absoluteString)/",
                uploadDate: now,
                uploadDateIsApproximate: true,
                viewCount: 0,
                siteName: supportedHost,
                studio: nil,
                durationSeconds: durationSeconds(in: segment),
                qualityLabels: qualityLabels(in: segment),
                sourceKind: .siteFeed
            )
        }
    }

    private static func fetchHTML(page: Int) async throws -> String {
        let url: URL
        if page <= 1 {
            url = baseURL
        } else if let next = URL(string: "/hdporn/\(page)", relativeTo: baseURL)?.absoluteURL {
            url = next
        } else {
            throw FeedScraperError.invalidPage
        }

        var request = URLRequest(url: url)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FeedScraperError.invalidPage }
        guard (200...299).contains(http.statusCode) else { throw FeedScraperError.network(http.statusCode) }
        guard let html = String(data: data, encoding: .utf8) else { throw FeedScraperError.invalidPage }
        return html
    }

    private static func cardSegments(in html: String) -> [String] {
        let pattern = #"<section\s+class=["'][^"']*\bbox feature\b[^"']*["'][^>]*>.*?</section>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            Range(match.range, in: html).map { String(html[$0]) }
        }
    }

    private static func title(in segment: String) -> String {
        if let title = firstCapture(pattern: #"<h3\s+class=["']meta-data-title["'][^>]*>.*?<a[^>]*>(.*?)</a>"#, in: segment) {
            return decodeHTMLEntities(strippingTags(from: title))
        }
        if let alt = firstCapture(pattern: #"<img[^>]+alt=["']([^"']+)["']"#, in: segment) {
            return decodeHTMLEntities(alt)
        }
        return ""
    }

    private static func thumbnailURL(in segment: String) -> String? {
        guard let raw = firstCapture(pattern: #"<img[^>]+id=["']cover_\d+["'][^>]+src=["']([^"']+)["']"#, in: segment) ??
            firstCapture(pattern: #"<img[^>]+src=["']([^"']+)["'][^>]+id=["']cover_\d+["']"#, in: segment) else {
            return nil
        }
        return absoluteURL(decodeHTMLEntities(raw))
    }

    private static func previewURLs(in segment: String) -> [String] {
        let pattern = #"changeImage\(["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(segment.startIndex..<segment.endIndex, in: segment)
        var urls: [String] = []
        for match in regex.matches(in: segment, range: range) {
            guard match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: segment),
                  let resolved = absoluteURL(decodeHTMLEntities(String(segment[matchRange]))),
                  !urls.contains(resolved) else { continue }
            urls.append(resolved)
        }
        return urls
    }

    static func durationSeconds(from raw: String) -> Int? {
        let lower = raw.lowercased()
        var total = 0
        var matched = false
        let units: [(String, Int)] = [("h", 3600), ("m", 60), ("s", 1)]
        for (unit, multiplier) in units {
            if let value = firstCapture(pattern: #"(\d+)\s*\#(unit)"#, in: lower),
               let number = Int(value) {
                total += number * multiplier
                matched = true
            }
        }
        return matched ? total : nil
    }

    static func resolveUploadDate(from relativeDateString: String, now: Date = Date()) -> Date {
        let s = relativeDateString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let calendar = Calendar.current

        if s == "today" {
            return now
        }
        if s == "yesterday" {
            return calendar.date(byAdding: .day, value: -1, to: now) ?? now
        }
        if s == "one week ago" {
            return calendar.date(byAdding: .weekOfYear, value: -1, to: now) ?? now
        }

        let patterns: [(String, Calendar.Component)] = [
            (#"(\d+)\s+days?\s+ago"#, .day),
            (#"(\d+)\s+weeks?\s+ago"#, .weekOfYear),
            (#"(\d+)\s+months?\s+ago"#, .month),
            (#"(\d+)\s+years?\s+ago"#, .year),
        ]

        for (pattern, component) in patterns {
            if let match = try? NSRegularExpression(pattern: pattern).firstMatch(
                in: s,
                range: NSRange(s.startIndex..<s.endIndex, in: s)
            ),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: s),
               let value = Int(s[range]) {
                return calendar.date(byAdding: component, value: -value, to: now) ?? now
            }
        }

        return now
    }

    static func fetchUploadDate(for videoURL: String) async -> Date? {
        guard let url = URL(string: videoURL) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        guard let relativeDate = uploadDateString(in: html) else { return nil }
        return resolveUploadDate(from: relativeDate)
    }

    private static func durationSeconds(in segment: String) -> Int? {
        guard let raw = firstCapture(pattern: #"fa-clock-o\s+meta-data["'][^>]*>([^<]+)<"#, in: segment) else {
            return nil
        }
        return durationSeconds(from: raw)
    }

    private static func qualityLabels(in segment: String) -> [String] {
        let candidates = ["4K", "2160p", "1440p", "1080p", "720p", "60FPS", "HD"]
        let lower = segment.lowercased()
        let labels = candidates.filter { lower.contains($0.lowercased()) }
        return labels.isEmpty ? ["HD"] : labels
    }

    private static func uploadDateString(in html: String) -> String? {
        guard let raw = firstCapture(pattern: #"<li[^>]*fa-calendar[^>]*>([^<]+)</li>"#, in: html) else {
            return nil
        }
        return decodeHTMLEntities(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func absoluteURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("//") {
            return "https:\(trimmed)"
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
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

    private static func strippingTags(from value: String) -> String {
        let pattern = #"<[^>]+>"#
        return (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?
            .stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value),
                withTemplate: ""
            ) ?? value
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

private struct JSONLDVideoObject: Decodable {
    let position: Int?
    let name: String
    let url: String
    let uploadDate: String
    let interactionStatistic: JSONLDInteractionStatistic?
}

private struct JSONLDInteractionStatistic: Decodable {
    let userInteractionCount: FlexibleInt
}

private struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let string = try? container.decode(String.self),
                  let int = Int(string) {
            value = int
        } else {
            value = 0
        }
    }
}
