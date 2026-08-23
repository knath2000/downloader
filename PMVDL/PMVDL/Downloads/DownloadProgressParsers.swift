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

    static func transferMetrics(from text: String) -> DownloadTransferMetrics? {
        var metrics = DownloadTransferMetrics()

        if let match = try? NSRegularExpression(
            pattern: "of\\s+~?([\\d.]+)\\s*([KMGT]?i?B|[KMGT]?B)",
            options: [.caseInsensitive]
        ).firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
           let amountRange = Range(match.range(at: 1), in: text),
           let unitRange = Range(match.range(at: 2), in: text),
           let amount = Double(text[amountRange]) {
            metrics.totalBytes = bytes(amount, unit: String(text[unitRange]))
        }

        if let match = try? NSRegularExpression(
            pattern: "at\\s+([\\d.]+)\\s*([KMGT]?i?B|[KMGT]?B)/s",
            options: [.caseInsensitive]
        ).firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
           let amountRange = Range(match.range(at: 1), in: text),
           let unitRange = Range(match.range(at: 2), in: text),
           let amount = Double(text[amountRange]) {
            metrics.bytesPerSecond = Double(bytes(amount, unit: String(text[unitRange])))
        }

        if let pct = percent(from: text),
           let totalBytes = metrics.totalBytes {
            metrics.bytesDownloaded = Int64(Double(totalBytes) * pct / 100.0)
        }

        if metrics.bytesDownloaded == nil,
           metrics.totalBytes == nil,
           metrics.bytesPerSecond == nil {
            return nil
        }
        return metrics
    }

    private static func percent(from text: String) -> Double? {
        guard let match = try? NSRegularExpression(
            pattern: "([\\d.]+)%",
            options: []
        ).firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)),
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[range])
    }

    private static func bytes(_ amount: Double, unit: String) -> Int64 {
        let normalized = unit.lowercased()
        let multiplier: Double
        switch normalized {
        case "kb", "kib":
            multiplier = 1024
        case "mb", "mib":
            multiplier = 1024 * 1024
        case "gb", "gib":
            multiplier = 1024 * 1024 * 1024
        case "tb", "tib":
            multiplier = 1024 * 1024 * 1024 * 1024
        default:
            multiplier = 1
        }
        return Int64(amount * multiplier)
    }
}
