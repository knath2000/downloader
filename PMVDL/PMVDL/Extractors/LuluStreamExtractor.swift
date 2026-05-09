import Foundation

/// Extracts video sources from luluvid / luluvdo / lulustream pages.
/// These sites wrap a packed JWPlayer config in their embed page. The packed JS
/// contains an HLS master playlist URL on the tnmr.org CDN that requires the
/// embed-page referer to fetch successfully.
struct LuluStreamExtractor: VideoSiteExtractor {
    private static let userAgent = NetworkConstants.chromeUserAgent

    private static let supportedDomains = [
        "luluvid.com", "luluvdo.com", "lulustream.com", "tnmr.org"
    ]

    static func supports(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return supportedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func extract(fromHTML _html: String, url: URL) async throws -> VideoSource {
        let filecode = try extractFilecode(from: url)
        let embedUrl = "https://luluvdo.com/e/\(filecode)"

        // (1) Fetch wrapper page for title
        let wrapperHtml = try await fetchPage(at: "https://luluvid.com/d/\(filecode)")
        var title = extractTitle(from: wrapperHtml) ?? "LuluStream Video"
        let thumbnail = extractThumbnail(from: wrapperHtml)

        // If wrapper failed to yield title, try embed page instead
        if title == "LuluStream Video" {
            let embedHtmlForTitle = try await fetchPage(at: embedUrl)
            title = extractTitle(from: embedHtmlForTitle) ?? title
        }

        // (2) Fetch embed page and find HLS
        let embedHtml = try await fetchPage(at: embedUrl)
        guard let hlsUrl = findHlsSource(embedHtml) else {
            throw LuluStreamError.noSourceFound(filecode: filecode)
        }

        // (3) Parse HLS manifest with the embed-page referer
        let headers = ["Referer": embedUrl, "User-Agent": userAgent]
        let variants = (try? await parseHlsVariants(from: hlsUrl, referer: embedUrl)) ?? []
        let hlsWithHeaders = variants.map {
            VideoSource.Quality(label: $0.label, url: $0.url, headers: headers, sourcePageUrl: embedUrl)
        }

        return VideoSource(
            mp4: nil,
            hls: hlsWithHeaders,
            title: title,
            thumbnail: thumbnail,
            siteName: "LuluStream"
        )
    }

    // MARK: - Page fetching

    private static func fetchPage(at urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { return "" }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://luluvid.com", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Metadata extraction

    private static func extractFilecode(from url: URL) throws -> String {
        let path = url.path
        let pattern = "/[dew]/([a-zA-Z0-9_-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range(at: 1), in: path) else {
            let components = path.split(separator: "/")
            guard let last = components.last, !last.isEmpty else {
                throw VideoExtractorError.invalidURL
            }
            return String(last).split(separator: ".").first.map { String($0) } ?? String(last)
        }
        return String(path[range])
    }

    private static func extractTitle(from html: String) -> String? {
        if let match = try? NSRegularExpression(
            pattern: "<title[^>]*>(.+?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators]
        ).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            let t = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    private static func extractThumbnail(from html: String) -> String? {
        let patterns = [
            #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#,
        ]
        for pattern in patterns {
            if let match = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                .firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                let range = Range(match.range(at: 1), in: html) {
                let u = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !u.isEmpty { return u }
            }
        }
        if let match = try? NSRegularExpression(pattern: #"poster=["']([^"']+)["']"#)
            .firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            let range = Range(match.range(at: 1), in: html) {
            return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }


    /// Find the HLS source URL from the embed page HTML.
    /// Tries unminified config first, then falls back to p.a.c.k.e.r decode.
    private static func findHlsSource(_ html: String) -> String? {
        // 1. Try unminified file: or sources: patterns
        if let url = findM3u8InText(html) { return url }

        // 2. Decode packed JS
        guard let packed = extractPackedBlock(html),
              let decoded = unpackPacker(packed),
              let url = findM3u8InText(decoded) else { return nil }
        return url
    }

#if DEBUG
    static func findHlsSourceForTesting(_ html: String) -> String? {
        findHlsSource(html)
    }
#endif

    /// Search any text for .m3u8 URLs in JS object patterns.
    private static func findM3u8InText(_ text: String) -> String? {
        let patterns = [
            #"file\s*:\s*['"](https?://[^'"]+\.m3u8[^'"]*)['"]"#,
            #"['"]file['"]\s*:\s*['"](https?://[^'"]+\.m3u8[^'"]*)['"]"#,
            #"['"](https?://[^'"]+\.m3u8[^'"]*)['"]"#,
        ]
        for pattern in patterns {
            if let match = try? NSRegularExpression(pattern: pattern)
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let range = Range(match.range(at: 1), in: text) {
                let u = String(text[range]).trimmingCharacters(in: .whitespaces)
                if !u.isEmpty && u.hasPrefix("http") { return u }
            }
        }
        return nil
    }

    // MARK: - URL refresh for download time

    /// Re-fetch the embed page and extract a fresh HLS URL.
    /// Called at download time to avoid stale signed URLs.
    static func refreshHlsUrl(from pageUrl: String, headers: [String: String]? = nil) async throws -> String? {
        guard let url = URL(string: pageUrl) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let headers = headers {
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        } else {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://luluvid.com", forHTTPHeaderField: "Referer")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { return nil }

        // Try unminified first, then packed decode
        if let hlsUrl = findM3u8InText(html) { return hlsUrl }
        guard let packed = extractPackedBlock(html),
              let decoded = unpackPacker(packed),
              let hlsUrl = findM3u8InText(decoded) else { return nil }
        return hlsUrl
    }

    // MARK: - p.a.c.k.e.r unpack

    /// Extract the full eval(function(p,a,c,k,e,d){...}) block from HTML.
    /// Uses balanced-parentheses scanning instead of regex to handle ) inside the function body.
    private static func extractPackedBlock(_ html: String) -> String? {
        // Find the start of eval(
        guard let startRange = html.range(of: "eval(") else { return nil }
        let evalOpen = startRange.lowerBound

        // Scan forward from after "eval(" to find matching closing )
        // Track nested parentheses
        var parenDepth = 1 // We're inside eval(
        let scanStart = html.index(evalOpen, offsetBy: "eval(".count)

        var currentIdx = scanStart
        while currentIdx < html.endIndex {
            let ch = html[currentIdx]
            if ch == "(" {
                parenDepth += 1
            } else if ch == ")" {
                parenDepth -= 1
                if parenDepth == 0 {
                    // Found the matching closing )
                    let endIdx = currentIdx
                    let block = String(html[scanStart..<endIdx])
                    return block
                }
            }
            currentIdx = html.index(after: currentIdx)
        }

        return nil
    }

    /// Unpack a Dean Edwards p.a.c.k.e.r. block.
    /// Input: the full content between eval( and matching ) — includes function def and arguments.
    private static func unpackPacker(_ packed: String) -> String? {
        let s = packed.trimmingCharacters(in: .whitespaces)

        // The format is: function(p,a,c,k,e,d){...}('payload','base',count,'dict'.split('|'),0,{})
        // Step 1: Find the end of the function definition by tracking braces
        guard let funcStart = s.range(of: "function") else { return nil }

        // Find the opening { after function(p,a,c,k,e,d)
        var braceDepth = 0
        var foundOpenBrace = false
        var searchIdx = funcStart.lowerBound

        while searchIdx < s.endIndex {
            if s[searchIdx] == "{" {
                if !foundOpenBrace {
                    foundOpenBrace = true
                }
                braceDepth += 1
            } else if s[searchIdx] == "}" {
                braceDepth -= 1
                if foundOpenBrace && braceDepth == 0 {
                    // Found the end of function body, now look for arguments
                    let afterFunc = s.index(after: searchIdx)

                    // Extract arguments: ('payload','base',count,'dict'.split('|'),0,{})
                    let argsStr = String(s[afterFunc...]).trimmingCharacters(in: .whitespaces)
                    return parsePackerArgs(argsStr)
                }
            }
            searchIdx = s.index(after: searchIdx)
        }

        return nil
    }

    /// Parse the arguments portion: ('payload','base',count,'dict'.split('|'),0,{})
    private static func parsePackerArgs(_ args: String) -> String? {
        // Find the opening (
        guard let openParen = args.firstIndex(of: "(") else { return nil }
        let afterOpen = args.index(after: openParen)

        // Find matching closing ) by tracking parentheses
        var parenDepth = 1
        var current = afterOpen
        var argsContent = ""

        while current < args.endIndex && parenDepth > 0 {
            if args[current] == "(" { parenDepth += 1 }
            else if args[current] == ")" { parenDepth -= 1 }
            if parenDepth > 0 { argsContent.append(args[current]) }
            current = args.index(after: current)
        }

        // Now parse: 'payload','base',count,'dict'.split('|')
        // Split by comma, but be careful with nested strings
        let parts = splitArgs(argsContent)

        guard parts.count == 4 else { return nil }

        let p = decodeEscapes(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "'")))
        let a = Int(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "'"))) ?? 36
        let c = Int(parts[2]) ?? 0

        // The 4th part is 'dict'.split('|') — extract the dict string
        let kPart = parts[3]
        let dictStr: String
        if kPart.contains(".split(") {
            // Extract the string before .split(
            if let quoteIdx = kPart.firstIndex(of: "'") ?? kPart.firstIndex(of: "\"") {
                let afterQuote = kPart.index(after: quoteIdx)
                if let endQuote = kPart[afterQuote...].firstIndex(of: kPart[kPart.startIndex]) {
                    dictStr = String(kPart[afterQuote..<endQuote])
                } else {
                    dictStr = kPart
                }
            } else {
                dictStr = kPart
            }
        } else {
            dictStr = kPart.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }

        guard let decoded = decode(p: p, a: a, c: c, k: dictStr),
              decoded.contains("jwplayer("),
              decoded.contains(".m3u8") else {
            return nil
        }

        return decoded
    }

    /// Split arguments by comma, respecting nested parentheses and escaped quotes.
    private static func splitArgs(_ str: String) -> [String] {
        var result: [String] = []
        var current = ""
        var parenDepth = 0
        var inQuote: Character? = nil
        var prevCh: Character? = nil

        for ch in str {
            if (ch == "'" || ch == "\"") && prevCh != "\\" {
                if inQuote == nil {
                    inQuote = ch
                } else if inQuote == ch {
                    inQuote = nil
                }
            } else if ch == "(" && inQuote == nil {
                parenDepth += 1
            } else if ch == ")" && inQuote == nil {
                parenDepth -= 1
            } else if ch == "," && parenDepth == 0 && inQuote == nil {
                result.append(current)
                current = ""
                prevCh = ch
                continue
            }
            current.append(ch)
            prevCh = ch
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Unescape \\' → ' and \\\ → \\
    private static func decodeEscapes(_ s: String) -> String {
        var result = s.replacingOccurrences(of: "\\n", with: "\n")
        result = result.replacingOccurrences(of: "\\t", with: "\t")
        result = result.replacingOccurrences(of: "\\'", with: "'")
        result = result.replacingOccurrences(of: "\\\\", with: "\\")
        return result
    }

    /// Core p.a.c.k.e.r. decode: replace base-N encoded words with dictionary values.
    private static func decode(p: String, a: Int, c: Int, k: String) -> String? {
        guard a >= 2 && a <= 62 else { return nil }
        let keys = k.components(separatedBy: "|")
        var words = p.components(separatedBy: " ")
        var result = ""

        for word in words {
            var decoded = word
            // Find all base-N numerals in the word
            let numPattern = "[0-9a-zA-Z]+"
            if let regex = try? NSRegularExpression(pattern: numPattern) {
                let matches = regex.matches(in: word, range: NSRange(word.startIndex..., in: word))
                // Process in reverse to avoid offset issues
                for match in matches.reversed() {
                    guard let numRange = Range(match.range, in: decoded) else { continue }
                    let numeral = String(decoded[numRange])
                    guard let value = Int(numeral, radix: a), value < keys.count, !keys[value].isEmpty else { continue }
                    decoded = decoded.replacingCharacters(in: numRange, with: keys[value])
                }
            }
            if !result.isEmpty { result += " " }
            result += decoded
        }

        return result
    }

    // MARK: - HLS variant parser

    private static func parseHlsVariants(from urlString: String, referer: String) async throws -> [VideoSource.Quality] {
        guard let url = URL(string: urlString) else {
            return [VideoSource.Quality(label: "HLS", url: urlString)]
        }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let playlist = String(data: data, encoding: .utf8) else {
            return [VideoSource.Quality(label: "HLS", url: urlString)]
        }

        var variants: [VideoSource.Quality] = []
        let lines = playlist.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }

        for (i, line) in lines.enumerated() {
            guard line.hasPrefix("#EXT-X-STREAM-INF") else { continue }
            guard i + 1 < lines.count else { continue }
            let variantLine = lines[i + 1]
            guard let variantUrl = URL(string: variantLine, relativeTo: url) else { continue }

            let label: String
            if let match = NSRegularExpression.firstNumberGroup(in: line, pattern: "RESOLUTION=\\d+x(\\d+)"),
               let height = Int(match) {
                label = heightToLabel(height)
            } else if let bw = NSRegularExpression.firstNumberGroup(in: line, pattern: "BANDWIDTH=(\\d+)"),
                      let bandwidth = Int(bw) {
                label = bandwidth > 4_000_000 ? "1080p" : bandwidth > 2_000_000 ? "720p" : "480p"
            } else {
                label = "HLS"
            }
            variants.append(VideoSource.Quality(label: label, url: variantUrl.absoluteString))
        }

        return variants.isEmpty ? [VideoSource.Quality(label: "HLS", url: urlString)] : variants
    }

    private static func heightToLabel(_ h: Int) -> String {
        switch h {
        case 2160...: return "2160p"
        case 1440...: return "1440p"
        case 1080...: return "1080p"
        case 720...: return "720p"
        case 480...: return "480p"
        case 360...: return "360p"
        default: return "\(h)p"
        }
    }
}

enum LuluStreamError: LocalizedError {
    case noSourceFound(filecode: String)
    case decodeError(filecode: String, reason: String)
    var errorDescription: String? {
        switch self {
        case .noSourceFound(let filecode):
            return "LuluStream could not find a video source for '\(filecode)'. The video may have expired or been deleted."
        case .decodeError(let filecode, let reason):
            return "LuluStream could not decode the packed player for '\(filecode)'. \(reason)"
        }
    }
}
