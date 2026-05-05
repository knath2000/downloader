import Foundation

struct HomeURLInputModel: Equatable {
    let rawText: String

    var lines: [String] {
        rawText
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var validURLs: [String] {
        lines.filter(Self.isLikelyURL)
    }

    var invalidLines: [String] {
        lines.filter { !Self.isLikelyURL($0) }
    }

    var readyCount: Int {
        validURLs.count
    }

    var helperText: String {
        if lines.isEmpty {
            return "Paste one video URL per line, or drag URLs here."
        }
        if invalidLines.isEmpty {
            return "\(readyCount) URL\(readyCount == 1 ? "" : "s") ready."
        }
        return "\(invalidLines.count) line\(invalidLines.count == 1 ? "" : "s") need attention."
    }

    static func isLikelyURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && url.host != nil
    }
}
