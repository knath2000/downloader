import Foundation

/// Extracts video sources from DoodStream and its rotating provider domains.
/// DoodStream exposes a direct MP4 URL via a JavaScript player on the page.
/// The video URL can be found via a p.a.c.k.e.r unpack or by direct JS config patterns.
struct DoodStreamExtractor: VideoSiteExtractor {
  typealias PlaymogoPassResolver = (URL, URL) async throws -> String

  private struct PageFetchResult {
    let html: String
    let finalURL: URL
  }

  static func supports(_ url: URL) -> Bool {
    guard let host = url.host()?.lowercased() else { return false }
    return host == "doodstream.com" || host == "doodstream.org" || host == "dood.wf" || host == "dood.pm"
      || host == "dood.to" || host == "dood.ws" || host == "dood.one" || host == "dood.watch" || host == "dood.la"
      || host == "dood.sh" || host == "vide0.net" || host == "dooodster.com" || host == "playmogo.com"
      || host.hasSuffix(".doodstream.com") || host.hasSuffix(".doodstream.org") || host.hasSuffix(".dood.wf")
      || host.hasSuffix(".dood.pm") || host.hasSuffix(".dood.to") || host.hasSuffix(".dood.ws")
      || host.hasSuffix(".dood.one") || host.hasSuffix(".dood.watch") || host.hasSuffix(".dood.la")
      || host.hasSuffix(".dood.sh") || host.hasSuffix(".vide0.net") || host.hasSuffix(".dooodster.com") || isPlaymogoHost(host)
  }

  static func extract(fromHTML html: String, url: URL) async throws -> VideoSource {
    try await extract(
      fromHTML: html,
      url: url,
      resolvedPageURL: nil,
      playmogoPassResolver: nil,
      randomSuffix: makeRandomPlaymogoSuffix,
      nowMilliseconds: currentMilliseconds
    )
  }

  /// Uses the stable Playmogo resolver for a URL identified as DoodStream by a trusted provider record.
  static func extractTrustedProviderURL(_ url: URL) async throws -> VideoSource {
    try await extract(
      fromHTML: "",
      url: url,
      resolvedPageURL: nil,
      playmogoPassResolver: nil,
      randomSuffix: makeRandomPlaymogoSuffix,
      nowMilliseconds: currentMilliseconds,
      forcePlaymogoCanonicalization: true
    )
  }

