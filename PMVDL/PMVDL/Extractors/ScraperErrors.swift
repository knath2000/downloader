import Foundation

enum ScraperError: LocalizedError {
    case toolNotInstalled(name: String, installCmd: String)
    case extractionFailed(String)
    case pageFetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolNotInstalled(let name, let cmd):
            return "\(name) not installed. Run: \(cmd)"
        case .extractionFailed(let m):
            return "Extraction failed: \(m)"
        case .pageFetchFailed(let u):
            return "Could not fetch page: \(u)"
        }
    }
}
