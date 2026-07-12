import Foundation

protocol FeedScraper {
    static var supportedHost: String { get }
    static func fetchPage(page: Int) async throws -> [FeedItem]
}

enum FeedScraperError: LocalizedError {
    case unsupportedSite(String)
    case invalidPage
    case missingStructuredData
    case invalidStructuredData
    case network(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSite(let host): return "Feed is not available for \(host)."
        case .invalidPage: return "The feed page could not be loaded."
        case .missingStructuredData: return "The feed page did not include video metadata."
        case .invalidStructuredData: return "The feed metadata could not be decoded."
        case .network(let status): return "Feed request failed with HTTP \(status)."
        }
    }
}

enum ISO8601DurationParser {
    static func seconds(from value: String) -> Int? {
        let trimmed = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("pt") else { return nil }

        let pattern = #"^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
              match.numberOfRanges >= 4 else {
            return nil
        }

        var total = 0
        if match.range(at: 1).location != NSNotFound,
           let hours = Range(match.range(at: 1), in: trimmed).flatMap({ Int(trimmed[$0]) }) {
            total += hours * 3600
        }
        if match.range(at: 2).location != NSNotFound,
           let minutes = Range(match.range(at: 2), in: trimmed).flatMap({ Int(trimmed[$0]) }) {
            total += minutes * 60
        }
        if match.range(at: 3).location != NSNotFound,
           let seconds = Range(match.range(at: 3), in: trimmed).flatMap({ Int(trimmed[$0]) }) {
            total += seconds
        }
        return total > 0 ? total : nil
    }
}

struct JSONLDVideoObject: Decodable {
    let position: Int?
    let name: String
    let url: String
    let thumbnailUrl: String?
    let uploadDate: String
    let interactionStatistic: JSONLDInteractionStatistic?
    let duration: String?
}

struct JSONLDInteractionStatistic: Decodable {
    let userInteractionCount: FlexibleInt
}

struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let string = try? container.decode(String.self),
                  let int = Int(string) {
            value = int
        } else {
            value = 0
        }
    }
}
