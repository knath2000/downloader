import Foundation

struct ProfileSourceCount: Codable, Hashable, Identifiable {
    let source: String
    let count: Int

    init(source: String, count: Int) {
        self.source = source
        self.count = count
    }

    var id: String { source }
    var displayText: String { "\(source) ×\(count)" }
}

struct ProfileStats: Codable, Hashable {
    struct RankedEntry: Codable, Hashable, Identifiable {
        let name: String
        let count: Int
        let sources: [ProfileSourceCount]
        let imageURL: String?
        let imageReferer: String?
        let imageSource: String?
        let profileURL: String?
        let profileReferer: String?

        init(
            name: String,
            count: Int,
            sources: [ProfileSourceCount],
            imageURL: String? = nil,
            imageReferer: String? = nil,
            imageSource: String? = nil,
            profileURL: String? = nil,
            profileReferer: String? = nil
        ) {
            self.name = name
            self.count = count
            self.sources = sources
            self.imageURL = imageURL
            self.imageReferer = imageReferer
            self.imageSource = imageSource
            self.profileURL = profileURL
            self.profileReferer = profileReferer
        }

        var id: String { name }
        var sourceSummary: String {
            sources.map(\.displayText).joined(separator: ", ")
        }
    }

    struct TitleSample: Codable, Hashable, Identifiable {
        let source: String
        let titles: [String]

        var id: String { source }
    }

    let topPerformers: [RankedEntry]
    let topCategories: [RankedEntry]
    let topTags: [RankedEntry]
    let topStudios: [RankedEntry]
    let preferredQuality: [RankedEntry]
    let favoritesCount: Int
    let pornhubLikedCount: Int
    let pornhubFavoritesCount: Int
    let libraryCount: Int
    let libraryTitleSample: [String]
    let titleSamples: [TitleSample]
    let avgDurationMinutes: Double?
    let durationSampleCount: Int
    let durationSources: [ProfileSourceCount]
    let ignoredSignals: [ProfileIgnoredSignal]

    init(
        topPerformers: [RankedEntry],
        topCategories: [RankedEntry],
        topTags: [RankedEntry],
        topStudios: [RankedEntry],
        preferredQuality: [RankedEntry],
        favoritesCount: Int,
        pornhubLikedCount: Int,
        pornhubFavoritesCount: Int,
        libraryCount: Int,
        libraryTitleSample: [String],
        titleSamples: [TitleSample],
        avgDurationMinutes: Double?,
        durationSampleCount: Int,
        durationSources: [ProfileSourceCount],
        ignoredSignals: [ProfileIgnoredSignal] = []
    ) {
        self.topPerformers = topPerformers
        self.topCategories = topCategories
        self.topTags = topTags
        self.topStudios = topStudios
        self.preferredQuality = preferredQuality
        self.favoritesCount = favoritesCount
        self.pornhubLikedCount = pornhubLikedCount
        self.pornhubFavoritesCount = pornhubFavoritesCount
        self.libraryCount = libraryCount
        self.libraryTitleSample = libraryTitleSample
        self.titleSamples = titleSamples
        self.avgDurationMinutes = avgDurationMinutes
        self.durationSampleCount = durationSampleCount
        self.durationSources = durationSources
        self.ignoredSignals = ignoredSignals
    }

    private enum CodingKeys: String, CodingKey {
        case topPerformers
        case topCategories
        case topTags
        case topStudios
        case preferredQuality
        case favoritesCount
        case pornhubLikedCount
        case pornhubFavoritesCount
        case libraryCount
        case libraryTitleSample
        case titleSamples
        case avgDurationMinutes
        case durationSampleCount
        case durationSources
        case ignoredSignals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        topPerformers = try container.decodeIfPresent([RankedEntry].self, forKey: .topPerformers) ?? []
        topCategories = try container.decodeIfPresent([RankedEntry].self, forKey: .topCategories) ?? []
        topTags = try container.decodeIfPresent([RankedEntry].self, forKey: .topTags) ?? []
        topStudios = try container.decodeIfPresent([RankedEntry].self, forKey: .topStudios) ?? []
        preferredQuality = try container.decodeIfPresent([RankedEntry].self, forKey: .preferredQuality) ?? []
        favoritesCount = try container.decodeIfPresent(Int.self, forKey: .favoritesCount) ?? 0
        pornhubLikedCount = try container.decodeIfPresent(Int.self, forKey: .pornhubLikedCount) ?? 0
        pornhubFavoritesCount = try container.decodeIfPresent(Int.self, forKey: .pornhubFavoritesCount) ?? 0
        libraryCount = try container.decodeIfPresent(Int.self, forKey: .libraryCount) ?? 0
        libraryTitleSample = try container.decodeIfPresent([String].self, forKey: .libraryTitleSample) ?? []
        titleSamples = try container.decodeIfPresent([TitleSample].self, forKey: .titleSamples) ?? []
        avgDurationMinutes = try container.decodeIfPresent(Double.self, forKey: .avgDurationMinutes)
        durationSampleCount = try container.decodeIfPresent(Int.self, forKey: .durationSampleCount) ?? 0
        durationSources = try container.decodeIfPresent([ProfileSourceCount].self, forKey: .durationSources) ?? []
        ignoredSignals = try container.decodeIfPresent([ProfileIgnoredSignal].self, forKey: .ignoredSignals) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(topPerformers, forKey: .topPerformers)
        try container.encode(topCategories, forKey: .topCategories)
        try container.encode(topTags, forKey: .topTags)
        try container.encode(topStudios, forKey: .topStudios)
        try container.encode(preferredQuality, forKey: .preferredQuality)
        try container.encode(favoritesCount, forKey: .favoritesCount)
        try container.encode(pornhubLikedCount, forKey: .pornhubLikedCount)
        try container.encode(pornhubFavoritesCount, forKey: .pornhubFavoritesCount)
        try container.encode(libraryCount, forKey: .libraryCount)
        try container.encode(libraryTitleSample, forKey: .libraryTitleSample)
        try container.encode(titleSamples, forKey: .titleSamples)
        try container.encodeIfPresent(avgDurationMinutes, forKey: .avgDurationMinutes)
        try container.encode(durationSampleCount, forKey: .durationSampleCount)
        try container.encode(durationSources, forKey: .durationSources)
        try container.encode(ignoredSignals, forKey: .ignoredSignals)
    }