  static func extract(
    fromHTML html: String,
    url: URL,
    resolvedPageURL: URL?,
    playmogoPassResolver: PlaymogoPassResolver?,
    randomSuffix: @escaping () -> String,
    nowMilliseconds: @escaping () -> String,
    forcePlaymogoCanonicalization: Bool = false
  ) async throws -> VideoSource {
    var targetUrl = url
    if let alternateURL = alternatePlaymogoURL(for: targetUrl, force: forcePlaymogoCanonicalization) {
      targetUrl = alternateURL
    }
    var fetched: PageFetchResult
    if html.isEmpty {
      do {
        fetched = try await fetchPageResult(url: targetUrl)
      } catch {
        if let alternateURL = alternatePlaymogoURL(for: targetUrl, force: forcePlaymogoCanonicalization) {
          do {
            Log.extractionDood.notice("Provider page fetch failed; trying Playmogo mirror: \(alternateURL.absoluteString, privacy: .public)")
            fetched = try await fetchPageResult(url: alternateURL)
          } catch {
            Log.extractionDood.error("Static provider page fetch failed; falling back to WebView: \(error.localizedDescription, privacy: .public)")
            fetched = PageFetchResult(html: "", finalURL: targetUrl)
          }
        } else {
          Log.extractionDood.error("Static provider page fetch failed; falling back to WebView: \(error.localizedDescription, privacy: .public)")
          fetched = PageFetchResult(html: "", finalURL: targetUrl)
        }
      }
    } else {
      fetched = PageFetchResult(html: html, finalURL: resolvedPageURL ?? targetUrl)
    }

    if targetUrl.path.hasPrefix("/d/"),
       let embedURL = extractEmbeddedPlayerURL(from: fetched.html, pageURL: fetched.finalURL) {
      do {
        fetched = try await fetchPageResult(url: embedURL)
      } catch {
        Log.extractionDood.error("Embedded Dood player fetch failed: \(error.localizedDescription, privacy: .public)")
      }
    }

    targetUrl = resolvedPageURL ?? fetched.finalURL
    let host = targetUrl.host()?.lowercased() ?? ""
    let isPlaymogo = isPlaymogoHost(host)
    let pageHtml = normalizedHTML(fetched.html)
    let title = extractTitle(from: pageHtml) ?? (isPlaymogo ? "Playmogo Video" : "DoodStream Video")
    let thumbnail = extractThumbnail(from: pageHtml)
    var finalVideoUrl: String?
    var resolutionMethod = "Static page parser"

    if isPlaymogo {
      Log.extractionDood.debug("Playmogo detected. Trying static pass_md5 extraction first...")
      finalVideoUrl = await findPlaymogoVideoUrl(
        in: pageHtml,
        pageURL: targetUrl,
        passResolver: playmogoPassResolver ?? { passURL, referer in
          try await fetchPlaymogoPassBase(passURL: passURL, referer: referer)
        },
        randomSuffix: randomSuffix,
        nowMilliseconds: nowMilliseconds
      )
      if finalVideoUrl != nil {
        resolutionMethod = "Static Playmogo resolver"
      }

      if finalVideoUrl == nil {
        Log.extractionDood.debug("Static Playmogo extraction failed. Falling back to WebViewExtractor...")
        do {
          finalVideoUrl = try await WebViewExtractor.shared.extractVideoUrl(from: targetUrl, timeout: 45)
          if let url = finalVideoUrl, isValidCandidate(url) {
            Log.extractionDood.debug("WebView extracted candidate URL: \(url, privacy: .public)")
            resolutionMethod = "WebView media capture"
          } else if let url = finalVideoUrl {
            Log.extractionDood.error("WebView extracted invalid URL, rejecting: \(url, privacy: .public)")
            finalVideoUrl = nil
          }
        } catch {
          Log.extractionDood.error("WebView extraction failed: \(error.localizedDescription, privacy: .public)")
          requestVerificationIfNeeded(for: error, url: targetUrl)
          finalVideoUrl = nil
        }
      }

      if finalVideoUrl == nil, let foundUrl = findDoodOrCloudCandidate(in: pageHtml) {
        finalVideoUrl = foundUrl
        Log.extractionDood.debug("Found static helper candidate: \(foundUrl, privacy: .public)")
      }

      if finalVideoUrl == nil {
        if let foundUrl = findVideoUrl(in: pageHtml) ?? findVideoUrlViaPacker(pageHtml) {
          if isValidCandidate(foundUrl) {
            finalVideoUrl = foundUrl
            Log.extractionDood.info("Found valid Playmogo-compatible URL via standard extraction: \(foundUrl, privacy: .public)")
          } else {
            Log.extractionDood.debug("Skipping invalid URL from standard extraction: \(foundUrl, privacy: .public)")
          }
        }
      }
    } else {
      finalVideoUrl = findVideoUrl(in: pageHtml) ?? findVideoUrlViaPacker(pageHtml)

      if finalVideoUrl == nil {
        Log.extractionDood.debug("Static extraction failed. Falling back to WebViewExtractor...")
        do {
          finalVideoUrl = try await WebViewExtractor.shared.extractVideoUrl(from: targetUrl, timeout: 25)
          if finalVideoUrl != nil {
            resolutionMethod = "WebView media capture"
          }
        } catch {
          requestVerificationIfNeeded(for: error, url: targetUrl)
          finalVideoUrl = nil
        }
      }
    }

    // If we have a cloudatacdn.com URL for normal DoodStream, try to resolve it.
    // Playmogo must keep the CDN URL because the dood.video redirect resolves to loopback locally.
    if let currentUrl = finalVideoUrl, currentUrl.contains("cloudatacdn.com"), !isPlaymogo {
      Log.extractionDood.debug("Detected intermediate CDN URL, attempting to resolve final URL...")
      if let resolvedUrl = await resolveUrl(currentUrl) {
        if isValidFinalVideoUrl(resolvedUrl) {
          finalVideoUrl = resolvedUrl
          Log.extractionDood.info("Resolved to final dood.video URL: \(resolvedUrl, privacy: .public)")
        } else {
          Log.extractionDood.error("Resolved URL is not a dood.video URL: \(resolvedUrl, privacy: .public)")
        }
      } else {
        Log.extractionDood.error("Failed to resolve intermediate URL")
      }
    }

    guard let videoUrl = finalVideoUrl else {
      throw DoodStreamError.noVideoSource
    }

    let playmogoHeaders = isPlaymogo ? [
      "Referer": targetUrl.absoluteString,
      "User-Agent": NetworkConstants.chromeUserAgent
    ] : nil

    if isPlaymogo, !isFullCloudMediaUrl(videoUrl) {
      Log.extractionDood.error("Final Playmogo URL is not a playable CDN URL: \(videoUrl, privacy: .public)")
      throw DoodStreamError.noVideoSource
    }

    if !isPlaymogo, !isValidFinalVideoUrl(videoUrl) {
      Log.extractionDood.error("Final URL does not contain a playable dood.video URL: \(videoUrl, privacy: .public)")
      throw DoodStreamError.noVideoSource
    }

    // For Playmogo the URL requires Referer headers; only expose it via the hls quality entry
    // (which carries headers) so that batch-download paths that skip per-URL headers don't
    // silently download garbage from the CDN redirect.
    let mp4Field: String? = isPlaymogo ? nil : videoUrl
    return VideoSource(
      mp4: mp4Field,
      hls: [VideoSource.Quality(
        label: "Video",
        url: videoUrl,
        kind: .direct,
        headers: playmogoHeaders,
        sourcePageUrl: targetUrl.absoluteString,
        resolutionMethod: resolutionMethod
      )],
      title: title,
      thumbnail: thumbnail,
      siteName: isPlaymogo ? "Playmogo" : "DoodStream",
      resolutionMethod: resolutionMethod
    )
  }

