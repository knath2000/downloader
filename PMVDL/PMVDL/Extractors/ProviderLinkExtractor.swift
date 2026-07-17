import Foundation

/// Extracts provider links from allpornstream.com pages.
/// The page stores provider metadata in a Next.js RSC payload under `video_urls`.
struct ProviderLinkExtractor: VideoSiteExtractor {

    static func supports(_ url: URL) -> Bool {
        url.host()?.lowercased().contains("allpornstream.com") ?? false
    }

    static func extract(fromHTML html: String, url: URL) async throws -> VideoSource {
        let pageHtml = html.isEmpty ? try await fetchPage(url: url) : html

        let title = extractTitle(from: pageHtml)
        let thumbnail = extractThumbnail(from: pageHtml)
        let entries = parseVideoUrls(from: pageHtml)

        guard !entries.isEmpty else {
            throw VideoExtractorError.noVideoSources
        }

        let candidates = providerCandidates(from: entries, pageURL: url)
        let qualities = await resolveProviderCandidates(candidates)

        guard !qualities.isEmpty else {
            throw VideoExtractorError.noVideoSources
        }

        return VideoSource(
            mp4: nil,
            hls: qualities,
            title: title,
            thumbnail: thumbnail,
            siteName: "ProviderLink"
        )
    }

    // MARK: - Main parsing

    private static func parseVideoUrls(from html: String) -> [ProviderEntry] {
        var entries: [ProviderEntry] = []
        var decodedPayloads: [String] = []

        for payload in extractNextFPushStrings(from: html) {
            let decoded = decodeEscapedJsonString(payload)
            decodedPayloads.append(decoded)

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

        if entries.isEmpty {
            entries.append(contentsOf: parseInlineVideoUrls(from: html))
        }

        return entries
    }

    private static func parseInlineVideoUrls(from html: String) -> [ProviderEntry] {
        guard let videoUrlsRange = html.range(of: #""video_urls"\s*:"#, options: .regularExpression),
              let bracePos = html[videoUrlsRange.upperBound...].firstIndex(of: "{"),
              let videoUrlsObject = extractObject(from: html, start: bracePos) else {
            return []
        }
        return parseVideoUrlsObject(videoUrlsObject)
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
        let fileCode: String?
    }

    private struct ProviderCandidate {
        let providerName: String
        let selectedUrl: String
        let watchUrl: String?
        let embedUrl: String?
        let fileCode: String?
        let sourcePageUrl: String
    }

    private typealias ProviderResolver = (String) async throws -> VideoSource

    struct ProviderCandidateForTesting: Equatable {
        let providerName: String
        let url: String
    }

    static func providerCandidatesForTesting(from html: String) -> [ProviderCandidateForTesting] {
        let entries = parseVideoUrls(from: html)
        let pageURL = URL(string: "https://allpornstream.com/post/test")!
        return providerCandidates(from: entries, pageURL: pageURL).map {
            ProviderCandidateForTesting(providerName: $0.providerName, url: $0.selectedUrl)
        }
    }

    static func resolveProviderCandidatesForTesting(
        _ candidates: [ProviderCandidateForTesting],
        resolver: @escaping (String) async throws -> VideoSource
    ) async -> [VideoSource.Quality] {
        let internalCandidates = candidates.map {
            ProviderCandidate(
                providerName: $0.providerName,
                selectedUrl: $0.url,
                watchUrl: nil,
                embedUrl: $0.url,
                fileCode: providerFileCode(from: $0.url),
                sourcePageUrl: $0.url
            )
        }
        return await resolveProviderCandidates(internalCandidates, resolver: resolver)
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
            sourcePageUrl: iframeByProvider[provider.lowercased()],
            fileCode: nil
        )
    }

    private static func parseIframeObject(_ item: String) -> ProviderEntry? {
        guard let provider = findJsonStringValue(for: "hosting_provider", in: item),
              let url = findJsonStringValue(for: "embed_url", in: item) ?? findJsonStringValue(for: "url", in: item) else {
            return nil
        }

        let fileCode = findJsonStringValue(for: "file_code", in: item)

        return ProviderEntry(providerName: provider, url: url, isIframeFallback: true, sourcePageUrl: nil, fileCode: fileCode)
    }

    // MARK: - Provider resolution

    private static func providerCandidates(from entries: [ProviderEntry], pageURL: URL) -> [ProviderCandidate] {
        var orderedKeys: [String] = []
        var watchByKey: [String: ProviderEntry] = [:]
        var embedByKey: [String: ProviderEntry] = [:]

        for entry in entries where !entry.isIframeFallback {
            let key = groupingKey(for: entry)
            if !orderedKeys.contains(key) {
                orderedKeys.append(key)
            }
            watchByKey[key] = entry
        }

        for entry in entries where entry.isIframeFallback {
            let key = groupingKey(for: entry)
            if !orderedKeys.contains(key) {
                orderedKeys.append(key)
            }
            embedByKey[key] = entry
        }

        return orderedKeys.compactMap { key in
            let embed = embedByKey[key]
            let watch = watchByKey[key]
            guard let chosen = embed ?? watch else { return nil }
            let sourcePageUrl = chosen.sourcePageUrl ?? (chosen.url.isEmpty ? pageURL.absoluteString : chosen.url)

            return ProviderCandidate(
                providerName: chosen.providerName.uppercased(),
                selectedUrl: chosen.url,
                watchUrl: watch?.url,
                embedUrl: embed?.url,
                fileCode: embed?.fileCode ?? watch?.fileCode ?? providerFileCode(from: chosen.url),
                sourcePageUrl: sourcePageUrl
            )
        }
    }

    private static func resolveProviderCandidates(
        _ candidates: [ProviderCandidate],
        resolver: ProviderResolver? = nil
    ) async -> [VideoSource.Quality] {
        await withTaskGroup(of: (Int, [VideoSource.Quality]).self) { group in
            for (index, candidate) in candidates.enumerated() where isResolvableProvider(candidate) {
                group.addTask {
                    do {
                        let resolved: VideoSource
                        if let resolver {
                            resolved = try await resolver(candidate.selectedUrl)
                        } else {
                            resolved = try await resolveProvider(candidate)
                        }
                        return (index, flatten(resolved, provider: candidate))
                    } catch {
                        return (index, [])
                    }
                }
            }

            var byIndex: [Int: [VideoSource.Quality]] = [:]
            for await (index, qualities) in group {
                byIndex[index] = qualities
            }

            return candidates.indices.flatMap { index in
                byIndex[index] ?? []
            }
        }
    }

    private static func resolveProvider(_ candidate: ProviderCandidate) async throws -> VideoSource {
        guard let url = URLTrustPolicy.validated(candidate.selectedUrl) else {
            throw VideoExtractorError.invalidURL
        }

        if isDoodProvider(candidate.providerName) {
            let host = url.host?.lowercased() ?? "unknown"
            if !DoodStreamExtractor.supports(url) {
                Log.extractionDood.notice("Resolving AllPornStream DoodStream provider through new host: \(host, privacy: .public)")
            }
            return try await DoodStreamExtractor.extract(fromHTML: "", url: url)
        }

        return try await ScraperEngine.extract(from: candidate.selectedUrl)
    }

    private static func flatten(_ source: VideoSource, provider candidate: ProviderCandidate) -> [VideoSource.Quality] {
        var result: [VideoSource.Quality] = []
        var seen = Set<String>()
        let concrete = source.hls.filter { $0.kind != .pageUrl }

        if concrete.isEmpty, let mp4 = source.mp4, seen.insert(mp4).inserted {
            result.append(VideoSource.Quality(
                label: "\(candidate.providerName) · Video",
                url: mp4,
                kind: .direct,
                headers: source.headers(forQualityURL: mp4),
                sourcePageUrl: candidate.sourcePageUrl
            ))
        } else {
            for quality in concrete {
                guard seen.insert(quality.url).inserted else { continue }
                result.append(VideoSource.Quality(
                    label: "\(candidate.providerName) · \(quality.label)",
                    url: quality.url,
                    kind: quality.kind,
                    headers: quality.headers ?? source.headers(forQualityURL: quality.url),
                    sourcePageUrl: quality.sourcePageUrl ?? candidate.sourcePageUrl
                ))
            }
        }

        return result
    }

    private static func groupingKey(for entry: ProviderEntry) -> String {
        let provider = normalizedProviderKey(entry.providerName)
        let file = entry.fileCode ?? providerFileCode(from: entry.url)
        return "\(provider)|\(file ?? normalizedURLKey(entry.url))"
    }

    private static func normalizedProviderKey(_ providerName: String) -> String {
        providerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedURLKey(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString.lowercased() }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return urlString.lowercased()
        }
        let scheme = components.scheme?.lowercased()
        let host = components.host?.lowercased()
        components.scheme = scheme
        components.host = host
        components.query = nil
        components.fragment = nil
        return components.string ?? urlString.lowercased()
    }

