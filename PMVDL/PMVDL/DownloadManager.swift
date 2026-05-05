import Foundation
import AppKit

actor DownloadManager {
    static let shared = DownloadManager()

    private let directDownloader = DirectDownloader()
    private let hlsDownloader = HLSDownloader()
    private let ytDlpRunner = YtDlpRunner()

    private init() {
        DownloadPaths.ensureDownloadDir()
    }

    func downloadViaYTDLPSite(pageUrl: String, title: String? = nil,
                              preferredFormat: String = "mp4",
                              onProgress: @escaping (String) -> Void) async throws -> URL {
        try await ytDlpRunner.downloadViaYTDLPSite(
            pageUrl: pageUrl,
            title: title,
            preferredFormat: preferredFormat,
            onProgress: onProgress
        )
    }

    func downloadDirect(url: String, title: String? = nil,
                        headers: [String: String]? = nil,
                        onProgress: @escaping (String) -> Void) async throws -> URL {
        try await directDownloader.downloadDirect(url: url, title: title, headers: headers, onProgress: onProgress)
    }

    func downloadDirectWithDelegate(url: String, title: String? = nil,
                                    headers: [String: String]? = nil,
                                    delegate: QueueDownloadProgressDelegate) async throws -> URL {
        try await directDownloader.downloadDirectWithDelegate(url: url, title: title, headers: headers, delegate: delegate)
    }

    func downloadHLS(m3u8Url: String, title: String? = nil,
                     headers: [String: String]? = nil,
                     sourcePageUrl: String? = nil,
                     onProgress: @escaping (ProgressEvent) -> Void) async throws -> URL {
        try await hlsDownloader.downloadHLS(
            m3u8Url: m3u8Url,
            title: title,
            headers: headers,
            sourcePageUrl: sourcePageUrl,
            onProgress: onProgress
        )
    }

    func downloadAudio(pageUrl: String, title: String? = nil,
                       format: String = "mp3",
                       onProgress: @escaping (String) -> Void) async throws -> URL {
        try await ytDlpRunner.downloadAudio(pageUrl: pageUrl, title: title, format: format, onProgress: onProgress)
    }

    func downloadWithSubtitles(pageUrl: String, title: String? = nil,
                               onProgress: @escaping (String) -> Void) async throws -> URL {
        try await ytDlpRunner.downloadWithSubtitles(pageUrl: pageUrl, title: title, onProgress: onProgress)
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

enum DownloadError: LocalizedError {
    case toolNotFound(String)
    case downloadFailed(String)
    case timedOut
    case directoryNotFound(String)
    case invalidURL(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "\(name) not found. Run: brew install \(name)"
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .timedOut:
            return "Download timed out (2 hours)"
        case .directoryNotFound(let dir):
            return "Directory not found: \(dir)"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        }
    }
}
