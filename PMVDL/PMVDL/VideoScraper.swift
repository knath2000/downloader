import Foundation

struct VideoScraper {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

    static func extract(from urlString: String) async throws -> VideoSource {
        // Delegate to the central ScraperEngine for consistency
        // This ensures ProviderLink and other sites use the same extractor pipeline
        return try await ScraperEngine.extract(from: urlString)
    }
}

public extension String {
    func matches(for pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, range: range).compactMap {
            guard let nsRange = Range($0.range(at: 1), in: self) else { return nil }
            return String(self[nsRange])
        }
    }
}