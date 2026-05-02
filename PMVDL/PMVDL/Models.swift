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
        case downloading, verifying, uploading, completing
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
    static func verifying(msg: String, pct: Double = 99) -> Self {
        .init(phase: .verifying, percent: min(pct, 99), message: msg)
    }
    static func completed(msg: String) -> Self {
        .init(phase: .completing, percent: 100, message: msg)
    }
}

enum VideoFileNaming {
    private static let mediaExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "m3u8"]

    static func mp4FileName(title: String?, fallback: String = "video") -> String {
        "\(sanitizedBaseName(title: title, fallback: fallback)).mp4"
    }

    static func sanitizedBaseName(title: String?, fallback: String = "video") -> String {
        let raw = candidate(from: title) ?? candidate(from: fallback) ?? "video"
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_.'()"))
        var cleaned = raw.components(separatedBy: allowed.inverted).joined()
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || isGenericTempName(cleaned) {
            cleaned = "video"
        }
        return String(cleaned.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func candidate(from value: String?) -> String? {
        guard var candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty else {
            return nil
        }
        candidate = candidate.removingPercentEncoding ?? candidate
        candidate = candidate.replacingOccurrences(of: "+", with: " ")
        if candidate.contains("/") || candidate.contains("\\") {
            candidate = URL(string: candidate)?.lastPathComponent ?? (candidate as NSString).lastPathComponent
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !isGenericTempName(candidate) else { return nil }

        while true {
            let ext = (candidate as NSString).pathExtension.lowercased()
            guard mediaExtensions.contains(ext) || ext.contains("~") else { break }
            candidate = (candidate as NSString).deletingPathExtension
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private static func isGenericTempName(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("viddl_") || lower.hasPrefix("pmvdl_")
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
    case pending, downloading, verifying, uploading, completed, paused, failed(String)

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
    var uploadStarted: Bool?

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
        self.uploadStarted = nil
    }

    var hasEnteredUpload: Bool {
        uploadStarted == true || status == .uploading
    }

    var isVisibleInDownloads: Bool {
        !(targetCloud == .mega && hasEnteredUpload)
    }

    var isVisibleInTransfers: Bool {
        guard targetCloud == .mega else { return false }
        if status == .uploading { return true }
        if case .failed = status, uploadStarted == true { return true }
        return false
    }
}

struct HistoryItem: Identifiable, Codable, Hashable {
    let id: UUID
    let url: String
    let title: String
    let provider: String
    let recordedAt: Date

    init(id: UUID = UUID(), url: String, title: String, provider: String, recordedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.provider = provider
        self.recordedAt = recordedAt
    }
}

struct CompletedUploadItem: Identifiable, Codable, Hashable {
    let id: UUID
    let url: String
    let title: String
    let provider: String
    let destination: String
    let remotePath: String
    let completedAt: Date

    init(id: UUID = UUID(), url: String, title: String, provider: String, destination: String, remotePath: String, completedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.provider = provider
        self.destination = destination
        self.remotePath = remotePath
        self.completedAt = completedAt
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
    case history = "History"
    case library = "Library"
    case downloads = "Downloads"
    case mega = "Mega"
    case scheduler = "Scheduler"
    case transfers = "Transfers"
    case processing = "Processing"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .history: return "clock.arrow.circlepath"
        case .library: return "books.vertical.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .mega: return "cloud.fill"
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
