import Foundation

enum RemoteFileTextPolicy {
    static let maxEditableBytes: Int64 = 1_000_000

    static let editableExtensions: Set<String> = [
        "txt", "md", "json", "yaml", "yml", "xml", "csv",
        "srt", "vtt", "log", "conf", "config", "ini",
        "nfo", "m3u", "m3u8", "sh", "py", "js", "html", "css"
    ]

    static func isLikelyTextEditable(_ item: RemoteFileItem) -> Bool {
        guard item.kind == .file else { return false }

        if let size = item.size, size > maxEditableBytes {
            return false
        }

        let ext = (item.name as NSString).pathExtension.lowercased()
        if editableExtensions.contains(ext) {
            return true
        }

        if let contentType = item.contentType?.lowercased() {
            return contentType.hasPrefix("text/")
                || contentType.contains("json")
                || contentType.contains("xml")
                || contentType.contains("yaml")
        }

        return false
    }
}