    var totalItemCount: Int {
        favoritesCount + pornhubLikedCount + pornhubFavoritesCount + libraryCount
    }

    static let empty = ProfileStats(
        topPerformers: [],
        topCategories: [],
        topTags: [],
        topStudios: [],
        preferredQuality: [],
        favoritesCount: 0,
        pornhubLikedCount: 0,
        pornhubFavoritesCount: 0,
        libraryCount: 0,
        libraryTitleSample: [],
        titleSamples: [],
        avgDurationMinutes: nil,
        durationSampleCount: 0,
        durationSources: [],
        ignoredSignals: []
    )
}

struct ProfileEvidenceItem: Codable, Hashable, Identifiable {
    let id: String
    let source: String
    let title: String
    let url: String
    let uploaderName: String?
    let uploaderURL: String?
    let uploaderPath: String?
    let scraperPerformers: [String]
    let categories: [String]
    let tags: [String]
    let metadataStudio: String?
    let sourceSiteName: String?
    let durationSeconds: Int?
    let qualityLabels: [String]
    let eventDate: Date?
    let thumbnailURL: String?
    let thumbnailReferer: String?

    init(
        id: String,
        source: String,
        title: String,
        url: String,
        uploaderName: String?,
        uploaderURL: String?,
        uploaderPath: String?,
        scraperPerformers: [String],
        categories: [String],
        tags: [String],
        metadataStudio: String?,
        sourceSiteName: String?,
        durationSeconds: Int?,
        qualityLabels: [String],
        eventDate: Date?,
        thumbnailURL: String? = nil,
        thumbnailReferer: String? = nil
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.url = url
        self.uploaderName = uploaderName
        self.uploaderURL = uploaderURL
        self.uploaderPath = uploaderPath
        self.scraperPerformers = scraperPerformers
        self.categories = categories
        self.tags = tags
        self.metadataStudio = metadataStudio
        self.sourceSiteName = sourceSiteName
        self.durationSeconds = durationSeconds
        self.qualityLabels = qualityLabels
        self.eventDate = eventDate
        self.thumbnailURL = thumbnailURL
        self.thumbnailReferer = thumbnailReferer
    }
}

struct ProfileEvidenceSignal: Codable, Hashable, Identifiable {
    let name: String
    let count: Int
    let sources: [ProfileSourceCount]
    let sampleTitles: [String]
    let sampleURLs: [String]
    let signalKind: String

    var id: String { "\(signalKind):\(name.lowercased())" }
}

struct ProfileGenerationInput: Codable, Hashable {
    let items: [ProfileEvidenceItem]
    let uploaderSignals: [ProfileEvidenceSignal]
    let explicitPerformerSignals: [ProfileEvidenceSignal]
    let titleNameSignals: [ProfileEvidenceSignal]
    let favoritesCount: Int
    let pornhubLikedCount: Int
    let pornhubFavoritesCount: Int
    let libraryCount: Int
    let libraryTitleSample: [String]
    let titleSamples: [ProfileStats.TitleSample]
    let avgDurationMinutes: Double?
    let durationSampleCount: Int
    let durationSources: [ProfileSourceCount]
    let qualitySignals: [ProfileStats.RankedEntry]

    var totalItemCount: Int {
        favoritesCount + pornhubLikedCount + pornhubFavoritesCount + libraryCount
    }
}

struct ProfileIgnoredSignal: Codable, Hashable {
    let name: String
    let count: Int
    let sources: [ProfileSourceCount]
    let reason: String

