import Foundation

enum DownloadProgressParsers {
    static func ffmpegProgressEvent(from text: String, totalDuration: TimeInterval?) -> ProgressEvent? {
        guard let match = try? NSRegularExpression(
            pattern: "time=(\\d+):(\\d+):(\\d+\\.\\d+)"
        ).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range1 = Range(match.range(at: 1), in: text),
              let range2 = Range(match.range(at: 2), in: text),
              let range3 = Range(match.range(at: 3), in: text),
              let h = Double(text[range1]),
              let m = Double(text[range2]),
              let s = Double(text[range3]) else {
            return nil
        }

        let elapsed = h * 3600 + m * 60 + s
        let pct: Double
        if let totalDuration, totalDuration > 0 {
            pct = min(99.0, elapsed / totalDuration * 100)
        } else {
            pct = min(99.0, elapsed / (30 * 60) * 100)
        }

        let timeString = String(format: "%02d:%02d:%05.2f", Int(h), Int(m), s)
        return .downloading(
            msg: "Downloading HLS… \(timeString) \(pct == 0 ? "0" : String(format: "%.1f", pct))%",
            pct: pct
        )
    }

    static func ytDlpProgressMessage(from text: String) -> String? {
        if let match = try? NSRegularExpression(
            pattern: "\\[download\\]\\s+([\\d.]+)%.*at\\s+([\\d.]+\\w+/s)"
        ).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            return "Downloading… \(text[range])"
        }

        if let match = try? NSRegularExpression(
            pattern: "\\[download\\]\\s+100%\\s+of\\s+([\\d.]+\\w+)"
        ).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range, in: text) {
            return "Downloading… \(text[range])"
        }

        return nil
    }

    static func rclonePercent(from text: String) -> Int? {
        guard let match = try? NSRegularExpression(
            pattern: "Transferred:[^\\n]*?(\\d+)%"
        ).firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              let range = Range(match.range(at: 1), in: text),
              let pct = Double(text[range]),
              pct >= 0 else {
            return nil
        }
        return Int(pct)
    }

    static func megaTransferPercent(from text: String) -> Int? {
        guard let match = try? NSRegularExpression(
            pattern: "([\\d.]+)%\\s+of"
        ).firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              let range = Range(match.range(at: 1), in: text),
              let pct = Double(text[range]) else {
            return nil
        }
        return Int(pct)
    }
}
