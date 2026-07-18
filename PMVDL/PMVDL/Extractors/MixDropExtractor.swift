import Foundation

/// Extracts video sources from mixdrop.co / mixdrop.sx / mixdrop.pw.
/// MixDrop uses a p.a.c.k.e.r style eval block that decodes to an HLS or direct MP4 URL.
struct MixDropExtractor: VideoSiteExtractor {

 static func supports(_ url: URL) -> Bool {
 guard let host = url.host()?.lowercased() else { return false }
 return host == "mixdrop.ag" || host == "mixdrop.co" || host == "mixdrop.sx" || host == "mixdrop.pw" || host == "mixdrop.top" || host == "mxdrop.to" || host == "m1xdrop.click" || host == "miiixdrop.net" || host == "miiiixdrop.net"
 || host.hasSuffix(".mixdrop.ag") || host.hasSuffix(".mixdrop.co") || host.hasSuffix(".mixdrop.sx") || host.hasSuffix(".mixdrop.pw") || host.hasSuffix(".mixdrop.top") || host.hasSuffix(".mxdrop.to") || host.hasSuffix(".m1xdrop.click") || host.hasSuffix(".miiixdrop.net") || host.hasSuffix(".miiiixdrop.net")
 }

 static func extract(fromHTML html: String, url: URL) async throws -> VideoSource {
 let pageHtml: String
 if html.isEmpty {
 do {
 pageHtml = try await fetchPage(url: url)
 } catch {
 return try await extractViaWebView(url: url)
 }
 } else {
 pageHtml = html
 }

 let title = extractTitle(from: pageHtml) ?? "MixDrop Video"
 let thumbnail = extractThumbnail(from: pageHtml)

 guard let videoUrl = findVideoUrl(in: pageHtml, pageURL: url) ?? findVideoUrlViaPacker(pageHtml, pageURL: url) else {
 return try await extractViaWebView(url: url)
 }

 return videoSource(videoUrl, pageURL: url, title: title, thumbnail: thumbnail, resolutionMethod: "Static MixDrop resolver")
 }

 private static func extractViaWebView(url: URL) async throws -> VideoSource {
 let videoUrl = try await WebViewExtractor.shared.extractVideoUrl(from: url, timeout: 45)
 guard isValidMixDropMediaUrl(videoUrl) else { throw MixDropError.noVideoSource }
 return videoSource(videoUrl, pageURL: url, title: "MixDrop Video", thumbnail: nil, resolutionMethod: "WebView media capture")
 }

 private static func videoSource(_ videoUrl: String, pageURL: URL, title: String, thumbnail: String?, resolutionMethod: String) -> VideoSource {
 let headers = [
 "User-Agent": NetworkConstants.chromeUserAgent,
 "Referer": pageURL.absoluteString
 ]

 let quality = VideoSource.Quality(
 label: "Video",
 url: videoUrl,
 kind: .direct,
 headers: headers,
 sourcePageUrl: pageURL.absoluteString,
 resolutionMethod: resolutionMethod
 )

 return VideoSource(
 mp4: videoUrl,
 hls: [quality],
 title: title,
 thumbnail: thumbnail,
 siteName: "MixDrop",
 headers: headers,
 resolutionMethod: resolutionMethod
 )
 }

 // MARK: - Page Fetching