  // MARK: - Page Fetching

  private static func fetchPageResult(url: URL) async throws -> PageFetchResult {
    var request = URLRequest(url: url)
    request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
    request.timeoutInterval = 15

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
    (200...299).contains(httpResponse.statusCode),
    let html = String(data: data, encoding: .utf8) else {
      throw DoodStreamError.networkError
    }

    return PageFetchResult(html: html, finalURL: httpResponse.url ?? url)
  }

  private static func fetchPage(url: URL) async throws -> String {
    try await fetchPageResult(url: url).html
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
      pattern: #"<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)[\"']"#,
      options: .caseInsensitive
    ).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
    let range = Range(match.range(at: 1), in: html) {
      return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
  }

  // MARK: - Video URL extraction

  private static func normalizedHTML(_ html: String) -> String {
    html
      .replacingOccurrences(of: "\\/", with: "/")
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&#038;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#34;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
  }

  private static func isPlaymogoHost(_ host: String) -> Bool {
    host == "playmogo.com" || host == "ds2play.com" ||
    host == "www.playmogo.com" ||
    host.hasSuffix(".playmogo.com") || host.hasSuffix(".ds2play.com")
  }

  private static func alternatePlaymogoURL(for url: URL, force: Bool = false) -> URL? {
    guard let host = url.host?.lowercased(),
          !isPlaymogoHost(host),
          host != "dood.video",
          force || supports(url) || host.hasPrefix("dood") else {
      return nil
    }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.scheme = "https"
    components?.host = "playmogo.com"
    return components?.url
  }

  private static func requestVerificationIfNeeded(for error: Error, url: URL) {
    guard case WebViewError.cloudflareChallenge = error else { return }
    Task { @MainActor in
      ExtractionVerificationCoordinator.shared.requestVerification(for: url)
    }
  }

  private static func extractEmbeddedPlayerURL(from html: String, pageURL: URL) -> URL? {
    let pattern = #"<iframe\b[^>]*\bsrc\s*=\s*[\"']([^\"']+)[\"']"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
    let range = NSRange(html.startIndex..., in: html)
    for match in regex.matches(in: html, range: range) {
      guard let sourceRange = Range(match.range(at: 1), in: html) else { continue }
      let source = normalizedHTML(String(html[sourceRange]))
      guard let embedURL = URL(string: source, relativeTo: pageURL)?.absoluteURL,
            embedURL.path.hasPrefix("/e/"),
            URLTrustPolicy.isAllowed(embedURL) else {
        continue
      }
      return embedURL
    }
    return nil
  }

