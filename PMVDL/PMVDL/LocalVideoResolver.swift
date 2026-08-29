import Foundation

/// Resolves a `LibraryItem` to a local file URL on disk, if the file has been
/// downloaded to the configured download directory.
///
/// Strategy:
/// 1. If `remotePaths[CloudTarget.local]` is set and the file exists → use it.
/// 2. Otherwise, derive the canonical filename from `mp4Url` (or `url` as a
///    fallback) via `VideoFileNaming.mp4FileName` and check whether it exists
///    in `DownloadPaths.downloadDir`.
///
/// This is intentionally synchronous and cheap — the only I/O is a single
/// `fileExists` stat per call. Callers should use it from the main thread when
/// rendering cards; missing files just return `nil` so the static thumbnail
/// is shown instead.
enum LocalVideoResolver {
    /// Resolve a `LibraryItem` to a local file URL, if the file is on disk.
    static func localURL(for item: LibraryItem) -> URL? {
        // Fast path: an explicit local path recorded by the download pipeline.
        if let localPath = item.remotePaths[CloudTarget.local.rawValue],
           !localPath.isEmpty {
            let url = URL(fileURLWithPath: localPath, isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        // Slow path: derive the canonical filename from the source URL and
        // check the configured download directory.
        let candidateTitle = item.mp4Url ?? item.url
        guard let filename = try? deriveFileName(forSource: candidateTitle, fallbackTitle: item.title) else {
            return nil
        }
        let candidate = DownloadPaths.downloadDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// Best-effort local URL by source URL alone (used during early-extraction
    /// states where `LibraryItem` may not yet be persisted).
    static func localURL(sourceURL: String, title: String?) -> URL? {
        guard let filename = try? deriveFileName(forSource: sourceURL, fallbackTitle: title) else {
            return nil
        }
        let candidate = DownloadPaths.downloadDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// Derive a candidate filename matching what the downloader would have
    /// written. We try the URL-derived title first, then the human-readable
    /// title, then a generic fallback — `VideoFileNaming.sanitizedBaseName`
    /// handles the rest.
    private static func deriveFileName(forSource sourceURL: String, fallbackTitle: String?) throws -> String {
        // Prefer the URL's last path component (often the source video slug).
        if let url = URL(string: sourceURL) {
            let lastComponent = url.lastPathComponent
            if !lastComponent.isEmpty, lastComponent != "/" {
                let name = VideoFileNaming.mp4FileName(
                    title: lastComponent.removingPercentEncoding ?? lastComponent,
                    fallback: fallbackTitle ?? lastComponent
                )
                return name
            }
        }
        return VideoFileNaming.mp4FileName(title: fallbackTitle, fallback: "video")
    }
}
