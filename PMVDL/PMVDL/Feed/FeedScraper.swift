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
        let thumbnails = thumbnailMap(for: list.itemListElement, html: html)
        return list.itemListElement.compactMap { video in
            feedItem(from: video, thumbnailURL: thumbnails[video.url])
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

    private static func feedItem(from video: JSONLDVideoObject, thumbnailURL: String?) -> FeedItem? {
        guard let uploadDate = parseDate(video.uploadDate),
              let fullURL = fullPostURL(relative: video.url),
              let id = postID(from: video.url) else {
            return nil
        }
        return FeedItem(
            id: id,
            title: video.name,
            url: fullURL,
            thumbnailURL: thumbnailURL,
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

    private static func thumbnailMap(for videos: [JSONLDVideoObject], html: String) -> [String: String] {
        var output: [String: String] = [:]
        for video in videos {
            guard let cardRange = cardRange(for: video, html: html) else { continue }
            let segment = String(html[cardRange])
            if let thumbnail = firstThumbnailURL(in: segment) {
                output[video.url] = thumbnail
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

    private static func firstThumbnailURL(in html: String) -> String? {
        if let dataImages = dataImagesAttribute(in: html),
           let thumbnail = firstDirectImageURL(in: decodeHTMLEntities(dataImages)) {
            return proxiedThumbnailURL(for: thumbnail)
        }

        let encodedPattern = #"https%3A%2F%2F[^"'\s,&<>]+\.(?:jpg|jpeg|png|webp)"#
        if let encoded = firstMatch(pattern: encodedPattern, in: html) {
            return encoded.removingPercentEncoding.flatMap(proxiedThumbnailURL)
        }

        return firstDirectImageURL(in: decodeHTMLEntities(html)).flatMap(proxiedThumbnailURL)
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

    private static func firstDirectImageURL(in html: String) -> String? {
        let directPattern = #"https://[^"'\s,&<>\]]+\.(?:jpg|jpeg|png|webp)(?:\?[^"'\s,&<>\]]*)?"#
        return firstMatch(pattern: directPattern, in: html)
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

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
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

            return FeedItem(
                id: "hqporner-\(id)",
                title: title,
                url: url,
                thumbnailURL: thumbnailURL(in: segment),
                uploadDate: now,
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
