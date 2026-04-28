import Foundation

/// Extracts video sources from doodstream.com / dood.wf / doodstream.org.
/// DoodStream exposes a direct MP4 URL via a JavaScript player on the page.
/// The video URL can be found via a p.a.c.k.e.r unpack or by direct JS config patterns.
struct DoodStreamExtractor: VideoSiteExtractor {
  private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

  static func supports(_ url: URL) -> Bool {
    guard let host = url.host()?.lowercased() else { return false }
    return host == "doodstream.com" || host == "doodstream.org" || host == "dood.wf" || host == "dood.pm"
      || host == "dood.to" || host == "dood.ws" || host == "dood.one" || host == "dood.watch" || host == "dood.la"
      || host == "dood.sh" || host == "playmogo.com"
      || host.hasSuffix(".doodstream.com") || host.hasSuffix(".doodstream.org") || host.hasSuffix(".dood.wf")
      || host.hasSuffix(".dood.pm") || host.hasSuffix(".dood.to") || host.hasSuffix(".dood.ws")
      || host.hasSuffix(".dood.one") || host.hasSuffix(".dood.watch") || host.hasSuffix(".dood.la")
      || host.hasSuffix(".dood.sh") || host == "www.playmogo.com"
  }

  static func extract(fromHTML html: String, url: URL) async throws -> VideoSource {
    // 1. Convert /d/ to /e/ to ensure we hit the embed player
    var targetUrl = url
    if targetUrl.path.starts(with: "/d/") {
      var comps = URLComponents(url: targetUrl, resolvingAgainstBaseURL: false)
      comps?.path = targetUrl.path.replacingOccurrences(of: "/d/", with: "/e/")
      if let newUrl = comps?.url {
        targetUrl = newUrl
      }
    }

    let host = targetUrl.host()?.lowercased() ?? ""
    var title = ""
    var thumbnail: String? = nil
    var finalVideoUrl: String?

    // Playmogo: Try HTML parsing first (faster and avoids WebView issues)
    if host.contains("playmogo") {
      print("Playmogo detected. Trying HTML parsing first...")
      
      // Fetch the page HTML
      if let pageHtml = try? await fetchPage(url: targetUrl) {
        title = extractTitle(from: pageHtml) ?? "Playmogo Video"
        thumbnail = extractThumbnail(from: pageHtml)
        
        // Try multiple extraction methods
        // 1. Look for dood.video URLs in HTML (must contain dood.video AND be a valid video URL)
        let doodVideoRegex = try? NSRegularExpression(pattern: "https://[^\"'\\s]*dood\\.video[^\"'\\s]*", options: [])
        if let matches = doodVideoRegex?.matches(in: pageHtml, options: [], range: NSRange(pageHtml.startIndex..., in: pageHtml)) {
          for match in matches {
            if let range = Range(match.range, in: pageHtml) {
              let potentialUrl = String(pageHtml[range])
              // Validate: must contain dood.video AND have .mp4 or token= or key= (not just any dood.video URL)
              if potentialUrl.contains("dood.video") && (potentialUrl.contains(".mp4") || potentialUrl.contains("token=") || potentialUrl.contains("key=")) {
                finalVideoUrl = potentialUrl
                print("[DoodStream] Found valid dood.video URL via HTML regex: \(potentialUrl)")
                break
              } else {
                print("[DoodStream] Skipping invalid dood.video URL: \(potentialUrl)")
              }
            }
          }
        }
        
        // 2. Try standard extraction methods
        if finalVideoUrl == nil {
          if let foundUrl = findVideoUrl(in: pageHtml) ?? findVideoUrlViaPacker(pageHtml) {
            // Validate the URL
            if foundUrl.contains("dood.video") && (foundUrl.contains(".mp4") || foundUrl.contains("token=") || foundUrl.contains("key=")) {
              finalVideoUrl = foundUrl
              print("[DoodStream] Found valid dood.video URL via standard extraction: \(foundUrl)")
            } else {
              print("[DoodStream] Skipping invalid URL from standard extraction: \(foundUrl)")
            }
          }
        }
        
        // 3. If still no valid URL, try WebView as last resort
        if finalVideoUrl == nil {
          print("HTML parsing failed to find valid dood.video URL. Falling back to WebViewExtractor...")
          do {
            finalVideoUrl = try await WebViewExtractor.shared.extractVideoUrl(from: targetUrl, timeout: 90)
            
            // Validate extracted URL
            if let url = finalVideoUrl {
              if url.contains("dood.video") && (url.contains(".mp4") || url.contains("token=") || url.contains("key=")) {
                print("[DoodStream] WebView extracted valid URL: \(url)")
              } else {
                print("[DoodStream] Warning: WebView extracted URL does not contain valid dood.video: \(url)")
                finalVideoUrl = nil // Reject invalid URL
              }
            }
          } catch {
            print("[DoodStream] WebView extraction failed: \(error)")
            finalVideoUrl = nil
          }
        }
      } else {
        print("Failed to fetch page HTML, trying WebView directly...")
        do {
          finalVideoUrl = try await WebViewExtractor.shared.extractVideoUrl(from: targetUrl, timeout: 90)
          if let url = finalVideoUrl, !(url.contains("dood.video") && (url.contains(".mp4") || url.contains("token=") || url.contains("key="))) {
            print("[DoodStream] Warning: WebView URL invalid, rejecting: \(url)")
            finalVideoUrl = nil
          }
        } catch {
          print("[DoodStream] WebView extraction failed: \(error)")
          finalVideoUrl = nil
        }
      }
      
    } else {
      // Standard DoodStream domains
      let pageHtml = html.isEmpty ? ((try? await fetchPage(url: targetUrl)) ?? "") : html
      title = extractTitle(from: pageHtml) ?? "DoodStream Video"
      thumbnail = extractThumbnail(from: pageHtml)

      if !pageHtml.isEmpty {
        finalVideoUrl = findVideoUrl(in: pageHtml) ?? findVideoUrlViaPacker(pageHtml)
      }

      if finalVideoUrl == nil {
        print("Static extraction failed. Falling back to WebViewExtractor...")
        finalVideoUrl = try? await WebViewExtractor.shared.extractVideoUrl(from: targetUrl, timeout: 25)

        // Validate extracted URL
        if let url = finalVideoUrl, !url.contains("dood.video") {
            print("[DoodStream] Warning: Fallback extracted URL does not contain 'dood.video': \(url)")
        }
      }
    }

    // Additional fallback: If still no valid URL for Playmogo, try URL resolution on any candidate
    if finalVideoUrl == nil && host.contains("playmogo") {
      print("[DoodStream] All extraction failed for Playmogo, trying URL resolution on page HTML...")
      if let htmlContent = try? await fetchPage(url: targetUrl) {
        // Look for any potential video URL pattern
        let urlRegex = try? NSRegularExpression(pattern: "https://[^\"'\\s]+/d/[^\"'\\s]+", options: [])
        if let matches = urlRegex?.matches(in: htmlContent, options: [], range: NSRange(htmlContent.startIndex..., in: htmlContent)),
           let firstMatch = matches.first,
           let range = Range(firstMatch.range, in: htmlContent) {
          let candidateUrl = String(htmlContent[range])
          print("[DoodStream] Found candidate URL: \(candidateUrl)")
          // Try to resolve it
          if let resolvedUrl = await resolveUrl(candidateUrl) {
            if resolvedUrl.contains("dood.video") {
              finalVideoUrl = resolvedUrl
              print("[DoodStream] Resolved to valid dood.video URL: \(resolvedUrl)")
            }
          }
        }
      }
    }

    // If we have a cloudatacdn.com URL, try to resolve it to the final dood.video URL
    if let currentUrl = finalVideoUrl, currentUrl.contains("cloudatacdn.com") {
      print("[DoodStream] Detected intermediate CDN URL, attempting to resolve final URL...")
      if let resolvedUrl = await resolveUrl(currentUrl) {
        if resolvedUrl.contains("dood.video") {
          finalVideoUrl = resolvedUrl
          print("[DoodStream] Resolved to final dood.video URL: \(resolvedUrl)")
        } else {
          print("[DoodStream] Resolved URL is not a dood.video URL: \(resolvedUrl)")
        }
      } else {
        print("[DoodStream] Failed to resolve intermediate URL")
      }
    }

    guard var videoUrl = finalVideoUrl else {
      throw DoodStreamError.noVideoSource
    }

    // Final validation: ensure URL contains dood.video
    if !videoUrl.contains("dood.video") {
      print("[DoodStream] ERROR: Final URL does not contain dood.video: \(videoUrl)")
      throw DoodStreamError.noVideoSource
    }

    return VideoSource(
      mp4: videoUrl,
      hls: [VideoSource.Quality(
        label: "Video",
        url: videoUrl,
        kind: .direct,
        sourcePageUrl: targetUrl.absoluteString
      )],
      title: title,
      thumbnail: thumbnail,
      siteName: host.contains("playmogo") ? "Playmogo" : "DoodStream"
    )
  }

