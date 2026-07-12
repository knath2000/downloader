import Foundation

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