  private static func findPlaymogoVideoUrl(
    in html: String,
    pageURL: URL,
    passResolver: PlaymogoPassResolver,
    randomSuffix: () -> String,
    nowMilliseconds: () -> String
  ) async -> String? {
    guard let passPath = extractPlaymogoPassPath(from: html),
          let passURL = URL(string: passPath, relativeTo: pageURL)?.absoluteURL,
          let tokenPrefix = extractPlaymogoTokenPrefix(from: html) else {
      return nil
    }

    do {
      let base = try await passResolver(passURL, pageURL)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !base.isEmpty else { return nil }

      let finalURL = base + randomSuffix() + tokenPrefix + nowMilliseconds()
      guard isFullCloudMediaUrl(finalURL) else { return nil }
      return finalURL
    } catch {
      Log.extractionDood.error("Playmogo pass_md5 fetch failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  private static func extractPlaymogoPassPath(from html: String) -> String? {
    let text = normalizedHTML(html)
    let patterns = [
      #"\$\.get\(\s*['"]([^'"]+)['"]"#,
      #"\.get\(\s*['"]([^'"]*/pass_md5/[^'"]+)['"]"#,
      #"\burl\s*:\s*['"]([^'"]*/pass_md5/[^'"]+)['"]"#,
      #"\bfetch\(\s*['"]([^'"]*/pass_md5/[^'"]+)['"]"#,
      #"\.open\(\s*['"][A-Z]+['"]\s*,\s*['"]([^'"]*/pass_md5/[^'"]+)['"]"#,
      #"['"]([^'"]*/pass_md5/[^'"]+)['"]"#
    ]
    for pattern in patterns {
      if let path = extractJsStringValue(pattern: pattern, in: text) {
        return path
      }
    }
    return nil
  }

  private static func extractPlaymogoTokenPrefix(from html: String) -> String? {
    let text = normalizedHTML(html)
    let patterns = [
      #"return\s+[A-Za-z_$][A-Za-z0-9_$]*\s*\+\s*['"]([^'"]*\?token=[^'"]+&expiry=)['"]\s*\+\s*(?:Date\s*\.\s*now\s*\(\s*\)|(?:new\s+Date\s*\(\s*\)|\(new\s+Date\s*\))\s*\.\s*getTime\s*\(\s*\))"#,
      #"[A-Za-z_$][A-Za-z0-9_$]*\s*\+\s*['"]([^'"]*\?token=[^'"]+&expiry=)['"]\s*\+\s*(?:Date\s*\.\s*now\s*\(\s*\)|(?:new\s+Date\s*\(\s*\)|\(new\s+Date\s*\))\s*\.\s*getTime\s*\(\s*\))"#,
      #"['"]([^'"]*\?token=[^'"]+&expiry=)['"]\s*\+\s*(?:Date\s*\.\s*now\s*\(\s*\)|(?:new\s+Date\s*\(\s*\)|\(new\s+Date\s*\))\s*\.\s*getTime\s*\(\s*\))"#
    ]
    for pattern in patterns {
      if let token = extractJsStringValue(pattern: pattern, in: text) {
        return token
      }
    }
    return nil
  }

  private static func fetchPlaymogoPassBase(
    passURL: URL,
    referer: URL
  ) async throws -> String {
    var request = URLRequest(url: passURL)
    request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
    request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    request.timeoutInterval = 15

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
          (200...299).contains(httpResponse.statusCode),
          let body = String(data: data, encoding: .utf8) else {
      throw DoodStreamError.networkError
    }
    return body
  }

  private static func makeRandomPlaymogoSuffix() -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    return String((0..<10).compactMap { _ in alphabet.randomElement() })
  }

  private static func currentMilliseconds() -> String {
    String(Int(Date().timeIntervalSince1970 * 1000))
  }

   /// Try direct JS config patterns first (fastest path).
  private static func findVideoUrl(in html: String) -> String? {
   // sources: [{file: "https://..."}]
   if let url = extractJsStringValue(pattern: #"sources\s*:\s*\[\{file\s*:\s*['\"]([^'\"]+)['\"]"#, in: html) {
   return url
   }

   // Prevent grabbing generic <script src="..."> or <img src="..."> by checking all matches
   let broadPattern = "(?:download_url|downloadUrl|source|src|file|video_url)\\s*[=:]\\s*['\\\"]([^'\\\"]+)['\\\"]"
   if let regex = try? NSRegularExpression(pattern: broadPattern) {
   let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
   for match in matches {
   if let range = Range(match.range(at: 1), in: html) {
   let rawUrl = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)

   // Strip query parameters (e.g. ?loadCastFramework=1) for accurate extension checking
   let urlWithoutQuery = rawUrl.components(separatedBy: "?").first ?? rawUrl
   let lowerUrlWithoutQuery = urlWithoutQuery.lowercased()
   let rawLower = rawUrl.lowercased()

   // Filter out common false positives AND iframe embeds
   if !lowerUrlWithoutQuery.hasSuffix(".js") &&
      !lowerUrlWithoutQuery.hasSuffix(".css") &&
      !lowerUrlWithoutQuery.hasSuffix(".png") &&
      !lowerUrlWithoutQuery.hasSuffix(".jpg") &&
      !lowerUrlWithoutQuery.hasSuffix(".jpeg") &&
      !lowerUrlWithoutQuery.hasSuffix(".gif") &&
      !lowerUrlWithoutQuery.hasSuffix(".webp") &&
      !lowerUrlWithoutQuery.hasSuffix(".svg") &&
      !lowerUrlWithoutQuery.hasSuffix(".ico") &&
      !rawLower.contains("no_video") &&
      !rawLower.contains("placeholder") &&
      !rawLower.contains("favicon") &&
      !rawLower.contains("jquery") &&
      !rawLower.starts(with: "/e/") {
     return rawUrl
   }
   }
   }
   }

   // data-src="https://..."
   if let url = extractHtmlAttrValue(attr: "data-src", in: html) {
   let urlWithoutQuery = url.components(separatedBy: "?").first ?? url
   if !urlWithoutQuery.lowercased().hasSuffix(".js") { return url }
   }

   // video_url variable assignment
   if let url = extractJsStringValue(pattern: "video_url\\s*[=:]\\s*['\\\"]([^'\\\"]+)['\\\"]", in: html) {
   return url
   }

   return nil
   }

