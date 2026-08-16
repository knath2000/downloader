import Foundation

// ===== EXISTING MODELS =====

struct VideoSource: Codable, Equatable {
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
        let resolutionMethod: String?

        init(label: String, url: String, kind: Kind = .hlsManifest, headers: [String: String]? = nil, sourcePageUrl: String? = nil, resolutionMethod: String? = nil) {
            self.label = label; self.url = url; self.kind = kind; self.headers = headers; self.sourcePageUrl = sourcePageUrl; self.resolutionMethod = resolutionMethod
        }
    }
    let mp4: String?
    let hls: [Quality]
    let title: String?
    let thumbnail: String?
    let duration: TimeInterval?
    let uploader: String?
    let uploaderURL: String?
    let siteName: String?
    let isAudio: Bool
    let resolutionMethod: String?
    /// Source-level HTTP headers required for downloading the video (e.g. Referer for hot-link
    /// protected CDNs like pmvhaven.com's video.pmvhaven.com origin). Used as a fallback when
    /// a per-quality `headers` map isn't available (e.g. the bare `mp4` URL is not in `hls`).
    let headers: [String: String]?

    init(mp4: String?, hls: [Quality], title: String? = nil, thumbnail: String? = nil, duration: TimeInterval? = nil, uploader: String? = nil, uploaderURL: String? = nil, siteName: String? = nil, isAudio: Bool = false, headers: [String: String]? = nil, resolutionMethod: String? = nil) {
        self.mp4 = mp4; self.hls = hls; self.title = title; self.thumbnail = thumbnail; self.duration = duration; self.uploader = uploader; self.uploaderURL = uploaderURL; self.siteName = siteName; self.isAudio = isAudio; self.headers = headers; self.resolutionMethod = resolutionMethod
    }

    var displaySiteName: String {
        SiteDisplayLabels.displayName(for: siteName)
    }

    func headers(forQualityURL url: String) -> [String: String]? {
        hls.first(where: { $0.url == url })?.headers ?? headers
    }

    func withResolutionMethod(_ method: String) -> VideoSource {
        VideoSource(
            mp4: mp4,
            hls: hls.map {
                Quality(label: $0.label, url: $0.url, kind: $0.kind, headers: $0.headers, sourcePageUrl: $0.sourcePageUrl, resolutionMethod: $0.resolutionMethod ?? method)
            },
            title: title,
            thumbnail: thumbnail,
            duration: duration,
            uploader: uploader,
            uploaderURL: uploaderURL,
            siteName: siteName,
            isAudio: isAudio,
            headers: headers,
            resolutionMethod: resolutionMethod ?? method
        )
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

enum UploadState: Equatable { case uploading(String); case done(String); case failed(String) }

/// Typed progress event so callers receive a numeric percent without parsing strings.
struct ProgressEvent {
    enum Phase: String, Codable {
        case downloading, verifying, uploading, completing
    }
    let phase: Phase
    let percent: Double       // 0...100
    let message: String       // human-readable
    let metrics: DownloadTransferMetrics?

    static func downloading(msg: String, pct: Double, metrics: DownloadTransferMetrics? = nil) -> Self {
        .init(phase: .downloading, percent: min(pct, 99), message: msg, metrics: metrics)
    }
    static func uploading(msg: String, pct: Double, metrics: DownloadTransferMetrics? = nil) -> Self {
        .init(phase: .uploading, percent: min(pct, 99), message: msg, metrics: metrics)
    }
    static func verifying(msg: String, pct: Double = 99, metrics: DownloadTransferMetrics? = nil) -> Self {
        .init(phase: .verifying, percent: min(pct, 99), message: msg, metrics: metrics)
    }
    static func completed(msg: String) -> Self {
        .init(phase: .completing, percent: 100, message: msg, metrics: nil)
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

// ===== NEW TIER 2 MODELS =====

struct LibraryItem: Identifiable, Codable, Hashable {
    let id: UUID
    let url: String
    let title: String
    let mp4Url: String?
    let hlsUrls: [VideoSource.Quality]
    let extractedAt: Date
    var thumbnailURL: String?
    var uploaderName: String?
    var uploaderURL: String?
    var sourceSiteName: String?
    var remotePaths: [String: String] // "mega": "/Cloud/...", "gdrive": "gdrive:VidDL/..."
    var tags: [String]?
    var collectionName: String?

    init(
        id: UUID = UUID(),
        url: String,
        title: String,
        mp4Url: String?,
        hlsUrls: [VideoSource.Quality],
        extractedAt: Date = Date(),
        thumbnailURL: String? = nil,
        uploaderName: String? = nil,
        uploaderURL: String? = nil,
        sourceSiteName: String? = nil,
        remotePaths: [String: String] = [:],
        tags: [String]? = nil,
        collectionName: String? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.mp4Url = mp4Url
        self.hlsUrls = hlsUrls
        self.extractedAt = extractedAt
        self.thumbnailURL = thumbnailURL
        self.uploaderName = uploaderName
        self.uploaderURL = uploaderURL
        self.sourceSiteName = sourceSiteName
        self.remotePaths = remotePaths
        self.tags = tags
        self.collectionName = collectionName
    }
}

// MARK: - Retry snapshot models

/// Non-secret snapshot of destination settings stored with each queue item so the download
/// can be retried without re-resolving the media URL.  Excludes seedboxWebdavPassword
/// intentionally — the current credential is read from AppStorage at retry time.
struct DownloadRetryContext: Codable, Equatable {
    let megaRemotePath: String
    let gdriveRemoteName: String
    let gdriveRemotePath: String
    let seedboxTransferMode: String
    let seedboxRemoteName: String
    let seedboxRemotePath: String
    let seedboxWebdavURL: String
    let seedboxWebdavUser: String
}

/// Full payload needed to re-run a download job without HomeView extraction state.
struct DownloadRetryPayload: Codable, Equatable {
    let sourcePageURL: String
    let preferredQualityLabel: String?
    let preferredQualityURL: String?
    let target: CloudTarget
    let context: DownloadRetryContext
    /// GDrive jobs need the Mega remote path that was resolved at first-attempt time so
    /// retry doesn't accidentally delete a different Mega file discovered later.
    let gdriveMegaRemotePath: String?
    private let inMemoryResolution: DownloadResolution

    var resolution: DownloadResolution { inMemoryResolution }

    init(
        resolution: DownloadResolution,
        target: CloudTarget,
        context: DownloadRetryContext,
        gdriveMegaRemotePath: String?
    ) {
        self.sourcePageURL = resolution.result.url
        self.preferredQualityLabel = resolution.source.hls.first(where: {
            $0.url == resolution.requestedUrl || $0.url == resolution.finalUrl
        })?.label
        self.preferredQualityURL = nil
        self.target = target
        self.context = context
        self.gdriveMegaRemotePath = gdriveMegaRemotePath
        self.inMemoryResolution = resolution
    }

    init(
        sourcePageURL: String,
        preferredQualityLabel: String?,
        title: String,
        target: CloudTarget,
        context: DownloadRetryContext
    ) {
        self.sourcePageURL = sourcePageURL
        self.preferredQualityLabel = preferredQualityLabel
        self.preferredQualityURL = nil
        self.target = target
        self.context = context
        self.gdriveMegaRemotePath = nil
        let source = VideoSource(mp4: nil, hls: [], title: title, siteName: URL(string: sourcePageURL)?.host ?? "Video")
        self.inMemoryResolution = DownloadResolution(
            requestedUrl: sourcePageURL,
            finalUrl: sourcePageURL,
            result: ExtractResult(url: sourcePageURL, source: source, error: nil),
            source: source,
            title: title,
            mediaKind: .direct,
            headers: nil,
            sourcePageUrl: sourcePageURL
        )
    }

    private enum CodingKeys: String, CodingKey {
        case sourcePageURL, preferredQualityLabel, preferredQualityURL, target, context, gdriveMegaRemotePath, resolution
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(CloudTarget.self, forKey: .target)
        context = try container.decode(DownloadRetryContext.self, forKey: .context)
        gdriveMegaRemotePath = try container.decodeIfPresent(String.self, forKey: .gdriveMegaRemotePath)
        if let pageURL = try container.decodeIfPresent(String.self, forKey: .sourcePageURL) {
            sourcePageURL = pageURL
            preferredQualityLabel = try container.decodeIfPresent(String.self, forKey: .preferredQualityLabel)
            preferredQualityURL = nil
            let source = VideoSource(mp4: nil, hls: [], title: nil, siteName: URL(string: pageURL)?.host ?? "Video")
            inMemoryResolution = DownloadResolution(
                requestedUrl: pageURL,
                finalUrl: pageURL,
                result: ExtractResult(url: pageURL, source: source, error: nil),
                source: source,
                title: pageURL,
                mediaKind: .direct,
                headers: nil,
                sourcePageUrl: pageURL
            )
        } else {
            let legacyResolution = try container.decode(DownloadResolution.self, forKey: .resolution)
            sourcePageURL = legacyResolution.result.url
            preferredQualityLabel = legacyResolution.source.hls.first(where: {
                $0.url == legacyResolution.requestedUrl || $0.url == legacyResolution.finalUrl
            })?.label
            preferredQualityURL = nil
            inMemoryResolution = legacyResolution
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourcePageURL, forKey: .sourcePageURL)
        try container.encodeIfPresent(preferredQualityLabel, forKey: .preferredQualityLabel)
        try container.encodeIfPresent(preferredQualityURL, forKey: .preferredQualityURL)
        try container.encode(target, forKey: .target)
        try container.encode(context, forKey: .context)
        try container.encodeIfPresent(gdriveMegaRemotePath, forKey: .gdriveMegaRemotePath)
    }
}

enum QueueStatus: Codable, Equatable {
    case pending, waiting, downloading, verifying, uploading, processing, completed, paused, failed(String)

    var isTerminal: Bool {
        switch self { case .completed, .failed: return true; default: return false }
    }
}

enum DownloadResumeStrategy: String, Codable, Equatable {
    case restartSafeNewFile
    case appendLocalRange
    case appendSeedboxRange
    case remoteSafeNewFile
}

enum DownloadQueueItemKind: String, Codable, Equatable {
    case processing
    case extraction
}

struct DownloadTransferMetrics: Codable, Equatable {
    var bytesDownloaded: Int64?
    var totalBytes: Int64?
    var bytesPerSecond: Double?
}

struct DownloadActivityEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let recordedAt: Date
    let status: QueueStatus
    let message: String

    init(id: UUID = UUID(), recordedAt: Date = Date(), status: QueueStatus, message: String) {
        self.id = id
        self.recordedAt = recordedAt
        self.status = status
        self.message = message
    }
}

struct DownloadQueueItem: Identifiable, Codable, Equatable {
    let id: UUID
    var url: String
    var filename: String
    let quality: String // "MP4", "1080p", etc.
    var status: QueueStatus
    var progress: Double // 0-100
    let targetCloud: CloudTarget // "mega" or "gdrive"
    let createdAt: Date
    var megatag: String? // mega-exec transfer tag for cancellation
    var displayTitle: String? // human-readable title (e.g. Vidara video name)
    var finalPath: String? // local file path or remote destination when done
    var uploadStarted: Bool?
    var statusMessage: String?
    var bytesDownloaded: Int64?
    var totalBytes: Int64?
    var bytesPerSecond: Double?
    /// Snapshot of the original resolution + destination settings used for one-click Retry.
    /// Nil on items created before this feature was added — their Retry button is disabled.
    var retryPayload: DownloadRetryPayload?
    var partialLocalPath: String?
    var expectedTotalBytes: Int64?
    var supportsByteRange: Bool?
    var resumeStrategy: DownloadResumeStrategy?
    var itemKind: DownloadQueueItemKind?
    var activity: [DownloadActivityEvent]?
    var automaticRetryCount: Int?
    var automaticRetryAfter: Date?
    var agentOwned: Bool?

    init(
        id: UUID = UUID(),
        url: String,
        quality: String,
        targetCloud: CloudTarget = .mega,
        displayTitle: String? = nil,
        retryPayload: DownloadRetryPayload? = nil,
        agentOwned: Bool = false
    ) {
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
        self.statusMessage = nil
        self.bytesDownloaded = nil
        self.totalBytes = nil
        self.bytesPerSecond = nil
        self.retryPayload = retryPayload
        self.partialLocalPath = nil
        self.expectedTotalBytes = nil
        self.supportsByteRange = nil
        self.resumeStrategy = nil
        self.itemKind = nil
        self.activity = [DownloadActivityEvent(status: .pending, message: "Ready to start")]
        self.automaticRetryCount = 0
        self.automaticRetryAfter = nil
        self.agentOwned = agentOwned
    }

    var isPaused: Bool { status == .paused }

    /// True only for failed rows that carry a retry payload.
    var canRetry: Bool {
        guard retryPayload != nil else { return false }
        if case .failed = status { return true }
        return false
    }

    var hasEnteredUpload: Bool {
        uploadStarted == true || status == .uploading
    }

    var isProcessingJob: Bool {
        itemKind == .processing || status == .processing
    }

    var isAgentOwned: Bool { agentOwned == true }

    var sourcePageURL: String? {
        if itemKind == .extraction {
            return url
        }
        return retryPayload?.resolution.result.url ?? retryPayload?.resolution.sourcePageUrl
    }

    var isVisibleInDownloads: Bool {
        true
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
    case local, mega, gdrive, seedbox

    var displayName: String {
        switch self {
        case .local: return "Local"
        case .mega: return "Mega"
        case .gdrive: return "Google Drive"
        case .seedbox: return "Seedbox"
        }
    }

    var icon: String {
        switch self {
        case .local: return "externaldrive.fill"
        case .mega: return "cloud.fill"
        case .gdrive: return "g.circle.fill"
        case .seedbox: return "server.rack"
        }
    }
}

enum DestinationAvailabilityPolicy {
    static let newJobTargets: [CloudTarget] = [.local, .gdrive]

    static func canCreateNewJob(for target: CloudTarget) -> Bool {
        newJobTargets.contains(target)
    }
}

enum NavDestination: String, Codable, CaseIterable {
    case home = "Home"
    case feed = "Feed"
    case watchlist = "Watchlist"
    case library = "Library"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .feed: return "antenna.radiowaves.left.and.right"
        case .watchlist: return "bookmark.fill"
        case .library: return "books.vertical.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var requiresPro: Bool {
        switch self {
        case .feed:
            return true
        case .home, .watchlist, .library, .settings:
            return false
        }
    }
}

struct ExtractResult: Codable, Equatable {
    let url: String
    let source: VideoSource?
    let error: String?
}