 private static func fetchPage(url: URL) async throws -> String {
 var request = URLRequest(url: url)
 request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
 request.timeoutInterval = 15

 let (data, response) = try await URLSession.shared.data(for: request)
 guard let httpResponse = response as? HTTPURLResponse,
 (200...299).contains(httpResponse.statusCode),
 let html = String(data: data, encoding: .utf8) else {
 throw MixDropError.networkError
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

 /// Try direct JS config patterns first.
 private static func findVideoUrl(in html: String, pageURL: URL) -> String? {
 if let url = extractMDCoreWurl(from: html, pageURL: pageURL) {
 return url
 }

 if let url = extractSourcesFile(from: html, pageURL: pageURL) {
 return url
 }

 if let url = extractKnownDownloadVariable(from: html, pageURL: pageURL) {
 return url
 }

 if let url = extractHtmlAttrValue(attr: "data-src", in: html),
 let normalized = normalizeMixDropMediaUrl(url, pageURL: pageURL) {
 return normalized
 }

 return nil
 }

 /// Decode p.a.c.k.e.r style eval blocks that MixDrop sometimes uses.
 private static func findVideoUrlViaPacker(_ html: String, pageURL: URL) -> String? {
 guard let packed = extractPackedBlock(html) else { return nil }
 guard let decoded = unpackPacker(packed) else { return nil }
 return findVideoUrl(in: decoded, pageURL: pageURL)
 }

 // MARK: - Helpers

 private static func extractMDCoreWurl(from html: String, pageURL: URL) -> String? {
 let patterns = [
 #"MDCore\.wurl\s*=\s*['"]([^'"]+)['"]"#,
 #"\bwurl\s*[:=]\s*['"]([^'"]+)['"]"#
 ]

 for pattern in patterns {
 if let raw = extractJsStringValue(pattern: pattern, in: html),
 let normalized = normalizeMixDropMediaUrl(raw, pageURL: pageURL) {
 return normalized
 }
 }

 return nil
 }

 private static func extractSourcesFile(from html: String, pageURL: URL) -> String? {
 let patterns = [
 #"sources\s*:\s*\[\s*\{\s*file\s*:\s*['"]([^'"]+)['"]"#,
 #"sources\s*:\s*\[\s*\{\s*["']file["']\s*:\s*['"]([^'"]+)['"]"#
 ]

 for pattern in patterns {
 if let raw = extractJsStringValue(pattern: pattern, in: html),
 let normalized = normalizeMixDropMediaUrl(raw, pageURL: pageURL) {
 return normalized
 }
 }

 return nil
 }

 private static func extractKnownDownloadVariable(from html: String, pageURL: URL) -> String? {
 let patterns = [
 #"\bdownload_url\s*[=:]\s*['"]([^'"]+)['"]"#,
 #"\bdownloadUrl\s*[=:]\s*['"]([^'"]+)['"]"#,
 #"\bvideo_url\s*[=:]\s*['"]([^'"]+)['"]"#
 ]

 for pattern in patterns {
 if let raw = extractJsStringValue(pattern: pattern, in: html),
 let normalized = normalizeMixDropMediaUrl(raw, pageURL: pageURL) {
 return normalized
 }
 }

 return nil
 }

 private static func normalizeMixDropMediaUrl(_ raw: String, pageURL: URL) -> String? {
 let trimmed = raw
 .replacingOccurrences(of: "&amp;", with: "&")
 .trimmingCharacters(in: .whitespacesAndNewlines)

 guard !trimmed.isEmpty else { return nil }

 let normalized: String

 if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
 normalized = trimmed
 } else if trimmed.hasPrefix("//") {
 normalized = "https:" + trimmed
 } else if trimmed.hasPrefix("/") {
 normalized = URL(string: trimmed, relativeTo: pageURL)?.absoluteURL.absoluteString ?? trimmed
 } else {
 normalized = trimmed
 }

 guard isValidMixDropMediaUrl(normalized) else {
 return nil
 }

 return normalized
 }

 private static func isValidMixDropMediaUrl(_ urlString: String) -> Bool {
 guard let components = URLComponents(string: urlString),
 let host = components.host?.lowercased() else {
 return false
 }

 let path = components.percentEncodedPath.lowercased()

 guard host == "mxcontent.net" || host.hasSuffix(".mxcontent.net") else {
 return false
 }

 return path.hasSuffix(".mp4") || path.contains(".mp4")
 }

 private static func extractJsStringValue(pattern: String, in text: String) -> String? {
 guard let regex = try? NSRegularExpression(pattern: pattern),
 let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
 let range = Range(match.range(at: 1), in: text) else {
 return nil
 }
 return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
 }

 private static func extractHtmlAttrValue(attr: String, in html: String) -> String? {
 let pattern = attr + #"\s*=\s*['"]([^'"]+)['"]"#
 return extractJsStringValue(pattern: pattern, in: html)
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

 private static func decodeEscapes(_ s: String) -> String {
 s.replacingOccurrences(of: "\\n", with: "\n")
 .replacingOccurrences(of: "\\t", with: "\t")
 .replacingOccurrences(of: "\\/", with: "/")
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
}

enum MixDropError: LocalizedError {
 case noVideoSource
 case networkError

 var errorDescription: String? {
 switch self {
 case .noVideoSource:
 return "MixDrop could not extract a video source. The video may have expired or been removed."
 case .networkError:
 return "Failed to fetch the MixDrop page."
 }
 }
}