  private static func findDoodOrCloudCandidate(in text: String) -> String? {
    let pattern = #"(?:https?:)?(?:\\?/\\?/|//)[^"'\s<>]+(?:dood\.video|cloudatacdn\.com)[^"'\s<>]*"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
    let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    for match in matches {
      if let range = Range(match.range, in: text) {
        let candidate = normalizeCandidate(String(text[range]))
        if isValidCandidate(candidate) {
          return candidate
        }
      }
    }
    return nil
  }

  private static func normalizeCandidate(_ rawUrl: String) -> String {
    let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\/", with: "/")
    if trimmed.hasPrefix("//") {
      return "https:" + trimmed
    }
    return trimmed
  }

  private static func isValidCandidate(_ url: String) -> Bool {
    return isValidFinalVideoUrl(url) || isFullCloudMediaUrl(url)
  }

  private static func isValidFinalVideoUrl(_ url: String) -> Bool {
    guard !isRejectedAsset(url),
          let components = URLComponents(string: url),
          let host = components.host?.lowercased(),
          host.contains("dood.video") else {
      return false
    }

    let path = components.percentEncodedPath
    guard !path.isEmpty, path != "/" else { return false }
    let queryItems = components.queryItems ?? []
    return queryItems.contains(where: { $0.name == "token" }) &&
      queryItems.contains(where: { $0.name == "expiry" })
  }

  private static func isFullCloudMediaUrl(_ url: String) -> Bool {
    guard !isRejectedAsset(url),
          let components = URLComponents(string: url),
          let host = components.host?.lowercased(),
          host.contains("cloudatacdn.com") else {
      return false
    }

    let path = components.percentEncodedPath
    guard path.contains("~"), path.count > 12 else { return false }
    let queryItems = components.queryItems ?? []
    return queryItems.contains(where: { $0.name == "token" }) &&
      queryItems.contains(where: { $0.name == "expiry" })
  }

  private static func isRejectedAsset(_ url: String) -> Bool {
    let lower = url.lowercased()
    if lower.contains("no_video") || lower.contains("placeholder") || lower.contains("favicon") {
      return true
    }

    let path = URL(string: url)?.path.lowercased() ?? lower.components(separatedBy: "?").first ?? lower
    let rejectedExtensions = [".ico", ".svg", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".css", ".js"]
    return rejectedExtensions.contains(where: { path.hasSuffix($0) })
  }

