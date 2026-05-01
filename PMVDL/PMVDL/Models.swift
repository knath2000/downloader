import Foundation

// ===== EXISTING MODELS =====

struct VideoSource: Equatable {
    enum Kind: String, Codable {
        case direct      // direct file (.mp4, etc.)
        case hlsManifest // HLS .m3u8 that must be materialized via ffmpeg
        case pageUrl     // page that must go through yt-dlp
    }

    struct Quality: Equatable, Codable, Hashable {
        let label: String
        let url: String
        let kind: Kind
        let headers: [String: String]?  // e.g. ["Referer": "...", "User-Agent": "..."]
        let sourcePageUrl: String?  // LuluStream embed page URL for URL refresh at download time

        init(label: String, url: String, kind: Kind = .hlsManifest, headers: [String: String]? = nil, sourcePageUrl: String? = nil) {
            self.label = label; self.url = url; self.kind = kind; self.headers = headers; self.sourcePageUrl = sourcePageUrl
        }
    }
    let mp4: String?
    let hls: [Quality]
    let title: String?
    let thumbnail: String?
    let duration: TimeInterval?
    let uploader: String?
    let siteName: String?
    let isAudio: Bool

    init(mp4: String?, hls: [Quality], title: String? = nil, thumbnail: String? = nil, duration: TimeInterval? = nil, uploader: String? = nil, siteName: String? = nil, isAudio: Bool = false) {
        self.mp4 = mp4; self.hls = hls; self.title = title; self.thumbnail = thumbnail; self.duration = duration; self.uploader = uploader; self.siteName = siteName; self.isAudio = isAudio
    }

    var displaySiteName: String {
        SiteDisplayLabels.displayName(for: siteName)
    }
}

enum SiteDisplayLabels {
    private static let actualToDisplay = [
        "NativeVideoPage": "Video Site",
        "ProviderLink": "Video Site",
        "LuluStream": "Stream Host",
        "StreamTape": "Stream Host",
        "MixDrop": "Stream Host",
        "DoodStream": "Stream Host",
        "Playmogo": "Stream Host",
        "Vidara": "Hosted Video",
        "HLS Stream": "Direct Stream"
    ]

    static func displayName(for siteName: String?) -> String {
        guard let siteName, !siteName.isEmpty else { return "Video Site" }
        return actualToDisplay[siteName] ?? "Generic Extractor"
    }
}

enum VideoExtractorError: LocalizedError {
    case invalidURL
    case noVideoSources
    case noAudioSources
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL."
        case .noVideoSources: return "No video sources found on page."
        case .noAudioSources: return "No audio sources found on page."
        case .network(let e): return "Network error: \(e.localizedDescription)"
        }
    }
}

enum UploadState { case uploading(String); case done(String); case failed(String) }

/// Typed progress event so callers receive a numeric percent without parsing strings.
struct ProgressEvent {
    enum Phase: String, Codable {
        case downloading, uploading, completing
    }
    let phase: Phase
    let percent: Double       // 0...100
    let message: String       // human-readable

    static func downloading(msg: String, pct: Double) -> Self {
        .init(phase: .downloading, percent: min(pct, 99), message: msg)
    }
    static func uploading(msg: String, pct: Double) -> Self {
        .init(phase: .uploading, percent: min(pct, 99), message: msg)
    }
    static func completed(msg: String) -> Self {
        .init(phase: .completing, percent: 100, message: msg)
    }
}

struct TransferItem: Identifiable, Hashable {
    let id: String
    let tag: String
    let filename: String
    let progress: Double   // 0-100
    let size: String
    let state: String
    let remotePath: String
}

// ===== NEW TIER 2 MODELS =====

struct LibraryItem: Identifiable, Codable, Hashable {
    let id: UUID
    let url: String
    let title: String
    let mp4Url: String?
    let hlsUrls: [VideoSource.Quality]
    let extractedAt: Date
    var thumbnailURL: String?
    var remotePaths: [String: String] // "mega": "/Cloud/...", "gdrive": "gdrive:VidDL/..."

    init(id: UUID = UUID(), url: String, title: String, mp4Url: String?, hlsUrls: [VideoSource.Quality], thumbnailURL: String? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.mp4Url = mp4Url
        self.hlsUrls = hlsUrls
        self.extractedAt = Date()
        self.thumbnailURL = thumbnailURL
        self.remotePaths = [:]
    }
}

enum QueueStatus: Codable, Equatable {
    case pending, downloading, uploading, completed, paused, failed(String)

    var isTerminal: Bool {
        switch self { case .completed, .failed: return true; default: return false }
    }
}

struct DownloadQueueItem: Identifiable, Codable {
    let id: UUID
    let url: String
    let filename: String
    let quality: String // "MP4", "1080p", etc.
    var status: QueueStatus
    var progress: Double // 0-100
    let targetCloud: CloudTarget // "mega" or "gdrive"
    let createdAt: Date
    var megatag: String? // mega-exec transfer tag for cancellation
    var displayTitle: String? // human-readable title (e.g. Vidara video name)
    var finalPath: String? // local file path or remote destination when done

    init(id: UUID = UUID(), url: String, quality: String, targetCloud: CloudTarget = .mega, displayTitle: String? = nil) {
        self.id = id
        self.url = url
        self.filename = (URL(string: url)?.lastPathComponent) ?? "video.mp4"
        self.quality = quality
        self.status = .pending
        self.progress = 0
        self.targetCloud = targetCloud
        self.createdAt = Date()
        self.displayTitle = displayTitle
    }
}

enum CloudTarget: String, Codable, CaseIterable {
    case local, mega, gdrive

    var displayName: String {
        switch self {
        case .local: return "Local"
        case .mega: return "Mega"
        case .gdrive: return "Google Drive"
        }
    }

    var icon: String {
        switch self {
        case .local: return "externaldrive.fill"
        case .mega: return "cloud.fill"
        case .gdrive: return "g.circle.fill"
        }
    }
}

enum NavDestination: String, Codable, CaseIterable {
    case home = "Home"
    case library = "Library"
    case downloads = "Downloads"
    case scheduler = "Scheduler"
    case transfers = "Transfers"
    case processing = "Processing"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "books.vertical.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .scheduler: return "calendar.badge.clock"
        case .transfers: return "arrow.up.circle.fill"
        case .processing: return "wand.and.stars"
        case .settings: return "gearshape.fill"
        }
    }
}

struct ExtractResult {
    let url: String
    let source: VideoSource?
    let error: String?
}
