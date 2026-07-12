import Foundation

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
