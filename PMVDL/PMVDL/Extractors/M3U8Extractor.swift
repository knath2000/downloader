import Foundation

/// Generic HLS stream handler for direct .m3u8 URLs.
struct M3U8Extractor: VideoSiteExtractor {
    static func supports(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8"
    }

    static func extract(fromHTML: String, url: URL) async throws -> VideoSource {
        // Return the m3u8 URL as-is; no MP4 available for raw HLS streams
        let quality = VideoSource.Quality(label: "stream", url: url.absoluteString)
        return VideoSource(mp4: nil, hls: [quality], title: url.lastPathComponent, siteName: "HLS Stream")
    }
}