  /// Decode p.a.c.k.e.r style eval blocks that DoodStream sometimes uses.
  private static func findVideoUrlViaPacker(_ html: String) -> String? {
  guard let packed = extractPackedBlock(html) else { return nil }

  let unpacked = unpackPacker(packed) ?? ""
  let urlRegex = try? NSRegularExpression(pattern: "https:\\/\\/[^\"'\\s]*dood\\.video[^\"'\\s]*", options: [])
  if let match = urlRegex?.firstMatch(in: unpacked, range: NSRange(unpacked.startIndex..., in: unpacked)),
     let range = Range(match.range, in: unpacked) {
    return String(unpacked[range])
  }
  return nil
  }

  private static func extractJsStringValue(pattern: String, in text: String) -> String? {
    let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    if let match = regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       let range = Range(match.range(at: 1), in: text) {
      return String(text[range])
    }
    return nil
  }

  private static func extractHtmlAttrValue(attr: String, in html: String) -> String? {
  let pattern = #"\\#(attr)\\s*=\\s*[\"']([^\"']+)[\"']"#
  let regex = try? NSRegularExpression(pattern: pattern, options: [])
  if let match = regex?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
     let range = Range(match.range(at: 1), in: html) {
    return String(html[range])
  }
  return nil
  }

  private static func extractPackedBlock(_ html: String) -> String? {
  let pattern = "eval\\s*\\(\\s*function\\s*\\([^)]*\\)\\s*\\{[^}]+\\}\\s*\\(\\s*\\{[^}]+\\}\\s*,\\s*\\d+\\s*,\\s*\\d+\\s*,\\s*'[^']*'\\s*\\)\\s*\\)"
  let regex = try? NSRegularExpression(pattern: pattern, options: [])
  if let match = regex?.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
     let range = Range(match.range, in: html) {
    return String(html[range])
  }
  return nil
  }

  private static func unpackPacker(_ packed: String) -> String? {
  let pPattern = "'([^']*)'"
  let aPattern = "(\\d+)"
  let cPattern = "(\\d+)"
  let kPattern = "'([^']*)'"

  let pRegex = try? NSRegularExpression(pattern: pPattern, options: [])
  let aRegex = try? NSRegularExpression(pattern: aPattern, options: [])
  let cRegex = try? NSRegularExpression(pattern: cPattern, options: [])
  let kRegex = try? NSRegularExpression(pattern: kPattern, options: [])

  let pMatches = pRegex?.matches(in: packed, range: NSRange(packed.startIndex..., in: packed))
  let aMatches = aRegex?.matches(in: packed, range: NSRange(packed.startIndex..., in: packed))
  let cMatches = cRegex?.matches(in: packed, range: NSRange(packed.startIndex..., in: packed))
  let kMatches = kRegex?.matches(in: packed, range: NSRange(packed.startIndex..., in: packed))

  guard let pMatch = pMatches?.first, let aMatch = aMatches?.first,
        let cMatch = cMatches?.first, let kMatch = kMatches?.first,
        let pRange = Range(pMatch.range(at: 1), in: packed),
        let aRange = Range(aMatch.range(at: 1), in: packed),
        let cRange = Range(cMatch.range(at: 1), in: packed),
        let kRange = Range(kMatch.range(at: 1), in: packed) else {
    return nil
  }

  let p = String(packed[pRange])
  let a = Int(String(packed[aRange])) ?? 0
  let c = Int(String(packed[cRange])) ?? 0
  let k = String(packed[kRange])

  return decode(p: p, a: a, c: c, k: k)
  }

  private static func parsePackerArgs(_ args: String) -> String? {
  let pattern = "'([^']*)'"
  let regex = try? NSRegularExpression(pattern: pattern, options: [])
  if let match = regex?.firstMatch(in: args, range: NSRange(args.startIndex..., in: args)),
     let range = Range(match.range(at: 1), in: args) {
    return String(args[range])
  }
  return nil
  }

