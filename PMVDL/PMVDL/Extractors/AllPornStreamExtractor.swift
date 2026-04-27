import Foundation

/// Extracts provider links from allpornstream.com pages.
/// The page stores provider metadata in a Next.js RSC payload under `video_urls`.
struct AllPornStreamExtractor: VideoSiteExtractor {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

    static func supports(_ url: URL) -> Bool {
        url.host()?.lowercased().contains("allpornstream.com") ?? false
    }

    static func extract(fromHTML html: String, url: URL) async throws -> VideoSource {
        let pageHtml = html.isEmpty ? try await fetchPage(url: url) : html

        let title = extractTitle(from: pageHtml)
        let thumbnail = extractThumbnail(from: pageHtml)
        let entries = parseVideoUrls(from: pageHtml)

        guard !entries.isEmpty else {
            throw PMVDLError.noVideoSources
        }

        let qualities = deduplicate(entries).map { entry in
            var label = entry.providerName.uppercased()
            label += entry.isIframeFallback ? " · embed" : " · watch"
            return VideoSource.Quality(
                label: label,
                url: entry.url,
                kind: .pageUrl,
                sourcePageUrl: entry.sourcePageUrl ?? url.absoluteString
            )
        }

        return VideoSource(
            mp4: nil,
            hls: qualities,
            title: title,
            thumbnail: thumbnail,
            siteName: "AllPornStream"
        )
    }

    // MARK: - Main parsing

    private static func parseVideoUrls(from html: String) -> [ProviderEntry] {
        var entries: [ProviderEntry] = []

        for payload in extractNextFPushStrings(from: html) {
            let decoded = decodeEscapedJsonString(payload)

            // Find "video_urls":{ in the decoded string
            guard let vuRange = decoded.range(of: "\"video_urls\":") else {
                continue
            }

            // Find the { after video_urls":
            guard let bracePos = decoded[vuRange.lowerBound...].firstIndex(of: "{") else {
                continue
            }

            guard let videoUrlsObject = extractObject(from: decoded, start: bracePos) else {
                continue
            }

            entries.append(contentsOf: parseVideoUrlsObject(videoUrlsObject))
        }

        return entries
    }

