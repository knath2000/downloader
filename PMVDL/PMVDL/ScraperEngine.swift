import Foundation

struct ToolLocator {
 static func find(_ executable: String, extraPaths: [String] = []) -> URL? {
  for path in extraPaths {
   if let trusted = trustedExecutable(atPath: path) {
    return trusted
   }
  }
  for directory in searchDirectories() {
   let path = (directory as NSString).appendingPathComponent(executable)
   if let trusted = trustedExecutable(atPath: path) {
    return trusted
   }
  }
  return nil
 }

 private static func trustedExecutable(atPath path: String) -> URL? {
  let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
  return FileManager.default.isExecutableFile(atPath: resolved.path) ? resolved : nil
 }

 private static func searchDirectories() -> [String] {
  let defaults = [
   "/opt/homebrew/bin",
   "/opt/homebrew/sbin",
   "/usr/local/bin",
   "/usr/local/sbin",
   "/opt/local/bin",
   "/usr/bin",
   "/bin",
   "/usr/sbin",
   "/sbin"
  ]

  var seen = Set<String>()
  return defaults.filter { path in
   guard !path.isEmpty, !seen.contains(path) else { return false }
   seen.insert(path)
   return true
  }
 }
}

/// Protocol all site extractors must implement.
protocol VideoSiteExtractor {
 static func supports(_ url: URL) -> Bool
 static func extract(fromHTML html: String, url: URL) async throws -> VideoSource
}

/// Central router that dispatches URLs to the correct extractor.
struct ScraperEngine {
 static let extractors: [any VideoSiteExtractor.Type] = [
  NativeVideoPageExtractor.self,
  VidaraExtractor.self, // Native extractor for vidara.so
  LuluStreamExtractor.self, // Native extractor for luluvid/luluvdo/lulustream
  ProviderLinkExtractor.self,
  StreamTapeExtractor.self, // Native extractor for streamtape.com / streamtape.net
  MixDropExtractor.self, // Native extractor for mixdrop.co / mixdrop.sx / mixdrop.pw
  DoodStreamExtractor.self, // Native extractor for doodstream.com / dood.wf
  HQPornerExtractor.self, // Native extractor for hqporner.com
  M3U8Extractor.self, // Raw HLS stream handler
  YtDlpExtractor.self, // General: covers 1700+ sites (fallback — broad URL match)
 ]

 static func findExtractor(for url: URL) -> (any VideoSiteExtractor.Type)? {
  for extractor in extractors {
   if extractor.supports(url) { return extractor }
  }
  return nil
 }

 static func extract(from urlString: String) async throws -> VideoSource {
  try await extractWithProgress(from: urlString, onProgress: nil)
 }

 static func extractWithProgress(from urlString: String, onProgress: (@Sendable (String) -> Void)?) async throws -> VideoSource {
  guard let url = URLTrustPolicy.validated(urlString) else { throw VideoExtractorError.invalidURL }
  onProgress?("Validating page URL…")
  if let extractor = findExtractor(for: url) {
   let source: VideoSource
   do {
    if extractor == ProviderLinkExtractor.self {
     onProgress?("Reading provider sources from the page…")
     source = try await ProviderLinkExtractor.extract(fromHTML: "", url: url, onProgress: onProgress)
    } else {
     onProgress?("Extracting with \(String(describing: extractor))…")
     source = try await extractor.extract(fromHTML: "", url: url)
    }
   } catch {
    onProgress?("Source failed • stage: page extraction • source: \(String(describing: extractor)) • reason: \(error.localizedDescription)")
    throw error
   }
   let count = source.hls.filter { $0.kind != .pageUrl }.count + (source.mp4 == nil ? 0 : 1)
   onProgress?("Found \(count) downloadable source\(count == 1 ? "" : "s")")
   return source.withResolutionMethod(resolutionMethod(for: extractor))
  }
  throw VideoExtractorError.noVideoSources
 }

 private static func resolutionMethod(for extractor: any VideoSiteExtractor.Type) -> String {
  if extractor == YtDlpExtractor.self { return "yt-dlp" }
  if extractor == M3U8Extractor.self { return "Direct stream" }
  return "Static page parser"
 }

 static var isYTDLPAvailable: Bool { ToolLocator.find("yt-dlp") != nil }

 static var isFFmpegAvailable: Bool { VideoProcessor.findFFmpeg() != nil }
}

struct ExtractionCoordinator {
 static func extract(from urlString: String) async throws -> VideoSource {
  try await extractWithProgress(from: urlString, onProgress: nil)
 }

 static func extractWithProgress(from urlString: String, onProgress: (@Sendable (String) -> Void)?) async throws -> VideoSource {
  guard let url = URLTrustPolicy.validated(urlString) else { throw VideoExtractorError.invalidURL }
  onProgress?("Trying cloud extraction…")
  do {
   let result = try await LustreAgentController.shared.preview(url: url)
   try Task.checkCancellation()
   if result.resolutionState == "resolved",
      let resolution = result.resolution,
      !resolution.qualities.isEmpty {
    let source = videoSource(from: resolution)
    let provenance = resolution.qualities.contains { $0.resolutionMethod.localizedCaseInsensitiveContains("cloud") }
      ? "cloud"
      : "local Agent"
    onProgress?("Resolved with \(provenance) extraction.")
    return source
   }
   onProgress?("Agent could not resolve this page — trying native extraction…")
  } catch is CancellationError {
   throw CancellationError()
  } catch {
   try Task.checkCancellation()
   onProgress?("Cloud or Agent unavailable — trying native extraction…")
  }
  return try await ScraperEngine.extractWithProgress(from: urlString, onProgress: onProgress)
 }

 private static func videoSource(from resolution: LustreAgentResolution) -> VideoSource {
  let qualities = resolution.qualities.map { quality in
   VideoSource.Quality(
    label: quality.label,
    url: quality.url.absoluteString,
    kind: quality.mediaKind == .hls ? .hlsManifest : quality.mediaKind == .ytDlp ? .pageUrl : .direct,
    headers: quality.headers.isEmpty ? nil : quality.headers,
    sourcePageUrl: resolution.sourcePageURL.absoluteString,
    resolutionMethod: quality.resolutionMethod
   )
  }
  let direct = qualities.first(where: { $0.kind == .direct })?.url
  return VideoSource(
   mp4: direct,
   hls: qualities,
   title: resolution.title,
   thumbnail: resolution.thumbnailURL?.absoluteString,
   siteName: resolution.provider,
   headers: qualities.first?.headers,
   resolutionMethod: qualities.first?.resolutionMethod
  )
 }
}
