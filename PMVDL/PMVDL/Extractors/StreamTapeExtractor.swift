import Foundation

/// Extracts video sources from streamtape.com / streamtape.net.
struct StreamTapeExtractor: VideoSiteExtractor {
    typealias StreamTapeRedirectResolver = (String, URL) async throws -> String?

    private struct StreamTapeCandidate: Hashable {
        let url: String
        let source: String
        let priority: Int
        let requiresRedirect: Bool
    }

    private static let streamTapeLinkIDs: [String] = [
        "captchalink",
        "norobotlink",
        "botlink",
        "robotlink",
        "ideoolink",
        "ideoooolink"
    ]

    private static let streamTapeLinkIDSet = Set(streamTapeLinkIDs)

    static func supports(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "streamtape.com" || host == "streamtape.net"
            || host.hasSuffix(".streamtape.com") || host.hasSuffix(".streamtape.net")
    }

    static func extract(fromHTML html: String, url: URL) async throws -> VideoSource {
        try await extract(
            fromHTML: html,
            url: url,
            redirectResolver: resolveStreamTapeRedirect
        )
    }

    static func extract(
        fromHTML html: String,
        url: URL,
        redirectResolver: StreamTapeRedirectResolver
    ) async throws -> VideoSource {
        let pageHtml = html.isEmpty ? try await fetchPage(url: url) : html

        let title = extractTitle(from: pageHtml) ?? "StreamTape Video"
        let thumbnail = extractThumbnail(from: pageHtml)
        let candidates = findVideoUrlCandidates(in: pageHtml, pageURL: url)

        var finalVideoUrl: String?
        for candidate in candidates {
            if candidate.requiresRedirect {
                do {
                    if let resolved = try await redirectResolver(candidate.url, url),
                       !resolved.isEmpty,
                       let resolvedURL = URL(string: resolved),
                       isTapeContentURL(resolvedURL) {
                        finalVideoUrl = resolved
                        break
                    }
                } catch {
                    continue
                }
            } else {
                finalVideoUrl = candidate.url
                break
            }
        }

        guard let videoUrl = finalVideoUrl else {
            throw StreamTapeError.noVideoSource
        }

        let headers = [
            "User-Agent": NetworkConstants.chromeUserAgent,
            "Referer": url.absoluteString
        ]

        let quality = VideoSource.Quality(
            label: "Video",
            url: videoUrl,
            kind: .direct,
            headers: headers,
            sourcePageUrl: url.absoluteString
        )

        return VideoSource(
            mp4: videoUrl,
            hls: [quality],
            title: title,
            thumbnail: thumbnail,
            siteName: "StreamTape",
            headers: headers
        )
    }

    // MARK: - Page Fetching

