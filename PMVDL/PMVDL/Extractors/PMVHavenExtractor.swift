import Foundation

/// Extracts video sources from pmvhaven.com pages.
struct PMVHavenExtractor: VideoSiteExtractor {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

    static func supports(_ url: URL) -> Bool {
        url.host()?.contains("pmvhaven.com") ?? false
    }

    static func extract(fromHTML: String, url: URL) async throws -> VideoSource {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw PMVDLError.network(
                NSError(domain: "PMVDL", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode page"])
            )
        }

        // Find MP4 URLs
        let mp4Urls = html.matches(for: #"\"(https?://[^\s\"]+\.mp4)\""#)
        let mp4Url = mp4Urls.first

        // Find HLS URLs
        let hlsUrls = html.matches(for: #"\"(https?://[^\s\"]+\.m3u8)\""#)

        let mainBase = mp4Url.map { $0 + "/" }
        var seen = Set<String>()
        var hls: [VideoSource.Quality] = []
        var masterUrl: String?

        let resOrder = ["2160p": 0, "1440p": 1, "1080p": 2, "720p": 3, "480p": 4, "360p": 5]

        for u in hlsUrls {
            guard !seen.contains(u) else { continue }
            seen.insert(u)

            if let resMatch = u.range(of: "/(\\d+p)\\.m3u8$", options: .regularExpression),
               let mainBase, u.hasPrefix(mainBase) {
                let raw = u[resMatch]
                let res = String(raw.dropFirst().dropLast(6))
                hls.append(VideoSource.Quality(label: res, url: u))
            } else if u.hasSuffix("/master.m3u8"), let mainBase, u.hasPrefix(mainBase) {
                masterUrl = u
            }
        }

        hls.sort { a, b in
            (resOrder[a.label] ?? 99) < (resOrder[b.label] ?? 99)
        }

        if let masterUrl {
            hls.append(VideoSource.Quality(label: "master", url: masterUrl))
        }

        guard mp4Url != nil || !hls.isEmpty else {
            throw PMVDLError.noVideoSources
        }

        return VideoSource(mp4: mp4Url, hls: hls, siteName: "PMVHaven")
    }
}