    private static func extractNextFPushStrings(from html: String) -> [String] {
        var results: [String] = []
        let pattern = #"__next_f\.push\(\[\d+,\""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return results }

        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))

        for match in matches {
            let matchRange = match.range
            // The match includes "__next_f.push([digits,\"", so the opening quote is at matchRange.location + matchRange.length - 1
            let quoteLoc = matchRange.location + matchRange.length - 1
            guard quoteLoc < ns.length, ns.character(at: quoteLoc) == 34 else { continue }

            // Find the closing quote
            var escape = false
            var i = quoteLoc + 1
            var closingQuote: Int?

            while i < ns.length {
                let ch = ns.character(at: i)
                if escape {
                    escape = false
                    i += 1
                    continue
                }
                if ch == 92 { // backslash
                    escape = true
                    i += 1
                    continue
                }
                if ch == 34 { // quote
                    // Check if this is the closing quote: next non-whitespace should be ]
                    var j = i + 1
                    while j < ns.length {
                        let c = ns.character(at: j)
                        if c == 32 || c == 9 || c == 10 || c == 13 {
                            j += 1
                            continue
                        }
                        break
                    }
                    if j < ns.length && ns.character(at: j) == 93 { // ]
                        closingQuote = i
                        break
                    }
                }
                i += 1
            }

            guard let endQuote = closingQuote else { continue }
            let extracted = ns.substring(with: NSRange(location: quoteLoc + 1, length: endQuote - quoteLoc - 1))
            results.append(extracted)
        }

        return results
    }

    // MARK: - JSON Parsing

    private struct ProviderEntry {
        let providerName: String
        let url: String
        let isIframeFallback: Bool
        let sourcePageUrl: String?
    }

    private static func parseVideoUrlsObject(_ object: String) -> [ProviderEntry] {
        var entries: [ProviderEntry] = []
        var iframeByProvider: [String: String] = [:]

        // Parse "iframe" array
        if let iframeItems = findJsonArrayItems(for: "iframe", in: object) {
            for item in iframeItems {
                if let entry = parseIframeObject(item) {
                    iframeByProvider[entry.providerName.lowercased()] = entry.url
                    entries.append(entry)
                }
            }
        }

        // Parse "link" array
        if let linkArrayStart = findJsonRawArray(for: "link", in: object) {
            if let items = extractArrayItems(from: object, start: linkArrayStart) {
                for item in items {
                    if let entry = parseLinkTuple(item, iframeByProvider: iframeByProvider) {
                        entries.append(entry)
                    }
                }
            }
        }

        return entries
    }

    private static func parseLinkTuple(_ item: String, iframeByProvider: [String: String]) -> ProviderEntry? {
        let values = extractJsonStringValues(from: item)
        guard values.count >= 2 else { return nil }

        let provider = values[0]
        let url = values[1]
        guard !provider.isEmpty, !url.isEmpty else { return nil }

        return ProviderEntry(
            providerName: provider,
            url: url,
            isIframeFallback: false,
            sourcePageUrl: iframeByProvider[provider.lowercased()]
        )
    }

    private static func parseIframeObject(_ item: String) -> ProviderEntry? {
        guard let provider = findJsonStringValue(for: "hosting_provider", in: item),
              let url = findJsonStringValue(for: "embed_url", in: item) ?? findJsonStringValue(for: "url", in: item),
              let statusCode = findJsonNumberValue(for: "status_code", in: item),
              statusCode == 200 else {
            return nil
        }

        return ProviderEntry(providerName: provider, url: url, isIframeFallback: true, sourcePageUrl: nil)
    }

    // MARK: - JSON Helpers

    private static func findJsonArrayItems(for key: String, in text: String) -> [String]? {
        guard let start = findJsonRawArray(for: key, in: text) else { return nil }
        return extractArrayItems(from: text, start: start)
    }

    private static func findJsonRawArray(for key: String, in text: String) -> String.Index? {
        let pattern = #""# + key + #""\s*:\s*\["#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }

        let bracketOffset = match.range.location + match.range.length - 1
        return text.index(text.startIndex, offsetBy: bracketOffset)
    }

    private static func extractArrayItems(from text: String, start: String.Index) -> [String]? {
        guard start < text.endIndex, text[start] == "[" else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        var i = start

        while i < text.endIndex {
            let ch = text[i]

            if escape {
                escape = false
                i = text.index(after: i)
                continue
            }
            if ch == "\\" && inString {
                escape = true
                i = text.index(after: i)
                continue
            }
            if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "[" || ch == "{" {
                    depth += 1
                } else if ch == "]" || ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        let content = String(text[text.index(after: start)..<i])
                        return splitTopLevelArrayItems(content)
                    }
                }
            }
            i = text.index(after: i)
        }

        return nil
    }

    private static func splitTopLevelArrayItems(_ content: String) -> [String] {
        var items: [String] = []
        var depth = 0
        var inString = false
        var escape = false
        var currentStart: String.Index?
        var i = content.startIndex

        while i < content.endIndex {
            let ch = content[i]

            if escape {
                escape = false
                i = content.index(after: i)
                continue
            }
            if ch == "\\" && inString {
                escape = true
                i = content.index(after: i)
                continue
            }
            if ch == "\"" {
                inString.toggle()
                if currentStart == nil {
                    currentStart = i
                }
            } else if !inString {
                if ch == "[" || ch == "{" {
                    if currentStart == nil, !ch.isWhitespace {
                        currentStart = i
                    }
                    depth += 1
                } else if ch == "]" || ch == "}" {
                    depth -= 1
                    if depth == 0, let start = currentStart {
                        let item = String(content[start...i]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !item.isEmpty { items.append(item) }
                        currentStart = nil
                    }
                } else if ch == "," && depth == 0 {
                    if let start = currentStart {
                        let item = String(content[start..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !item.isEmpty { items.append(item) }
                        currentStart = nil
                    }
                } else if currentStart == nil, !ch.isWhitespace {
                    currentStart = i
                }
            }

            i = content.index(after: i)
        }

        if let start = currentStart {
            let item = String(content[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !item.isEmpty { items.append(item) }
        }

        return items
    }

    private static func extractJsonStringValues(from text: String) -> [String] {
        var values: [String] = []
        var inString = false
        var escape = false
        var currentStart: String.Index?
        var i = text.startIndex

        while i < text.endIndex {
            let ch = text[i]

            if escape {
                escape = false
                i = text.index(after: i)
                continue
            }
            if ch == "\\" && inString {
                escape = true
                i = text.index(after: i)
                continue
            }
            if ch == "\"" {
                if inString, let start = currentStart {
                    values.append(decodeEscapedJsonString(String(text[start..<i])))
                    currentStart = nil
                } else {
                    currentStart = text.index(after: i)
                }
                inString.toggle()
            }
            i = text.index(after: i)
        }

        return values
    }

    private static func findJsonStringValue(for key: String, in text: String) -> String? {
        let pattern = #""# + key + #""\s*:\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range.location + match.range.length < text.utf16.count else {
            return nil
        }

        let valueStart = text.index(text.startIndex, offsetBy: match.range.location + match.range.length)
        guard valueStart < text.endIndex, text[valueStart] == "\"" else { return nil }

        let fromStart = String(text[valueStart...])
        return extractJsonStringValue(from: fromStart)
    }

    private static func findJsonNumberValue(for key: String, in text: String) -> Int? {
        let pattern = #""# + key + #""\s*:\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return Int(text[range])
    }

    private static func extractJsonStringValue(from text: String) -> String? {
        guard text.first == "\"" else { return nil }

        var escape = false
        var i = text.index(after: text.startIndex)

        while i < text.endIndex {
            let ch = text[i]

            if escape {
                escape = false
                i = text.index(after: i)
                continue
            }
            if ch == "\\" {
                escape = true
                i = text.index(after: i)
                continue
            }
            if ch == "\"" {
                let endIdx = i
                let contentStart = text.index(after: text.startIndex)
                return String(text[contentStart..<endIdx])
            }
            i = text.index(after: i)
        }

        return nil
    }

    private static func extractObject(from text: String, start: String.Index) -> String? {
        guard start < text.endIndex, text[start] == "{" else { return nil }

        var depth = 0
        var inString = false
        var escape = false
        var i = start

        while i < text.endIndex {
            let ch = text[i]

            if escape {
                escape = false
                i = text.index(after: i)
                continue
            }
            if ch == "\\" && inString {
                escape = true
                i = text.index(after: i)
                continue
            }
            if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...i])
                    }
                }
            }
            i = text.index(after: i)
        }

        return nil
    }

    private static func decodeEscapedJsonString(_ s: String) -> String {
        var result = ""
        var escape = false
        var i = s.startIndex

        while i < s.endIndex {
            let ch = s[i]

            if escape {
                switch ch {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "u":
                    let nextIdx = s.index(i, offsetBy: 1)
                    if let codePoint = s.extractUnicodeHex(at: nextIdx) {
                        result.append(codePoint)
                    } else {
                        result.append("\\u")
                    }
                default:
                    result.append(ch)
                }
                escape = false
                i = s.index(after: i)
                continue
            }

            if ch == "\\" {
                escape = true
                i = s.index(after: i)
                continue
            }

            result.append(ch)
            i = s.index(after: i)
        }

        return result
    }

    private static func deduplicate(_ entries: [ProviderEntry]) -> [ProviderEntry] {
        var seen = Set<String>()
        var result: [ProviderEntry] = []

        for entry in entries {
            let key = "\(entry.providerName)|\(entry.url)|\(entry.isIframeFallback ? "embed" : "watch")"
            if seen.insert(key).inserted {
                result.append(entry)
            }
        }

        return result
    }

    // MARK: - Metadata Extraction

    private static func extractTitle(from html: String) -> String? {
        if let match = try? NSRegularExpression(
            pattern: #"og:["']title["'][^>]+content=["']([^"']+)["']"#
        ).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let match = try? NSRegularExpression(
            pattern: "<title[^>]*>(.+?)</title>",
            options: [.caseInsensitive]
        ).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            let value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !value.hasPrefix("404") {
                return value
            }
        }

        return nil
    }

    private static func extractThumbnail(from html: String) -> String? {
        if let match = try? NSRegularExpression(
            pattern: #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            options: .caseInsensitive
        ).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return findJsonStringValue(for: "video_single_image", in: html)
    }

    // MARK: - Page Fetching

    private static func fetchPage(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw PMVDLError.network(
                NSError(domain: "PMVDL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch allpornstream.com page"])
            )
        }
        return html
    }
}

private extension String {
    func extractUnicodeHex(at index: Index) -> String? {
        let hexEnd = self.index(index, offsetBy: 4, limitedBy: endIndex) ?? endIndex
        let hexStr = String(self[index..<hexEnd])
        guard let codePoint = UInt32(hexStr, radix: 16),
              let scalar = UnicodeScalar(codePoint) else { return nil }
        return String(scalar)
    }
}