    private static func fetchPage(url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://streamtape.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw StreamTapeError.networkError
        }
        return html
    }

    // MARK: - Metadata

    private static func extractTitle(from html: String) -> String? {
        if let match = try? NSRegularExpression(
            pattern: #"<title[^>]*>(.+?)</title>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let range = Range(match.range(at: 1), in: html) {
            let t = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !t.hasPrefix("404") { return t }
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
        return nil
    }

    // MARK: - Video URL extraction

    private static func findVideoUrlCandidates(in html: String, pageURL: URL, includePacked: Bool = true) -> [StreamTapeCandidate] {
        var candidates: [StreamTapeCandidate] = []

        candidates.append(contentsOf: extractDirectConfigCandidates(in: html, pageURL: pageURL))
        candidates.append(contentsOf: extractAssignedGetVideoCandidates(in: html, pageURL: pageURL))
        candidates.append(contentsOf: extractHiddenGetVideoCandidates(in: html, pageURL: pageURL))
        candidates.append(contentsOf: extractVideoUrlVariableCandidates(in: html, pageURL: pageURL))

        if includePacked,
           let packed = extractPackedBlock(html),
           let decoded = unpackPacker(packed) {
            candidates.append(contentsOf: findVideoUrlCandidates(in: decoded, pageURL: pageURL, includePacked: false))
        }

        return dedupeAndSort(candidates)
    }

    private static func extractDirectConfigCandidates(in html: String, pageURL: URL) -> [StreamTapeCandidate] {
        var candidates: [StreamTapeCandidate] = []
        let patterns = [
            #"sources\s*:\s*\[\{file\s*:\s*['"]([^'"]+)['"]"#,
            #"data-src\s*=\s*['"]([^'"]+)['"]"#
        ]

        for (index, pattern) in patterns.enumerated() {
            for raw in extractJsStringValues(pattern: pattern, in: html) {
                if let normalized = normalizeStreamTapeUrl(raw, pageURL: pageURL) {
                    candidates.append(candidate(
                        url: normalized,
                        source: "direct:\(index)",
                        priority: index,
                        fallbackRequiresRedirect: false
                    ))
                }
            }
        }

        return candidates
    }

    private static func extractAssignedGetVideoCandidates(in html: String, pageURL: URL) -> [StreamTapeCandidate] {
        let pattern = #"document\.getElementById\(\s*['"]([^'"]+)['"]\s*\)\.innerHTML\s*=\s*(.*?);"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var candidates: [StreamTapeCandidate] = []

        for (matchIndex, match) in matches.enumerated() {
            guard let idRange = Range(match.range(at: 1), in: html),
                  let expressionRange = Range(match.range(at: 2), in: html) else {
                continue
            }

            let id = String(html[idRange]).lowercased()
            let expression = String(html[expressionRange])
            guard streamTapeLinkIDSet.contains(id) || expression.contains("get_video") else {
                continue
            }

            guard let raw = evaluateStreamTapeStringExpression(expression),
                  let normalized = normalizeStreamTapeUrl(raw, pageURL: pageURL) else {
                continue
            }

            candidates.append(candidate(
                url: normalized,
                source: "assigned:\(id)",
                priority: 50 + idPriority(id) * 10 + matchIndex,
                fallbackRequiresRedirect: true
            ))
        }

        return candidates
    }

    private static func extractHiddenGetVideoCandidates(in html: String, pageURL: URL) -> [StreamTapeCandidate] {
        var candidates: [StreamTapeCandidate] = []

        for (index, id) in streamTapeLinkIDs.enumerated() {
            let escaped = NSRegularExpression.escapedPattern(for: id)
            let pattern = #"id\s*=\s*['"]\#(escaped)['"][^>]*>(.*?)<"#

            for raw in extractJsStringValues(pattern: pattern, in: html, options: [.dotMatchesLineSeparators]) {
                if let normalized = normalizeStreamTapeUrl(raw, pageURL: pageURL) {
                    candidates.append(candidate(
                        url: normalized,
                        source: "hidden:\(id)",
                        priority: 200 + index,
                        fallbackRequiresRedirect: true
                    ))
                }
            }
        }

        return candidates
    }

    private static func extractVideoUrlVariableCandidates(in html: String, pageURL: URL) -> [StreamTapeCandidate] {
        let pattern = #"video_url\s*[=:]\s*['"]([^'"]+)['"]"#
        return extractJsStringValues(pattern: pattern, in: html).enumerated().compactMap { index, raw in
            guard let normalized = normalizeStreamTapeUrl(raw, pageURL: pageURL) else { return nil }
            return candidate(
                url: normalized,
                source: "video_url",
                priority: 300 + index,
                fallbackRequiresRedirect: false
            )
        }
    }

    private static func candidate(url: String, source: String, priority: Int, fallbackRequiresRedirect: Bool) -> StreamTapeCandidate {
        StreamTapeCandidate(
            url: url,
            source: source,
            priority: priority,
            requiresRedirect: isStreamTapeGetVideoURL(url) || fallbackRequiresRedirect && !isTapeContentURLString(url)
        )
    }

    private static func dedupeAndSort(_ candidates: [StreamTapeCandidate]) -> [StreamTapeCandidate] {
        var seen = Set<String>()
        var result: [StreamTapeCandidate] = []

        for candidate in candidates.sorted(by: { lhs, rhs in
            if lhs.priority == rhs.priority {
                return lhs.source < rhs.source
            }
            return lhs.priority < rhs.priority
        }) {
            if seen.insert(candidate.url).inserted {
                result.append(candidate)
            }
        }

        return result
    }

    // MARK: - StreamTape JavaScript string evaluation

    private static func evaluateStreamTapeStringExpression(_ expression: String) -> String? {
        let parts = splitTopLevelPlus(expression)
        guard !parts.isEmpty else { return nil }

        var result = ""
        for part in parts {
            guard let value = evaluateStreamTapeStringTerm(part) else {
                return nil
            }
            result += value
        }
        return result
    }

    private static func splitTopLevelPlus(_ expression: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var escape = false
        var depth = 0

        for ch in expression {
            if escape {
                current.append(ch)
                escape = false
                continue
            }

            if ch == "\\" {
                current.append(ch)
                if quote != nil {
                    escape = true
                }
                continue
            }

            if ch == "'" || ch == "\"" {
                if quote == nil {
                    quote = ch
                } else if quote == ch {
                    quote = nil
                }
                current.append(ch)
                continue
            }

            if quote == nil {
                if ch == "(" {
                    depth += 1
                } else if ch == ")" {
                    depth = max(0, depth - 1)
                } else if ch == "+", depth == 0 {
                    parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                    continue
                }
            }

            current.append(ch)
        }

        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty || !parts.isEmpty {
            parts.append(tail)
        }
        return parts
    }

    private static func evaluateStreamTapeStringTerm(_ term: String) -> String? {
        let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var index = text.startIndex
        skipWhitespace(in: text, index: &index)

        var wrapped = false
        if index < text.endIndex, text[index] == "(" {
            wrapped = true
            index = text.index(after: index)
            skipWhitespace(in: text, index: &index)
        }

        guard index < text.endIndex, text[index] == "'" || text[index] == "\"" else {
            return nil
        }

        let quote = text[index]
        index = text.index(after: index)

        var value = ""
        var escape = false
        while index < text.endIndex {
            let ch = text[index]
            index = text.index(after: index)

            if escape {
                value.append(decodedEscapedCharacter(ch))
                escape = false
                continue
            }
            if ch == "\\" {
                escape = true
                continue
            }
            if ch == quote {
                break
            }
            value.append(ch)
        }

        skipWhitespace(in: text, index: &index)
        if wrapped {
            guard index < text.endIndex, text[index] == ")" else { return nil }
            index = text.index(after: index)
        }

        while true {
            skipWhitespace(in: text, index: &index)
            guard index < text.endIndex else { return value }
            guard text[index...].hasPrefix(".substring(") else { return nil }
            index = text.index(index, offsetBy: ".substring(".count)
            skipWhitespace(in: text, index: &index)

            guard let start = parseInteger(in: text, index: &index) else { return nil }
            skipWhitespace(in: text, index: &index)

            var end: Int?
            if index < text.endIndex, text[index] == "," {
                index = text.index(after: index)
                skipWhitespace(in: text, index: &index)
                end = parseInteger(in: text, index: &index)
                skipWhitespace(in: text, index: &index)
            }

            guard index < text.endIndex, text[index] == ")" else { return nil }
            index = text.index(after: index)
            value = substring(value, from: start, to: end)
        }
    }

    private static func skipWhitespace(in text: String, index: inout String.Index) {
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
    }

    private static func parseInteger(in text: String, index: inout String.Index) -> Int? {
        let start = index
        while index < text.endIndex, text[index].isNumber {
            index = text.index(after: index)
        }
        guard start < index else { return nil }
        return Int(text[start..<index])
    }

    private static func substring(_ value: String, from start: Int, to end: Int?) -> String {
        let chars = Array(value)
        guard start < chars.count else { return "" }
        let boundedEnd = min(end ?? chars.count, chars.count)
        guard start < boundedEnd else { return "" }
        return String(chars[start..<boundedEnd])
    }

    private static func decodedEscapedCharacter(_ ch: Character) -> Character {
        switch ch {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        default: return ch
        }
    }

    // MARK: - URL normalization and redirects

    private static func normalizeStreamTapeUrl(_ raw: String, pageURL: URL) -> String? {
        let trimmed = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return nil }

        let normalized: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            normalized = trimmed
        } else if trimmed.hasPrefix("//") {
            normalized = "https:" + trimmed
        } else if trimmed.hasPrefix("/streamtape.com/") || trimmed.hasPrefix("/streamtape.net/") {
            normalized = "https:/" + trimmed
        } else if trimmed.hasPrefix("streamtape.com/") || trimmed.hasPrefix("streamtape.net/") {
            normalized = "https://" + trimmed
        } else if trimmed.hasPrefix("/get_video") {
            let host = pageURL.host ?? "streamtape.com"
            normalized = "https://\(host)" + trimmed
        } else if trimmed.hasPrefix("get_video") {
            let host = pageURL.host ?? "streamtape.com"
            normalized = "https://\(host)/" + trimmed
        } else if trimmed.hasPrefix("/") {
            return nil
        } else if let resolved = URL(string: trimmed, relativeTo: pageURL)?.absoluteURL.absoluteString {
            normalized = resolved
        } else {
            return nil
        }

        guard isUsableStreamTapeCandidate(normalized) else {
            return nil
        }

        return normalized
    }

    private static func isUsableStreamTapeCandidate(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else {
            return false
        }

        if isStreamTapeHost(host) {
            return url.path.contains("get_video")
        }

        if host == "tapecontent.net" || host.hasSuffix(".tapecontent.net") {
            return true
        }

        return false
    }

    private static func isStreamTapeGetVideoURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else {
            return false
        }
        return isStreamTapeHost(host) && url.path.contains("get_video")
    }

    private static func isStreamTapeHost(_ host: String) -> Bool {
        host == "streamtape.com" || host == "streamtape.net"
            || host.hasSuffix(".streamtape.com") || host.hasSuffix(".streamtape.net")
    }

    private static func isTapeContentURLString(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return isTapeContentURL(url)
    }

    private static func isTapeContentURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "tapecontent.net" || host.hasSuffix(".tapecontent.net")
    }

    private static func resolveStreamTapeRedirect(_ candidateUrl: String, referer: URL) async throws -> String? {
        guard let candidate = URL(string: candidateUrl),
              let host = candidate.host?.lowercased() else {
            return nil
        }

        if isTapeContentURL(candidate) {
            return candidateUrl
        }

        guard isStreamTapeHost(host), candidate.path.contains("get_video") else {
            return nil
        }

        if let resolved = try? await resolveStreamTapeRedirectOnce(
            candidate,
            referer: referer,
            method: "HEAD",
            range: nil
        ) {
            return resolved
        }

        return try await resolveStreamTapeRedirectOnce(
            candidate,
            referer: referer,
            method: "GET",
            range: "bytes=0-0"
        )
    }

    private static func resolveStreamTapeRedirectOnce(
        _ candidate: URL,
        referer: URL,
        method: String,
        range: String?
    ) async throws -> String? {
        let delegate = RedirectCaptureDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: candidate)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        if let range {
            request.setValue(range, forHTTPHeaderField: "Range")
        }

        let (_, response) = try await session.data(for: request)
        let locationURL = delegate.redirectURL ?? (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Location")
            .flatMap { URL(string: $0, relativeTo: candidate) }

        guard let locationURL else {
            if let responseURL = response.url,
               isTapeContentURL(responseURL) {
                return responseURL.absoluteString
            }
            return nil
        }

        let absolute = locationURL.absoluteURL
        guard isTapeContentURL(absolute) else {
            return nil
        }

        return absolute.absoluteString
    }

    // MARK: - Helpers

    private static func extractJsStringValues(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }

        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func extractPackedBlock(_ html: String) -> String? {
        guard let startRange = html.range(of: "eval(") else { return nil }
        let evalOpen = startRange.lowerBound
        var parenDepth = 1
        let scanStart = html.index(evalOpen, offsetBy: "eval(".count)

        var currentIdx = scanStart
        while currentIdx < html.endIndex {
            let ch = html[currentIdx]
            if ch == "(" { parenDepth += 1 }
            else if ch == ")" {
                parenDepth -= 1
                if parenDepth == 0 {
                    return String(html[scanStart..<currentIdx])
                }
            }
            currentIdx = html.index(after: currentIdx)
        }
        return nil
    }

    private static func unpackPacker(_ packed: String) -> String? {
        let s = packed.trimmingCharacters(in: .whitespaces)
        guard let funcStart = s.range(of: "function") else { return nil }

        var braceDepth = 0
        var foundOpenBrace = false
        var searchIdx = funcStart.lowerBound

        while searchIdx < s.endIndex {
            if s[searchIdx] == "{" {
                if !foundOpenBrace { foundOpenBrace = true }
                braceDepth += 1
            } else if s[searchIdx] == "}" {
                braceDepth -= 1
                if foundOpenBrace && braceDepth == 0 {
                    let afterFunc = s.index(after: searchIdx)
                    return parsePackerArgs(String(s[afterFunc...]))
                }
            }
            searchIdx = s.index(after: searchIdx)
        }
        return nil
    }

    private static func parsePackerArgs(_ args: String) -> String? {
        guard let openParen = args.firstIndex(of: "(") else { return nil }
        let afterOpen = args.index(after: openParen)

        var parenDepth = 1
        var current = afterOpen
        var argsContent = ""

        while current < args.endIndex && parenDepth > 0 {
            if args[current] == "(" { parenDepth += 1 }
            else if args[current] == ")" { parenDepth -= 1 }
            if parenDepth > 0 { argsContent.append(args[current]) }
            current = args.index(after: current)
        }

        let parts = splitArgs(argsContent)
        guard parts.count >= 4 else { return nil }

        let p = decodeEscapes(parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "'")))
        let a = Int(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "'"))) ?? 36
        let c = Int(parts[2]) ?? 0

        let kPart = parts[3]
        var dictStr = kPart.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        if kPart.contains(".split(") {
            if let q1 = kPart.firstIndex(of: "'"),
               let q2 = kPart[kPart.index(after: q1)...].firstIndex(of: "'") {
                dictStr = String(kPart[kPart.index(after: q1)..<q2])
            }
        }

        return decode(p: p, a: a, c: c, k: dictStr)
    }

    private static func splitArgs(_ str: String) -> [String] {
        var result: [String] = []
        var current = ""
        var parenDepth = 0
        var inQuote: Character? = nil
        var prevCh: Character? = nil

        for ch in str {
            if (ch == "'" || ch == "\"") && prevCh != "\\" {
                if inQuote == nil { inQuote = ch }
                else if inQuote == ch { inQuote = nil }
            } else if ch == "(" && inQuote == nil { parenDepth += 1 }
            else if ch == ")" && inQuote == nil { parenDepth -= 1 }
            else if ch == "," && parenDepth == 0 && inQuote == nil {
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

    private static func decodeEscapes(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\'", with: "'")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func decode(p: String, a: Int, c: Int, k: String) -> String? {
        guard a >= 2 && a <= 62 else { return nil }
        let keys = k.components(separatedBy: "|")
        let words = p.components(separatedBy: " ")
        var result = ""

        for word in words {
            var decoded = word
            let numPattern = "[0-9a-zA-Z]+"
            if let regex = try? NSRegularExpression(pattern: numPattern) {
                let matches = regex.matches(in: word, range: NSRange(word.startIndex..., in: word))
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

    private static func idPriority(_ id: String) -> Int {
        streamTapeLinkIDs.firstIndex(of: id) ?? streamTapeLinkIDs.count
    }
}

private final class RedirectCaptureDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _redirectURL: URL?

    var redirectURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _redirectURL
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        _redirectURL = request.url
        lock.unlock()
        completionHandler(nil)
    }
}

enum StreamTapeError: LocalizedError {
    case noVideoSource
    case networkError

    var errorDescription: String? {
        switch self {
        case .noVideoSource:
            return "StreamTape could not extract a video source. The video may have expired or been removed."
        case .networkError:
            return "Failed to fetch the StreamTape page."
        }
    }
}
