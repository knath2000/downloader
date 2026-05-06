import Foundation

enum RemotePath {
    static func normalizeDirectory(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        let collapsed = "/" + trimmed
            .split(separator: "/")
            .filter { !$0.isEmpty }
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

    static func sanitizeNameComponent(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "")
    }

    static func rclonePath(remoteName: String, directory: String) -> String {
        let dir = normalizeDirectory(directory)
        if dir == "/" {
            return "\(remoteName):"
        }
        return "\(remoteName):\(String(dir.dropFirst()))/"
    }

    static func rcloneFile(remoteName: String, path: String) -> String {
        let normalized = normalizeDirectory(path)
        if normalized == "/" {
            return "\(remoteName):"
        }
        return "\(remoteName):\(String(normalized.dropFirst()))"
    }
}
