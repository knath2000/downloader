import Foundation

enum RemotePath {
    static func normalizeDirectory(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        let collapsed = "/" + trimmed
            .split(separator: "/")
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")

        return collapsed == "/" ? "/" : collapsed
    }

    static func joining(directory: String, name: String) -> String {
        let dir = normalizeDirectory(directory)
        let cleanName = sanitizeNameComponent(name)
        guard !cleanName.isEmpty else { return dir }
        if dir == "/" { return "/" + cleanName }
        return dir + "/" + cleanName
    }

    static func parent(of path: String) -> String {
        let normalized = normalizeDirectory(path)
        guard normalized != "/" else { return "/" }
        let parts = normalized.split(separator: "/").map(String.init)
        guard parts.count > 1 else { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    static func basename(_ path: String) -> String {
        normalizeDirectory(path).split(separator: "/").last.map(String.init) ?? ""
    }

    static func isDescendant(_ child: String, of parent: String) -> Bool {
        let cleanParent = normalizeDirectory(parent)
        let cleanChild = normalizeDirectory(child)
        guard cleanParent != "/", cleanChild != cleanParent else { return false }
        return cleanChild.hasPrefix(cleanParent + "/")
    }

    static func duplicateName(for name: String, existingNames: Set<String>) -> String {
        let cleanName = sanitizeNameComponent(name)
        let lowercasedExisting = Set(existingNames.map { $0.lowercased() })
        guard lowercasedExisting.contains(cleanName.lowercased()) else {
            return cleanName
        }

        let (base, ext) = splitName(cleanName)
        var index = 1

        while true {
            let suffix = index == 1 ? " copy" : " copy \(index)"
            let candidate = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            if !lowercasedExisting.contains(candidate.lowercased()) {
                return candidate
            }
            index += 1
        }
    }

    static func sanitizeNameComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeNameComponent(trimmed) else { return "" }
        return trimmed
    }

    static func isSafeNameComponent(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != "..",
              !trimmed.contains("/"), !trimmed.contains("\\") else { return false }
        return !trimmed.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
    }

    static func rclonePath(remoteName: String, directory: String) -> String {
        let dir = normalizeDirectory(directory)
        if dir == "/" {
            return "\(remoteName):"
        }
        return "\(remoteName):\(String(dir.dropFirst()))/"
    }

    static func rcloneAbsolutePath(remoteName: String, directory: String) -> String {
        let dir = normalizeDirectory(directory)
        if dir == "/" {
            return "\(remoteName):/"
        }
        return "\(remoteName):\(dir)/"
    }

    static func rcloneFile(remoteName: String, path: String) -> String {
        let normalized = normalizeDirectory(path)
        if normalized == "/" {
            return "\(remoteName):"
        }
        return "\(remoteName):\(String(normalized.dropFirst()))"
    }

    static func rcloneAbsoluteFile(remoteName: String, path: String) -> String {
        let normalized = normalizeDirectory(path)
        if normalized == "/" {
            return "\(remoteName):/"
        }
        return "\(remoteName):\(normalized)"
    }

    private static func splitName(_ name: String) -> (base: String, ext: String) {
        guard let dotIndex = name.lastIndex(of: "."), dotIndex != name.startIndex else {
            return (name, "")
        }

        let base = String(name[..<dotIndex])
        let extStart = name.index(after: dotIndex)
        let ext = String(name[extStart...])
        guard !base.isEmpty, !ext.isEmpty else {
            return (name, "")
        }

        return (base, ext)
    }
}
