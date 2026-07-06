import Foundation

/// Extracts video sources from vidara.so pages.
struct VidaraExtractor: VideoSiteExtractor {
    private static let apiURL = URL(string: "https://vidara.so/api/stream")!
    private static let hlsHeaders = [
        "User-Agent": NetworkConstants.chromeUserAgent,
        "Referer": "https://vidara.so/"
    ]

    static func supports(_ url: URL) -> Bool {
        url.host()?.lowercased().contains("vidara.so") ?? false
    }

    static func extract(fromHTML: String, url: URL) async throws -> VideoSource {
        // Extract filecode from URL path: /v/<filecode>, /e/<filecode>, or /d/<filecode>
        let filecode = try extractFilecode(from: url)

        // Call the API to get streaming info
        let videoInfo = try await fetchStreamInfo(filecode: filecode)

        // Build VideoSource from API response
        let streamingUrl = videoInfo.streamingUrl
        guard let hlsUrl = streamingUrl, !hlsUrl.isEmpty else {
            throw VideoExtractorError.noVideoSources
        }

        // Try to parse master playlist for variant labels
        let hls = try await parseHlsVariants(masterUrl: hlsUrl, sourcePageUrl: url.absoluteString)

        return VideoSource(
            mp4: nil,
            hls: hls,
            title: videoInfo.title,
            thumbnail: videoInfo.thumbnail,
            siteName: "Vidara"
        )
    }

    // MARK: - Helpers

    private static func extractFilecode(from url: URL) throws -> String {
        let path = url.path
        let pattern = #"/[ved]/([a-zA-Z0-9_-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range(at: 1), in: path) else {
            throw VideoExtractorError.invalidURL
        }
        return String(path[range])
    }

    private static func parseHlsVariants(masterUrl: String, sourcePageUrl: String) async throws -> [VideoSource.Quality] {
        guard let url = URL(string: masterUrl) else {
            return [vidaraQuality(label: "master", url: masterUrl, sourcePageUrl: sourcePageUrl)]
        }

        var request = URLRequest(url: url)
        hlsHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let playlist = String(data: data, encoding: .utf8) else {
            return [vidaraQuality(label: "master", url: masterUrl, sourcePageUrl: sourcePageUrl)]
        }

        return parseHlsVariants(playlist: playlist, masterUrl: masterUrl, sourcePageUrl: sourcePageUrl)
    }

    private static func parseHlsVariants(playlist: String, masterUrl: String, sourcePageUrl: String) -> [VideoSource.Quality] {
        guard let url = URL(string: masterUrl) else {
            return [vidaraQuality(label: "master", url: masterUrl, sourcePageUrl: sourcePageUrl)]
        }

        var variants: [VideoSource.Quality] = []
        let lines = playlist.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }

        for (i, line) in lines.enumerated() {
            guard line.hasPrefix("#EXT-X-STREAM-INF") else { continue }

            // Find URL on next line
            guard i + 1 < lines.count, let variantUrl = URL(string: lines[i + 1], relativeTo: url) else { continue }

            // Extract HEIGHT from RESOLUTION=WIDTHxHEIGHT
            let label: String
            if let match = NSRegularExpression.firstNumberGroup(in: line, pattern: "RESOLUTION=\\d+x(\\d+)"),
               let height = Int(match) {
                label = heightToLabel(height)
            } else {
                label = "stream"
            }

            variants.append(vidaraQuality(label: label, url: variantUrl.absoluteString, sourcePageUrl: sourcePageUrl))
        }

        return variants.isEmpty ? [vidaraQuality(label: "master", url: masterUrl, sourcePageUrl: sourcePageUrl)] : variants
    }

    private static func vidaraQuality(label: String, url: String, sourcePageUrl: String) -> VideoSource.Quality {
        VideoSource.Quality(label: label, url: url, headers: hlsHeaders, sourcePageUrl: sourcePageUrl)
    }

    private static func heightToLabel(_ height: Int) -> String {
        switch height {
        case 2160...: return "2160p"
        case 1440...: return "1440p"
        case 1080...: return "1080p"
        case 720...: return "720p"
        case 480...: return "480p"
        case 360...: return "360p"
        default: return "\(height)p"
        }
    }

    private static func fetchStreamInfo(filecode: String) async throws -> VidaraStreamInfo {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://vidara.so/", forHTTPHeaderField: "Referer")

        let body = ["filecode": filecode, "device": "web"]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw VideoExtractorError.network(
                NSError(domain: "VidDL", code: -1, userInfo: [NSLocalizedDescriptionKey: "API request failed"])
            )
        }

        let decoder = JSONDecoder()
        return try decoder.decode(VidaraStreamInfo.self, from: data)
    }

#if DEBUG
    static func extractFilecodeForTesting(from url: URL) throws -> String {
        try extractFilecode(from: url)
    }

    static func parseHlsVariantsForTesting(
        playlist: String,
        masterUrl: String,
        sourcePageUrl: String
    ) -> [VideoSource.Quality] {
        parseHlsVariants(playlist: playlist, masterUrl: masterUrl, sourcePageUrl: sourcePageUrl)
    }
#endif
}

// MARK: - Regex Helper

extension NSRegularExpression {
    static func firstNumberGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }
}

// MARK: - API Response Model

private struct VidaraStreamInfo: Codable {
    let streamingUrl: String?
    let title: String?
    let thumbnail: String?

    enum CodingKeys: String, CodingKey {
        case streamingUrl = "streaming_url"
        case title
        case thumbnail
    }
}