  private static func splitArgs(_ str: String) -> [String] {
  return str.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  private static func decodeEscapes(_ s: String) -> String {
  var result = s
  let escapes = [
    ("\\\\", "\\"),
    ("\\\"", "\""),
    ("\\'", "'"),
    ("\\n", "\n"),
    ("\\r", "\r"),
    ("\\t", "\t")
  ]
  for (escaped, unescaped) in escapes {
    result = result.replacingOccurrences(of: escaped, with: unescaped)
  }
  return result
  }

  private static func decode(p: String, a: Int, c: Int, k: String) -> String? {
  var result = ""
  let kArray = Array(k)
  let pArray = Array(p)

  var d: [String: String] = [:]
  for i in 0..<c {
    if i < kArray.count {
      d[String(i)] = String(kArray[i])
    }
  }

  var i = 0
  while i < pArray.count {
    let key = String(pArray[i])
    if let value = d[key] {
      result += value
    } else {
      result += key
    }
    i += 1
  }

  return decodeEscapes(result)
  }

  private static func resolveUrl(_ url: String) async -> String? {
    guard let urlObj = URL(string: url) else { return nil }
    if isValidFinalVideoUrl(url) { return url }
    guard isFullCloudMediaUrl(url) else { return nil }

    var request = URLRequest(url: urlObj)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 30
    request.setValue(NetworkConstants.webViewUserAgent, forHTTPHeaderField: "User-Agent")

    do {
      let (_, response) = try await dataWithoutFollowingRedirects(for: request)
      if let httpResponse = response as? HTTPURLResponse {
        if let location = httpResponse.value(forHTTPHeaderField: "Location") {
          Log.extractionDood.debug("Redirect location: \(location, privacy: .public)")
          if isValidFinalVideoUrl(location) {
            return location
          }
        }
        if !(300...399).contains(httpResponse.statusCode) {
          Log.extractionDood.debug("HEAD did not return redirect status \(httpResponse.statusCode, privacy: .public), trying GET...")
          return await resolveUrlWithGet(url: url)
        }
      }
    } catch {
      if let finalUrl = finalUrlFromError(error) {
        return finalUrl
      }
      Log.extractionDood.error("Error resolving URL with HEAD: \(error.localizedDescription, privacy: .public)")
      // Try GET as fallback
      return await resolveUrlWithGet(url: url)
    }
    return nil
  }

  private static func resolveUrlWithGet(url: String) async -> String? {
    guard let urlObj = URL(string: url) else { return nil }
    if isValidFinalVideoUrl(url) { return url }
    guard isFullCloudMediaUrl(url) else { return nil }

    var request = URLRequest(url: urlObj)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue(NetworkConstants.webViewUserAgent, forHTTPHeaderField: "User-Agent")

    do {
      let (_, response) = try await dataWithoutFollowingRedirects(for: request)
      if let httpResponse = response as? HTTPURLResponse {
        if let location = httpResponse.value(forHTTPHeaderField: "Location") {
          Log.extractionDood.debug("GET redirect location: \(location, privacy: .public)")
          if isValidFinalVideoUrl(location) {
            return location
          }
        }
      }
    } catch {
      if let finalUrl = finalUrlFromError(error) {
        return finalUrl
      }
      Log.extractionDood.error("Error resolving URL with GET: \(error.localizedDescription, privacy: .public)")
    }
    return nil
  }

  private static func dataWithoutFollowingRedirects(for request: URLRequest) async throws -> (Data, URLResponse) {
    let delegate = NoRedirectURLSessionDelegate()
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    return try await session.data(for: request)
  }

  private static func finalUrlFromError(_ error: Error) -> String? {
    let nsError = error as NSError
    let keys = [NSURLErrorFailingURLStringErrorKey, "NSErrorFailingURLStringKey"]
    for key in keys {
      if let url = nsError.userInfo[key] as? String, isValidFinalVideoUrl(url) {
        return url
      }
    }
    if let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
       isValidFinalVideoUrl(url.absoluteString) {
      return url.absoluteString
    }
    return nil
  }

#if DEBUG
  static func extractPlaymogoPassPathForTesting(from html: String) -> String? {
    extractPlaymogoPassPath(from: html)
  }

  static func extractPlaymogoTokenPrefixForTesting(from html: String) -> String? {
    extractPlaymogoTokenPrefix(from: html)
  }

  static func extractEmbeddedPlayerURLForTesting(from html: String, pageURL: URL) -> URL? {
    extractEmbeddedPlayerURL(from: html, pageURL: pageURL)
  }

  static func alternatePlaymogoURLForTesting(_ url: URL, force: Bool = false) -> URL? {
    alternatePlaymogoURL(for: url, force: force)
  }
#endif

  enum DoodStreamError: LocalizedError {
  case noVideoSource
  case networkError

  var errorDescription: String? {
    switch self {
    case .noVideoSource:
      return "DoodStream could not extract a video source. The video may have expired or been removed."
    case .networkError:
      return "Failed to fetch the DoodStream page."
    }
  }
  }
}

private final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