  // MARK: - Page Fetching

  private static func fetchPage(url: URL) async throws -> String {
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 15

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse,
    (200...299).contains(httpResponse.statusCode),
    let html = String(data: data, encoding: .utf8) else {
      throw DoodStreamError.networkError
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
      pattern: #"<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)[\"']"#,
      options: .caseInsensitive
    ).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
    let range = Range(match.range(at: 1), in: html) {
      return String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
  }

  // MARK: - Video URL extraction

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
  let regex = try? NSRegularExpression(pattern: pattern, options: [])
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

    var request = URLRequest(url: urlObj)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 30
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      if let httpResponse = response as? HTTPURLResponse {
        // Check if there was a redirect
        if let location = httpResponse.value(forHTTPHeaderField: "Location") {
          print("[DoodStream] Redirect location: \(location)")
          // If the location is still a CDN, try to resolve it recursively
          if location.contains("cloudatacdn.com") {
            return await resolveUrl(location)
          }
          return location
        }
        // If no redirect but status is OK, return the original URL
        if httpResponse.statusCode == 200 {
          return url
        }
        // If status is a redirect (3xx) but no Location header, try GET instead
        if (300...399).contains(httpResponse.statusCode) {
          print("[DoodStream] Redirect status \(httpResponse.statusCode) without Location header, trying GET...")
          return await resolveUrlWithGet(url: url)
        }
      }
    } catch {
      print("[DoodStream] Error resolving URL with HEAD: \(error)")
      // Try GET as fallback
      return await resolveUrlWithGet(url: url)
    }
    return nil
  }

  private static func resolveUrlWithGet(url: String) async -> String? {
    guard let urlObj = URL(string: url) else { return nil }

    var request = URLRequest(url: urlObj)
    request.httpMethod = "GET"
    request.timeoutInterval = 30
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      if let httpResponse = response as? HTTPURLResponse {
        if let location = httpResponse.value(forHTTPHeaderField: "Location") {
          print("[DoodStream] GET redirect location: \(location)")
          if location.contains("cloudatacdn.com") {
            return await resolveUrlWithGet(url: location)
          }
          return location
        }
        if httpResponse.statusCode == 200 {
          return url
        }
      }
    } catch {
      print("[DoodStream] Error resolving URL with GET: \(error)")
    }
    return nil
  }

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