    private static func providerFileCode(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let marker = parts.firstIndex(where: { ["v", "e", "f", "d"].contains($0) }),
              marker + 1 < parts.count else {
            return nil
        }
        return parts[marker + 1]
    }

    private static func isResolvableProvider(_ candidate: ProviderCandidate) -> Bool {
        isDoodProvider(candidate.providerName) || isResolvableProviderURL(candidate.selectedUrl)
    }

    private static func isDoodProvider(_ providerName: String) -> Bool {
        normalizedProviderKey(providerName) == "doodstream"
    }

    private static func isResolvableProviderURL(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == "streamtape.com" || host.hasSuffix(".streamtape.com")
            || host == "streamtape.net" || host.hasSuffix(".streamtape.net")
            || host == "mixdrop.ag" || host.hasSuffix(".mixdrop.ag")
            || host == "mixdrop.co" || host.hasSuffix(".mixdrop.co")
            || host == "mixdrop.sx" || host.hasSuffix(".mixdrop.sx")
            || host == "mixdrop.pw" || host.hasSuffix(".mixdrop.pw")
            || host == "mixdrop.top" || host.hasSuffix(".mixdrop.top")
            || host == "mxdrop.to" || host.hasSuffix(".mxdrop.to")
            || host == "m1xdrop.click" || host.hasSuffix(".m1xdrop.click")
            || host == "miiixdrop.net" || host.hasSuffix(".miiixdrop.net")
            || host == "doodstream.com" || host.hasSuffix(".doodstream.com")
            || host == "doodstream.org" || host.hasSuffix(".doodstream.org")
            || host == "dood.wf" || host.hasSuffix(".dood.wf")
            || host == "dood.pm" || host.hasSuffix(".dood.pm")
            || host == "dood.to" || host.hasSuffix(".dood.to")
            || host == "dood.ws" || host.hasSuffix(".dood.ws")
            || host == "dood.one" || host.hasSuffix(".dood.one")
            || host == "dood.watch" || host.hasSuffix(".dood.watch")
            || host == "dood.la" || host.hasSuffix(".dood.la")
            || host == "dood.sh" || host.hasSuffix(".dood.sh")
            || host == "playmogo.com" || host.hasSuffix(".playmogo.com")
            || host == "ds2play.com" || host.hasSuffix(".ds2play.com")
            || host == "vidara.so" || host.hasSuffix(".vidara.so")
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
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw VideoExtractorError.network(
                NSError(domain: "VidDL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch video page"])
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
