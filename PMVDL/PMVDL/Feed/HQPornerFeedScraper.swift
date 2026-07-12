import Foundation

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
