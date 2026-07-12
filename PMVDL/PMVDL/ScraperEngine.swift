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
  guard let url = URLTrustPolicy.validated(urlString) else { throw VideoExtractorError.invalidURL }
  if let extractor = findExtractor(for: url) {
   return try await extractor.extract(fromHTML: "", url: url)
  }
  throw VideoExtractorError.noVideoSources
 }

 static var isYTDLPAvailable: Bool { ToolLocator.find("yt-dlp") != nil }

 static var isFFmpegAvailable: Bool { VideoProcessor.findFFmpeg() != nil }
}
