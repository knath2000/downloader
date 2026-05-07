import Foundation

struct HQPornerExtractor: VideoSiteExtractor {
  static func supports(_ url: URL) -> Bool {
    guard let host = url.host()?.lowercased() else { return false }
    return host == "hqporner.com" || host.hasSuffix(".hqporner.com")
  }

  static func extract(fromHTML html: String, url: URL) async throws -> VideoSource {
    let pageHtml = html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? try await fetchPage(url: url) : html
    let title = extractTitle(from: pageHtml)
    let thumbnail = extractThumbnail(from: pageHtml, pageURL: url)
    let iframeURL = try extractIframeURL(from: pageHtml)
    let embedHtml = try await fetchPage(url: iframeURL)
    let qualities = extractQualities(from: embedHtml, pageURL: url)

    guard !qualities.isEmpty else {
      throw VideoExtractorError.noVideoSources
    }

    return VideoSource(
      mp4: qualities.first?.url,
      hls: qualities,
      title: title,
      thumbnail: thumbnail,
      siteName: "HQPorner"
    )
  }

  private static func fetchPage(url: URL) async throws -> String {
    var request = URLRequest(url: url)
    request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://hqporner.com/", forHTTPHeaderField: "Referer")
    request.timeoutInterval = 20

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse,
          (200...299).contains(http.statusCode),
          let html = String(data: data, encoding: .utf8) else {
      throw VideoExtractorError.noVideoSources
    }
    return html
  }

  private static func extractTitle(from html: String) -> String {
    let patterns = [
      #"<h1[^>]*class=["'][^"']*title[^"']*["'][^>]*>(.*?)</h1>"#,
      #"<title[^>]*>(.*?)</title>"#
    ]
    for pattern in patterns {
      guard let match = firstCapture(pattern: pattern, in: html) else { continue }
      let stripped = decodeHTMLEntities(strippingTags(from: match))
        .replacingOccurrences(of: #"\s+(?:[|-]\s*)?HQPorner.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !stripped.isEmpty { return stripped }
    }
    return "Unknown"
  }

  private static func extractThumbnail(from html: String, pageURL: URL) -> String? {
    let patterns = [
      #"<meta\s+property=["']og:image["']\s+content=["']([^"']+)["']"#,
      #"<meta\s+content=["']([^"']+)["']\s+property=["']og:image["']"#
    ]
    for pattern in patterns {
      if let raw = firstCapture(pattern: pattern, in: html) {
        return absoluteURL(decodeHTMLEntities(raw), relativeTo: pageURL)
      }
    }
    return nil
  }

  private static func extractIframeURL(from html: String) throws -> URL {
    let patterns = [
      #"<iframe[^>]+src=["'](//mydaddy\.cc/video/[^"']+)["']"#,
      #"<iframe[^>]+src=["'](//[^"']+)["']"#
    ]
    for pattern in patterns {
      guard let raw = firstCapture(pattern: pattern, in: html),
            let resolved = absoluteURL(decodeHTMLEntities(raw), relativeTo: URL(string: "https://hqporner.com/")!),
            let url = URL(string: resolved) else { continue }
      return url
    }
    throw VideoExtractorError.noVideoSources
  }

  private static func extractQualities(from html: String, pageURL: URL) -> [VideoSource.Quality] {
    guard let regex = try? NSRegularExpression(pattern: #"<source\b[^>]*>"#, options: [.caseInsensitive]) else {
      return []
    }
    let range = NSRange(html.startIndex..<html.endIndex, in: html)
    var qualities: [VideoSource.Quality] = []
    var seen = Set<String>()

    for match in regex.matches(in: html, range: range) {
      guard let tagRange = Range(match.range, in: html) else { continue }
      let tag = String(html[tagRange])
      guard let rawSource = attribute("src", in: tag),
            let source = absoluteURL(decodeHTMLEntities(rawSource), relativeTo: pageURL),
            !seen.contains(source) else { continue }
      seen.insert(source)

      let label = attribute("title", in: tag) ?? attribute("label", in: tag) ?? "Video"
      qualities.append(VideoSource.Quality(
        label: decodeHTMLEntities(label),
        url: source,
        kind: .direct,
        headers: [
          "Referer": "https://hqporner.com/",
          "User-Agent": NetworkConstants.chromeUserAgent
        ],
        sourcePageUrl: pageURL.absoluteString
      ))
    }

    qualities.sort {
      resolution(from: $0.label) > resolution(from: $1.label)
    }
    return qualities
  }

  private static func resolution(from label: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: #"(\d+)p"#, options: [.caseInsensitive]),
          let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..<label.endIndex, in: label)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: label) else {
      return 0
    }
    return Int(label[range]) ?? 0
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

  private static func attribute(_ name: String, in tag: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    let pattern = #"\b\#(escaped)=\\?["']([^"'\\]+)\\?["']"#
    return firstCapture(pattern: pattern, in: tag)
  }

  private static func absoluteURL(_ raw: String, relativeTo pageURL: URL) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("//") {
      return "https:\(trimmed)"
    }
    return URL(string: trimmed, relativeTo: pageURL)?.absoluteURL.absoluteString
  }

  private static func strippingTags(from value: String) -> String {
    (try? NSRegularExpression(pattern: #"<[^>]+>"#, options: [.caseInsensitive]))?
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
  }
}