    init(name: String, count: Int, sources: [ProfileSourceCount], reason: String) {
        self.name = name
        self.count = count
        self.sources = sources
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case count
        case sources
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
        sources = try container.decodeIfPresent([ProfileSourceCount].self, forKey: .sources) ?? []
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

struct ProfileAIResponse: Codable, Hashable {
    let narrativeMarkdown: String
    let topPerformers: [ProfileStats.RankedEntry]
    let topCategories: [ProfileStats.RankedEntry]
    let topTags: [ProfileStats.RankedEntry]
    let topStudios: [ProfileStats.RankedEntry]
    let preferredQuality: [ProfileStats.RankedEntry]
    let ignoredSignals: [ProfileIgnoredSignal]

    init(
        narrativeMarkdown: String,
        topPerformers: [ProfileStats.RankedEntry],
        topCategories: [ProfileStats.RankedEntry],
        topTags: [ProfileStats.RankedEntry],
        topStudios: [ProfileStats.RankedEntry],
        preferredQuality: [ProfileStats.RankedEntry],
        ignoredSignals: [ProfileIgnoredSignal]
    ) {
        self.narrativeMarkdown = narrativeMarkdown
        self.topPerformers = topPerformers
        self.topCategories = topCategories
        self.topTags = topTags
        self.topStudios = topStudios
        self.preferredQuality = preferredQuality
        self.ignoredSignals = ignoredSignals
    }

    private enum CodingKeys: String, CodingKey {
        case narrativeMarkdown
        case narrative
        case topPerformers
        case topCategories
        case topTags
        case topStudios
        case preferredQuality
        case ignoredSignals
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        narrativeMarkdown = try container.decodeIfPresent(String.self, forKey: .narrativeMarkdown)
            ?? container.decodeIfPresent(String.self, forKey: .narrative)
            ?? ""
        topPerformers = try container.decodeIfPresent([ProfileStats.RankedEntry].self, forKey: .topPerformers) ?? []
        topCategories = try container.decodeIfPresent([ProfileStats.RankedEntry].self, forKey: .topCategories) ?? []
        topTags = try container.decodeIfPresent([ProfileStats.RankedEntry].self, forKey: .topTags) ?? []
        topStudios = try container.decodeIfPresent([ProfileStats.RankedEntry].self, forKey: .topStudios) ?? []
        preferredQuality = try container.decodeIfPresent([ProfileStats.RankedEntry].self, forKey: .preferredQuality) ?? []
        ignoredSignals = try container.decodeIfPresent([ProfileIgnoredSignal].self, forKey: .ignoredSignals) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(narrativeMarkdown, forKey: .narrativeMarkdown)
        try container.encode(topPerformers, forKey: .topPerformers)
        try container.encode(topCategories, forKey: .topCategories)
        try container.encode(topTags, forKey: .topTags)
        try container.encode(topStudios, forKey: .topStudios)
        try container.encode(preferredQuality, forKey: .preferredQuality)
        try container.encode(ignoredSignals, forKey: .ignoredSignals)
    }

    func stats(derivedFrom input: ProfileGenerationInput) -> ProfileStats {
        let sanitizedPerformers = Self.sanitized(topPerformers, limit: 10)
        let sanitizedStudios = Self.sanitized(topStudios, limit: 8)
        let sanitizedPreferredQuality = Self.sanitized(preferredQuality, limit: 8)
        let sanitizedIgnoredSignals = Self.sanitizedIgnoredSignals(ignoredSignals)
        return ProfileStats(
            topPerformers: Self.performersByAddingOmittedUploaders(
                sanitizedPerformers,
                studios: sanitizedStudios,
                input: input,
                limit: 10
            ),
            topCategories: Self.sanitized(topCategories, limit: 10),
            topTags: Self.sanitized(topTags, limit: 15),
            topStudios: sanitizedStudios,
            preferredQuality: sanitizedPreferredQuality.isEmpty ? input.qualitySignals : sanitizedPreferredQuality,
            favoritesCount: input.favoritesCount,
            pornhubLikedCount: input.pornhubLikedCount,
            pornhubFavoritesCount: input.pornhubFavoritesCount,
            libraryCount: input.libraryCount,
            libraryTitleSample: input.libraryTitleSample,
            titleSamples: input.titleSamples,
            avgDurationMinutes: input.avgDurationMinutes,
            durationSampleCount: input.durationSampleCount,
            durationSources: input.durationSources,
            ignoredSignals: sanitizedIgnoredSignals
        )
    }

    private static func performersByAddingOmittedUploaders(
        _ performers: [ProfileStats.RankedEntry],
        studios: [ProfileStats.RankedEntry],
        input: ProfileGenerationInput,
        limit: Int
    ) -> [ProfileStats.RankedEntry] {
        var performerKeys = Set(performers.map { normalizedNameKey($0.name) })
        let studioKeys = Set(studios.map { normalizedNameKey($0.name) })

        var repaired = performers
        let repeatedUploaders = input.uploaderSignals.filter {
            $0.signalKind == "libraryUploader" && $0.count >= libraryUploaderPerformerThreshold
        }
        for signal in repeatedUploaders {
            let key = normalizedNameKey(signal.name)
            guard !key.isEmpty,
                  !performerKeys.contains(key),
                  !studioKeys.contains(key) else { continue }
            repaired.append(ProfileStats.RankedEntry(name: signal.name, count: signal.count, sources: signal.sources))
            performerKeys.insert(key)
        }

        return sanitized(repaired, limit: limit)
    }

    private static func sanitizedIgnoredSignals(_ entries: [ProfileIgnoredSignal]) -> [ProfileIgnoredSignal] {
        var seen = Set<String>()
        var output: [ProfileIgnoredSignal] = []
        for entry in entries {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedNameKey(name)
            guard !name.isEmpty, !key.isEmpty, seen.insert(key).inserted else { continue }
            let sources = mergedSources(entry.sources)
            let count = sources.isEmpty ? max(entry.count, 0) : sources.reduce(0) { $0 + $1.count }
            guard count > 0 else { continue }
            let reason = entry.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            output.append(ProfileIgnoredSignal(name: name, count: count, sources: sources, reason: reason))
        }
        output.sort {
            if $0.count == $1.count {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.count > $1.count
        }
        return Array(output.prefix(30))
    }

    private static func sanitized(_ entries: [ProfileStats.RankedEntry], limit: Int) -> [ProfileStats.RankedEntry] {
        var seen = Set<String>()
        var output: [ProfileStats.RankedEntry] = []
        for entry in entries {
            guard let sanitizedEntry = sanitizedEntry(entry),
                  seen.insert(normalizedNameKey(sanitizedEntry.name)).inserted else { continue }
            output.append(sanitizedEntry)
        }
        output.sort {
            if $0.count == $1.count {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.count > $1.count
        }
        return Array(output.prefix(limit))
    }

    private static func normalizedNameKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private static func sanitizedEntry(_ entry: ProfileStats.RankedEntry) -> ProfileStats.RankedEntry? {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !isExcludedPreferenceName(name) else { return nil }

        let sources = mergedSources(entry.sources)
        let count = sources.isEmpty ? max(entry.count, 0) : sources.reduce(0) { $0 + $1.count }
        guard count > 0 else { return nil }
        return ProfileStats.RankedEntry(name: name, count: count, sources: sources)
    }

    private static func isExcludedPreferenceName(_ value: String) -> Bool {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return true }
        if excludedPreferenceNames.contains(lower) { return true }
        return lower.contains(".com") || lower.contains(".net") || lower.contains(".org")
    }

    private static func mergedSources(_ sources: [ProfileSourceCount]) -> [ProfileSourceCount] {
        var counts: [String: Int] = [:]
        for source in sources {
            guard source.count > 0,
                  let normalized = normalizedSource(source.source) else { continue }
            counts[normalized, default: 0] += source.count
        }
        return counts
            .map { ProfileSourceCount(source: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.source < $1.source : $0.count > $1.count }
    }

    private static func normalizedSource(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.contains("pornhub") && lower.contains("liked") { return "PornHub Liked" }
        if lower.contains("pornhub") && lower.contains("favorite") { return "PornHub Favorites" }
        if lower.contains("download") || lower.contains("library") { return "Download History" }
        if lower.contains("saved") || lower == "favorites" || lower == "favorite" { return "Saved Favorites" }
        return trimmed
    }

    private static let excludedPreferenceNames: Set<String> = [
        "allpornstream",
        "download history",
        "hqporner",
        "pornhub",
        "pornhub favorites",
        "pornhub liked",
        "rentry",
        "saved favorites",
        "www.pornhub.com"
    ]
    private static let libraryUploaderPerformerThreshold = 5
}

struct ProfileAudit: Codable, Hashable {
    let inputSummary: ProfileInputSummary
    let rawClassification: ProfileAIResponse

    init(input: ProfileGenerationInput, rawClassification: ProfileAIResponse) {
        self.inputSummary = ProfileInputSummary(input: input)
        self.rawClassification = rawClassification
    }
}

struct ProfileInputSummary: Codable, Hashable {
    let totalItemCount: Int
    let sourceCounts: [ProfileSourceCount]
    let durationSampleCount: Int
    let uploaderSignals: [ProfileDebugSignal]
    let explicitPerformerSignals: [ProfileDebugSignal]
    let titleNameSignals: [ProfileDebugSignal]
    let qualitySignals: [ProfileStats.RankedEntry]

    init(input: ProfileGenerationInput) {
        totalItemCount = input.totalItemCount
        sourceCounts = [
            ProfileSourceCount(source: "Saved Favorites", count: input.favoritesCount),
            ProfileSourceCount(source: "PornHub Liked", count: input.pornhubLikedCount),
            ProfileSourceCount(source: "PornHub Favorites", count: input.pornhubFavoritesCount),
            ProfileSourceCount(source: "Download History", count: input.libraryCount)
        ]
        durationSampleCount = input.durationSampleCount
        uploaderSignals = input.uploaderSignals.map(ProfileDebugSignal.init)
        explicitPerformerSignals = input.explicitPerformerSignals.map(ProfileDebugSignal.init)
        titleNameSignals = input.titleNameSignals.map(ProfileDebugSignal.init)
        qualitySignals = input.qualitySignals
    }
}

struct ProfileDebugSignal: Codable, Hashable, Identifiable {
    let name: String
    let count: Int
    let sources: [ProfileSourceCount]
    let signalKind: String

    var id: String { "\(signalKind):\(name.lowercased())" }

    init(_ signal: ProfileEvidenceSignal) {
        name = signal.name
        count = signal.count
        sources = signal.sources
        signalKind = signal.signalKind
    }
}

struct ProfileResult: Codable, Hashable {
    let narrative: String
    let generatedAt: Date
    let stats: ProfileStats
    let audit: ProfileAudit?

    var isStale: Bool {
        Date().timeIntervalSince(generatedAt) > 7 * 24 * 60 * 60
    }
}

enum ProfileState {
    case idle
    case loading
    case loaded(ProfileResult)
    case failed(String)
}

@MainActor
final class ProfileViewModel: ObservableObject {
    static let shared = ProfileViewModel()

    @Published var state: ProfileState = .idle

    private let defaults = UserDefaults.standard
    private let narrativeKey = "profileNarrative"
    private let generatedAtKey = "profileGeneratedAt"
    private let itemCountKey = "profileItemCount"
    private let cachedResultKey = "profileCachedResult"
    private let lastAuditKey = "profileLastAudit"
    private let apiKeyKey = "xaiAPIKey"

    private init() {
        if let result = loadCachedResult() {
            state = .loaded(result)
        }
    }

    func generate() async {
        let apiKey = (defaults.string(forKey: apiKeyKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            state = .failed("Add your xAI API key in Settings to generate your profile.")
            return
        }

        state = .loading
        let input = await collectEvidence()
        guard input.totalItemCount > 0 else {
            state = .failed("Save some favorites first, or browse the Feed.")
            return
        }

        do {
            let response = try await XAIClient.generateProfile(input: input, apiKey: apiKey)
            let narrative = response.narrativeMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !narrative.isEmpty else {
                state = .failed("xAI returned an empty profile.")
                return
            }
            let stats = await ProfileImageResolver.enrichedStats(response.stats(derivedFrom: input), input: input)
            let result = ProfileResult(
                narrative: narrative,
                generatedAt: Date(),
                stats: stats,
                audit: ProfileAudit(input: input, rawClassification: response)
            )
            persist(result)
            state = .loaded(result)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func collectEvidence() async -> ProfileGenerationInput {
        let favoriteItems = FeedFavoritesStore.shared.items
        let libraryItems = await backfilledLibraryItems(VideoLibrary.shared.items.sorted { $0.extractedAt > $1.extractedAt })
        let shouldFetchPornHub = PornHubSessionManager.shared.isLoggedIn

        async let likedFetch: [FeedItem] = shouldFetchPornHub ? fetchPornHub(section: .liked) : []
        async let favoritesFetch: [FeedItem] = shouldFetchPornHub ? fetchPornHub(section: .favorites) : []
        let (likedItems, pornHubFavoriteItems) = await (likedFetch, favoritesFetch)

        var qualities = ProfileFrequencyCounter()
        var durationSeconds: [Int] = []
        var durationSourceCounts: [String: Int] = [:]
        var evidenceItems: [ProfileEvidenceItem] = []

        addFavoriteEvidence(favoriteItems, source: "Saved Favorites", output: &evidenceItems)
        addFeedEvidence(likedItems, source: "PornHub Liked", output: &evidenceItems)
        addFeedEvidence(pornHubFavoriteItems, source: "PornHub Favorites", output: &evidenceItems)
        addLibraryEvidence(libraryItems, output: &evidenceItems)

        let uploaderSignals = uploaderSignals(from: evidenceItems)
        let explicitPerformerSignals = explicitPerformerSignals(from: evidenceItems)
        let titleNameSignals = titleNameSignals(from: evidenceItems)

        for item in evidenceItems {
            qualities.add(item.qualityLabels, source: item.source)
            if let duration = item.durationSeconds, duration > 0 {
                durationSeconds.append(duration)
                durationSourceCounts[item.source, default: 0] += 1
            }
        }

        let avgDuration = durationSeconds.isEmpty ? nil : Double(durationSeconds.reduce(0, +)) / Double(durationSeconds.count) / 60.0
        let libraryTitles = libraryItems.prefix(30).map(\.title).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return ProfileGenerationInput(
            items: evidenceItems,
            uploaderSignals: uploaderSignals,
            explicitPerformerSignals: explicitPerformerSignals,
            titleNameSignals: titleNameSignals,
            favoritesCount: favoriteItems.count,
            pornhubLikedCount: likedItems.count,
            pornhubFavoritesCount: pornHubFavoriteItems.count,
            libraryCount: libraryItems.count,
            libraryTitleSample: libraryTitles,
            titleSamples: [
                .init(source: "Saved Favorites", titles: favoriteItems.prefix(30).map(\.title)),
                .init(source: "PornHub Liked", titles: likedItems.prefix(30).map(\.title)),
                .init(source: "PornHub Favorites", titles: pornHubFavoriteItems.prefix(30).map(\.title)),
                .init(source: "Download History", titles: libraryTitles)
            ].filter { !$0.titles.isEmpty },
            avgDurationMinutes: avgDuration,
            durationSampleCount: durationSeconds.count,
            durationSources: durationSourceCounts
                .map { ProfileSourceCount(source: $0.key, count: $0.value) }
                .sorted { $0.count == $1.count ? $0.source < $1.source : $0.count > $1.count },
            qualitySignals: qualities.ranked(limit: 8)
        )
    }

    private func fetchPornHub(section: PornHubSection) async -> [FeedItem] {
        do {
            return try await PornHubFeedScraper.fetchProfilePage(page: 1, section: section)
        } catch {
            return []
        }
    }

    private func uploaderSignals(from items: [ProfileEvidenceItem]) -> [ProfileEvidenceSignal] {
        var counter = ProfileSignalCounter()
        for item in items {
            guard item.source == "Download History" || item.source.hasPrefix("PornHub"),
                  let uploaderName = clean(item.uploaderName),
                  shouldKeepSignalName(uploaderName, item: item) else { continue }
            let kind = item.source == "Download History" ? "libraryUploader" : "feedUploader"
            counter.add(
                uploaderName,
                source: item.source,
                title: item.title,
                url: item.url,
                signalKind: kind
            )
        }
        return counter.ranked(limit: 30)
    }

    private func explicitPerformerSignals(from items: [ProfileEvidenceItem]) -> [ProfileEvidenceSignal] {
        var counter = ProfileSignalCounter()
        for item in items {
            for performer in item.scraperPerformers where shouldKeepSignalName(performer, item: item) {
                counter.add(
                    performer,
                    source: item.source,
                    title: item.title,
                    url: item.url,
                    signalKind: "scraperPerformer"
                )
            }
        }
        return counter.ranked(limit: 30)
    }

    private func titleNameSignals(from items: [ProfileEvidenceItem]) -> [ProfileEvidenceSignal] {
        var counter = ProfileSignalCounter()
        for item in items {
            let candidates = Set(titleNameCandidates(from: item.title))
            for candidate in candidates where shouldKeepSignalName(candidate, item: item) {
                counter.add(
                    candidate,
                    source: item.source,
                    title: item.title,
                    url: item.url,
                    signalKind: "titleMention"
                )
            }
        }
        return counter.ranked(limit: 40)
    }

    private func addFavoriteEvidence(_ items: [FeedFavoriteItem], source: String, output: inout [ProfileEvidenceItem]) {
        for item in items {
            output.append(ProfileEvidenceItem(
                id: item.id,
                source: source,
                title: clean(item.title) ?? item.title,
                url: item.url,
                uploaderName: nil,
                uploaderURL: nil,
                uploaderPath: nil,
                scraperPerformers: cleanArray(item.performers),
                categories: cleanArray(item.categories),
                tags: cleanArray(item.tags),
                metadataStudio: clean(item.studio),
                sourceSiteName: clean(item.siteName),
                durationSeconds: item.durationSeconds,
                qualityLabels: cleanArray(item.qualityLabels),
                eventDate: item.favoritedAt,
                thumbnailURL: clean(item.thumbnailURL),
                thumbnailReferer: clean(item.referer) ?? clean(item.url)
            ))
        }
    }

    private func addFeedEvidence(_ items: [FeedItem], source: String, output: inout [ProfileEvidenceItem]) {
        for item in items {
            let performerHint = item.performers.first
            output.append(ProfileEvidenceItem(
                id: item.id,
                source: source,
                title: clean(item.title) ?? item.title,
                url: item.url,
                uploaderName: clean(item.studio) ?? clean(performerHint),
                uploaderURL: clean(item.studioURL),
                uploaderPath: uploaderPath(from: item.studioURL),
                scraperPerformers: cleanArray(item.performers),
                categories: cleanArray(item.categories),
                tags: cleanArray(item.tags),
                metadataStudio: clean(item.studio),
                sourceSiteName: clean(item.siteName),
                durationSeconds: item.durationSeconds,
                qualityLabels: cleanArray(item.qualityLabels),
                eventDate: item.uploadDate,
                thumbnailURL: clean(item.thumbnailURL),
                thumbnailReferer: clean(item.referer) ?? clean(item.url)
            ))
        }
    }

    private func addLibraryEvidence(_ items: [LibraryItem], output: inout [ProfileEvidenceItem]) {
        for item in items {
            output.append(ProfileEvidenceItem(
                id: item.id.uuidString,
                source: "Download History",
                title: clean(item.title) ?? item.title,
                url: item.url,
                uploaderName: clean(item.uploaderName),
                uploaderURL: clean(item.uploaderURL),
                uploaderPath: uploaderPath(from: item.uploaderURL),
                scraperPerformers: [],
                categories: [],
                tags: [],
                metadataStudio: nil,
                sourceSiteName: clean(item.sourceSiteName),
                durationSeconds: nil,
                qualityLabels: [],
                eventDate: item.extractedAt,
                thumbnailURL: clean(item.thumbnailURL),
                thumbnailReferer: clean(item.url)
            ))
        }
    }

    private func titleNameCandidates(from title: String) -> [String] {
        let words = title
            .replacingOccurrences(of: #"[^A-Za-z0-9']+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
        guard words.count >= 2 else { return [] }

        var candidates: [String] = []
        for start in words.indices {
            for length in 2...3 {
                let end = start + length
                guard end <= words.count else { continue }
                let slice = Array(words[start..<end])
                guard slice.allSatisfy(isLikelyNameToken),
                      slice.contains(where: containsLetter),
                      !slice.contains(where: isTitleNameStopword) else { continue }
                candidates.append(slice.joined(separator: " "))
            }
        }
        return candidates
    }

    private func isLikelyNameToken(_ value: String) -> Bool {
        guard value.count >= 2,
              value.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil else { return false }
        let first = value.unicodeScalars.first
        return first.map { CharacterSet.uppercaseLetters.contains($0) } ?? false
    }

    private func containsLetter(_ value: String) -> Bool {
        value.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
    }

    private func isTitleNameStopword(_ value: String) -> Bool {
        Self.titleNameStopwords.contains(value.lowercased())
    }

    private func shouldKeepSignalName(_ name: String, item: ProfileEvidenceItem) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if Self.excludedSignalNames.contains(lower) { return false }
        if lower.contains(".com") || lower.contains(".net") || lower.contains(".org") { return false }
        if let site = item.sourceSiteName?.lowercased(), !site.isEmpty, lower == site { return false }
        return true
    }

    private func backfilledLibraryItems(_ items: [LibraryItem]) async -> [LibraryItem] {
        let candidates = items.filter(needsUploaderBackfill)
        guard !candidates.isEmpty else { return items }

        var updates: [LibraryItemMetadataUpdate] = []
        let batchSize = 3
        var index = candidates.startIndex
        while index < candidates.endIndex {
            let end = candidates.index(index, offsetBy: batchSize, limitedBy: candidates.endIndex) ?? candidates.endIndex
            let batch = Array(candidates[index..<end])
            let batchUpdates = await withTaskGroup(of: LibraryItemMetadataUpdate?.self) { group in
                for item in batch {
                    group.addTask {
                        await Self.libraryMetadataUpdate(for: item)
                    }
                }

                var output: [LibraryItemMetadataUpdate] = []
                for await update in group {
                    if let update {
                        output.append(update)
                    }
                }
                return output
            }
            updates.append(contentsOf: batchUpdates)
            index = end
        }

        guard !updates.isEmpty else { return items }
        VideoLibrary.shared.updateMetadata(updates)
        let refreshed = Dictionary(uniqueKeysWithValues: VideoLibrary.shared.items.map { ($0.id, $0) })
        return items.map { refreshed[$0.id] ?? $0 }
    }

    private func needsUploaderBackfill(_ item: LibraryItem) -> Bool {
        guard isPornHubURL(item.url) else { return false }
        return clean(item.uploaderName) == nil
            || clean(item.sourceSiteName) == nil
    }

    private func isPornHubURL(_ raw: String) -> Bool {
        guard let host = URL(string: raw)?.host?.lowercased() else { return false }
        return host.contains("pornhub.com")
    }

    private nonisolated static func libraryMetadataUpdate(for item: LibraryItem) async -> LibraryItemMetadataUpdate? {
        guard let url = URL(string: item.url) else { return nil }
        do {
            let metadata = try await YtDlpExtractor.fetchMetadata(for: url)
            guard metadata.uploader != nil
                    || metadata.uploaderURL != nil
                    || metadata.siteName != nil
                    || metadata.thumbnail != nil else {
                return nil
            }
            return LibraryItemMetadataUpdate(
                id: item.id,
                uploaderName: metadata.uploader,
                uploaderURL: metadata.uploaderURL,
                sourceSiteName: metadata.siteName,
                thumbnailURL: metadata.thumbnail
            )
        } catch {
            return nil
        }
    }

    private func uploaderPath(from urlString: String?) -> String? {
        guard let urlString,
              let url = URL(string: urlString) else { return nil }
        return clean(url.path)
    }

    private func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cleanArray(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let trimmed = clean(value) else { return nil }
            return seen.insert(trimmed.lowercased()).inserted ? trimmed : nil
        }
    }

    private func persist(_ result: ProfileResult) {
        defaults.set(result.narrative, forKey: narrativeKey)
        defaults.set(Self.isoFormatter.string(from: result.generatedAt), forKey: generatedAtKey)
        defaults.set(result.stats.totalItemCount, forKey: itemCountKey)
        if let data = try? JSONEncoder().encode(result) {
            defaults.set(data, forKey: cachedResultKey)
        }
        if let audit = result.audit,
           let data = try? JSONEncoder().encode(audit) {
            defaults.set(data, forKey: lastAuditKey)
        }
    }

    private func loadCachedResult() -> ProfileResult? {
        if let data = defaults.data(forKey: cachedResultKey),
           let result = try? JSONDecoder().decode(ProfileResult.self, from: data) {
            if result.audit != nil {
                return result
            }
            return ProfileResult(narrative: result.narrative, generatedAt: result.generatedAt, stats: result.stats, audit: loadLastAudit())
        }
        guard let narrative = defaults.string(forKey: narrativeKey),
              !narrative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let generatedAt = defaults.string(forKey: generatedAtKey).flatMap { Self.isoFormatter.date(from: $0) } ?? Date()
        return ProfileResult(narrative: narrative, generatedAt: generatedAt, stats: .empty, audit: loadLastAudit())
    }

    private func loadLastAudit() -> ProfileAudit? {
        guard let data = defaults.data(forKey: lastAuditKey) else { return nil }
        return try? JSONDecoder().decode(ProfileAudit.self, from: data)
    }

    private static let isoFormatter = ISO8601DateFormatter()
    private static let excludedSignalNames: Set<String> = [
        "pornhub",
        "www.pornhub.com",
        "hqporner",
        "allpornstream",
        "rentry",
        "download history",
        "saved favorites",
        "pornhub liked",
        "pornhub favorites"
    ]
    private static let titleNameStopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "baby", "babysitter", "beach", "best", "big", "blonde",
        "brunette", "but", "cam", "casting", "college", "compilation", "cum", "cute", "day", "deep",
        "for", "from", "full", "gets", "girl", "girls", "hard", "hd", "her", "his", "home", "hot",
        "in", "is", "latina", "little", "mom", "new", "of", "old", "on", "outdoor", "part", "porn",
        "pov", "scene", "sex", "sexy", "step", "stepsis", "teen", "the", "to", "video", "with", "young"
    ]
}

private struct ProfileFrequencyCounter {
    private struct Entry {
        var name: String
        var sourceCounts: [String: Int]
    }

    private var entries: [String: Entry] = [:]

    mutating func add(_ value: String?, source: String) {
        guard let value else { return }
        add([value], source: source)
    }

    mutating func add(_ values: [String], source: String) {
        for raw in values {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            var entry = entries[key] ?? Entry(name: normalized, sourceCounts: [:])
            entry.sourceCounts[source, default: 0] += 1
            entries[key] = entry
        }
    }

    func ranked(limit: Int) -> [ProfileStats.RankedEntry] {
        entries.values
            .map { entry in
                ProfileStats.RankedEntry(
                    name: entry.name,
                    count: entry.sourceCounts.values.reduce(0, +),
                    sources: entry.sourceCounts
                        .map { ProfileSourceCount(source: $0.key, count: $0.value) }
                        .sorted { $0.count == $1.count ? $0.source < $1.source : $0.count > $1.count }
                )
            }
            .sorted {
                if $0.count == $1.count {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.count > $1.count
            }
            .prefix(limit)
            .map { $0 }
    }
}

private struct ProfileSignalCounter {
    private struct Entry {
        var name: String
        var signalKind: String
        var sourceCounts: [String: Int]
        var sampleTitles: [String]
        var sampleURLs: [String]
    }

    private var entries: [String: Entry] = [:]

    mutating func add(_ name: String, source: String, title: String, url: String, signalKind: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = normalizedKey(trimmed)
        guard !key.isEmpty else { return }

        var entry = entries[key] ?? Entry(
            name: trimmed,
            signalKind: signalKind,
            sourceCounts: [:],
            sampleTitles: [],
            sampleURLs: []
        )
        entry.sourceCounts[source, default: 0] += 1
        if entry.sampleTitles.count < 5, !entry.sampleTitles.contains(title) {
            entry.sampleTitles.append(title)
        }
        if entry.sampleURLs.count < 5, !entry.sampleURLs.contains(url) {
            entry.sampleURLs.append(url)
        }
        if signalKind == "libraryUploader" {
            entry.signalKind = signalKind
        }
        entries[key] = entry
    }

    func ranked(limit: Int) -> [ProfileEvidenceSignal] {
        entries.values
            .map { entry in
                ProfileEvidenceSignal(
                    name: entry.name,
                    count: entry.sourceCounts.values.reduce(0, +),
                    sources: entry.sourceCounts
                        .map { ProfileSourceCount(source: $0.key, count: $0.value) }
                        .sorted { $0.count == $1.count ? $0.source < $1.source : $0.count > $1.count },
                    sampleTitles: entry.sampleTitles,
                    sampleURLs: entry.sampleURLs,
                    signalKind: entry.signalKind
                )
            }
            .sorted {
                if $0.count == $1.count {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                return $0.count > $1.count
            }
            .prefix(limit)
            .map { $0 }
    }

    private func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }
}

enum ProfileImageResolver {
    static func enrichedStats(
        _ stats: ProfileStats,
        input: ProfileGenerationInput,
        pageImageProvider: (String, String?) async -> String? = fetchProfileImage
    ) async -> ProfileStats {
        let performers = await enrichedPerformers(
            stats.topPerformers,
            input: input,
            pageImageProvider: pageImageProvider
        )
        return ProfileStats(
            topPerformers: performers,
            topCategories: stats.topCategories,
            topTags: stats.topTags,
            topStudios: stats.topStudios,
            preferredQuality: stats.preferredQuality,
            favoritesCount: stats.favoritesCount,
            pornhubLikedCount: stats.pornhubLikedCount,
            pornhubFavoritesCount: stats.pornhubFavoritesCount,
            libraryCount: stats.libraryCount,
            libraryTitleSample: stats.libraryTitleSample,
            titleSamples: stats.titleSamples,
            avgDurationMinutes: stats.avgDurationMinutes,
            durationSampleCount: stats.durationSampleCount,
            durationSources: stats.durationSources,
            ignoredSignals: stats.ignoredSignals
        )
    }

    static func enrichedPerformers(
        _ performers: [ProfileStats.RankedEntry],
        input: ProfileGenerationInput,
        pageImageProvider: (String, String?) async -> String? = fetchProfileImage
    ) async -> [ProfileStats.RankedEntry] {
        var output: [ProfileStats.RankedEntry] = []
        for performer in performers {
            output.append(await enrichedPerformer(
                performer,
                input: input,
                pageImageProvider: pageImageProvider
            ))
        }
        return output
    }

    private static func enrichedPerformer(
        _ performer: ProfileStats.RankedEntry,
        input: ProfileGenerationInput,
        pageImageProvider: (String, String?) async -> String?
    ) async -> ProfileStats.RankedEntry {
        let candidates = matchingEvidence(for: performer.name, input: input)
        let profileLink = candidates.compactMap(profileLink).first
        for candidate in candidates {
            guard let rawPageURL = clean(candidate.item.uploaderURL) else { continue }
            let pageURL = PornHubFeedScraper.normalizedUploaderURL(rawPageURL) ?? rawPageURL
            if let imageURL = await pageImageProvider(pageURL, candidate.item.thumbnailReferer) {
                return ProfileStats.RankedEntry(
                    name: performer.name,
                    count: performer.count,
                    sources: performer.sources,
                    imageURL: imageURL,
                    imageReferer: pageURL,
                    imageSource: "profile",
                    profileURL: profileLink?.url,
                    profileReferer: profileLink?.referer
                )
            }
        }

        if let fallback = candidates.compactMap(evidenceThumbnail).first {
            return ProfileStats.RankedEntry(
                name: performer.name,
                count: performer.count,
                sources: performer.sources,
                imageURL: fallback.url,
                imageReferer: fallback.referer,
                imageSource: "evidenceThumbnail",
                profileURL: profileLink?.url,
                profileReferer: profileLink?.referer
            )
        }

        if let profileLink {
            return ProfileStats.RankedEntry(
                name: performer.name,
                count: performer.count,
                sources: performer.sources,
                imageURL: performer.imageURL,
                imageReferer: performer.imageReferer,
                imageSource: performer.imageSource,
                profileURL: profileLink.url,
                profileReferer: profileLink.referer
            )
        }

        return performer
    }

    private static func matchingEvidence(
        for name: String,
        input: ProfileGenerationInput
    ) -> [ProfileImageCandidate] {
        let key = normalizedNameKey(name)
        guard !key.isEmpty else { return [] }
        let signalURLs = matchingSignalURLs(for: key, input: input)

        return input.items.compactMap { item -> ProfileImageCandidate? in
            var score = 0
            if normalizedNameKey(item.uploaderName) == key {
                score += 60
            }
            if item.scraperPerformers.contains(where: { normalizedNameKey($0) == key }) {
                score += 50
            }
            if signalURLs.contains(normalizedURL(item.url)) {
                score += 40
            }
            if titleContainsName(name, in: item.title) {
                score += 30
            }
            guard score > 0 else { return nil }
            return ProfileImageCandidate(item: item, score: score)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                let lhsTime = lhs.item.eventDate?.timeIntervalSince1970 ?? 0
                let rhsTime = rhs.item.eventDate?.timeIntervalSince1970 ?? 0
                if lhsTime == rhsTime {
                    return lhs.item.id < rhs.item.id
                }
                return lhsTime > rhsTime
            }
            return lhs.score > rhs.score
        }
    }

    private static func matchingSignalURLs(for key: String, input: ProfileGenerationInput) -> Set<String> {
        let signals = input.uploaderSignals + input.explicitPerformerSignals + input.titleNameSignals
        return Set(signals
            .filter { normalizedNameKey($0.name) == key }
            .flatMap(\.sampleURLs)
            .map(normalizedURL)
            .filter { !$0.isEmpty })
    }

    private static func evidenceThumbnail(_ candidate: ProfileImageCandidate) -> (url: String, referer: String?)? {
        guard let url = clean(candidate.item.thumbnailURL) else { return nil }
        return (url, clean(candidate.item.thumbnailReferer) ?? clean(candidate.item.url))
    }

    private static func profileLink(_ candidate: ProfileImageCandidate) -> (url: String, referer: String?)? {
        guard let url = clean(candidate.item.uploaderURL),
              let profileURL = PornHubFeedScraper.normalizedUploaderURL(url) else { return nil }
        return (profileURL, clean(candidate.item.thumbnailReferer) ?? clean(candidate.item.url))
    }

    private static func fetchProfileImage(pageURL: String, referer: String?) async -> String? {
        guard let url = URL(string: pageURL) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        if let referer = clean(referer) {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }
            return metaImageURL(in: html, baseURL: url)
        } catch {
            return nil
        }
    }

    private static func metaImageURL(in html: String, baseURL: URL) -> String? {
        let tags = allMatches(pattern: #"<meta\b[^>]*>"#, in: html)
        let keys = ["og:image", "og:image:url", "twitter:image", "twitter:image:src"]
        for tag in tags {
            let name = attribute("property", in: tag) ?? attribute("name", in: tag)
            guard let name,
                  keys.contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()),
                  let content = attribute("content", in: tag),
                  let resolved = resolvedImageURL(decodeHTMLEntities(content), baseURL: baseURL) else { continue }
            return resolved
        }
        return nil
    }

    private static func resolvedImageURL(_ raw: String, baseURL: URL) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let resolved = URL(string: trimmed, relativeTo: baseURL) else { return nil }
        return resolved.absoluteURL.absoluteString
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, range: range),
              match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: tag) else {
            return nil
        }
        return String(tag[matchRange])
    }

    private static func allMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func titleContainsName(_ name: String, in title: String) -> Bool {
        let nameTokens = normalizedTokens(name)
        let titleTokens = normalizedTokens(title)
        guard !nameTokens.isEmpty, !titleTokens.isEmpty else { return false }
        if containsSequence(nameTokens, in: titleTokens) {
            return true
        }

        let compactName = nameTokens.joined()
        guard compactName.count >= 6 else { return false }
        return titleTokens.joined().contains(compactName)
    }

    private static func containsSequence(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for index in 0...(haystack.count - needle.count) {
            if Array(haystack[index..<(index + needle.count)]) == needle {
                return true
            }
        }
        return false
    }

    private static func normalizedTokens(_ value: String) -> [String] {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
    }

    private static func normalizedNameKey(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private static func normalizedURL(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private struct ProfileImageCandidate {
    let item: ProfileEvidenceItem
    let score: Int
}
