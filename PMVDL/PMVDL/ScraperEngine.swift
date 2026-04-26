import Foundation

/// Protocol all site extractors must implement.
protocol VideoSiteExtractor {
 static func supports(_ url: URL) -> Bool
 static func extract(fromHTML html: String, url: URL) async throws -> VideoSource
}

/// Central router that dispatches URLs to the correct extractor.
struct ScraperEngine {
 static let extractors: [any VideoSiteExtractor.Type] = [
  PMVHavenExtractor.self, // Optimized native extractor for pmvhaven.com
  VidaraExtractor.self, // Native extractor for vidara.so
  LuluStreamExtractor.self, // Native extractor for luluvid/luluvdo/lulustream
  AllPornStreamExtractor.self, // Native extractor for allpornstream.com Next.js RSC payload
  StreamTapeExtractor.self, // Native extractor for streamtape.com / streamtape.net
  MixDropExtractor.self, // Native extractor for mixdrop.co / mixdrop.sx / mixdrop.pw
  DoodStreamExtractor.self, // Native extractor for doodstream.com / dood.wf
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
  guard let url = URL(string: urlString) else { throw PMVDLError.invalidURL }
  if let extractor = findExtractor(for: url) {
   return try await extractor.extract(fromHTML: "", url: url)
  }
  throw PMVDLError.noVideoSources
 }

 static var isYTDLPAvailable: Bool {
  ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"].contains {
   FileManager.default.fileExists(atPath: $0)
  }
 }

 static var isFFmpegAvailable: Bool {
  ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].contains {
   FileManager.default.fileExists(atPath: $0)
  }
 }
}