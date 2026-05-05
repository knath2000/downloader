import Foundation

public extension String {
    func matches(for pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, range: range).compactMap {
            guard let nsRange = Range($0.range(at: 1), in: self) else { return nil }
            return String(self[nsRange])
        }
    }

    func parsePercent() -> Double? {
        guard let m = try? NSRegularExpression(pattern: "(\\d+)%$")
            .firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let r = Range(m.range(at: 1), in: self) else { return nil }
        return Double(self[r])
    }
}
