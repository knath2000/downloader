import Foundation

struct VideoScraper {
    static func extract(from urlString: String) async throws -> VideoSource {
        return try await ScraperEngine.extract(from: urlString)
    }
}
