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
        durationSources: []
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
}

struct ProfileGenerationInput: Codable, Hashable {
    let items: [ProfileEvidenceItem]
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

struct ProfileAIResponse: Decodable, Hashable {
    let narrativeMarkdown: String
    let topPerformers: [ProfileStats.RankedEntry]
    let topCategories: [ProfileStats.RankedEntry]
    let topTags: [ProfileStats.RankedEntry]
    let topStudios: [ProfileStats.RankedEntry]
    let preferredQuality: [ProfileStats.RankedEntry]

    private enum CodingKeys: String, CodingKey {
        case narrativeMarkdown
        case narrative
        case topPerformers
        case topCategories
        case topTags
        case topStudios
        case preferredQuality
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
    }

    func stats(derivedFrom input: ProfileGenerationInput) -> ProfileStats {
        let sanitizedPreferredQuality = Self.sanitized(preferredQuality, limit: 8)
        return ProfileStats(
            topPerformers: Self.sanitized(topPerformers, limit: 10),
            topCategories: Self.sanitized(topCategories, limit: 10),
            topTags: Self.sanitized(topTags, limit: 15),
            topStudios: Self.sanitized(topStudios, limit: 8),
            preferredQuality: sanitizedPreferredQuality.isEmpty ? input.qualitySignals : sanitizedPreferredQuality,
            favoritesCount: input.favoritesCount,
            pornhubLikedCount: input.pornhubLikedCount,
            pornhubFavoritesCount: input.pornhubFavoritesCount,
            libraryCount: input.libraryCount,
            libraryTitleSample: input.libraryTitleSample,
            titleSamples: input.titleSamples,
            avgDurationMinutes: input.avgDurationMinutes,
            durationSampleCount: input.durationSampleCount,
            durationSources: input.durationSources
        )
    }

    private static func sanitized(_ entries: [ProfileStats.RankedEntry], limit: Int) -> [ProfileStats.RankedEntry] {
        var seen = Set<String>()
        var output: [ProfileStats.RankedEntry] = []
        for entry in entries {
            guard let sanitizedEntry = sanitizedEntry(entry),
                  seen.insert(sanitizedEntry.name.lowercased()).inserted else { continue }
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

    private static func sanitizedEntry(_ entry: ProfileStats.RankedEntry) -> ProfileStats.RankedEntry? {
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let sources = mergedSources(entry.sources)
        let count = sources.isEmpty ? max(entry.count, 0) : sources.reduce(0) { $0 + $1.count }
        guard count > 0 else { return nil }
        return ProfileStats.RankedEntry(name: name, count: count, sources: sources)
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
}

struct ProfileResult: Codable, Hashable {
    let narrative: String
    let generatedAt: Date
    let stats: ProfileStats

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
            let result = ProfileResult(narrative: narrative, generatedAt: Date(), stats: response.stats(derivedFrom: input))
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
                eventDate: item.favoritedAt
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
                eventDate: item.uploadDate
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
                eventDate: item.extractedAt
            ))
        }
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
    }

    private func loadCachedResult() -> ProfileResult? {
        if let data = defaults.data(forKey: cachedResultKey),
           let result = try? JSONDecoder().decode(ProfileResult.self, from: data) {
            return result
        }
        guard let narrative = defaults.string(forKey: narrativeKey),
              !narrative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let generatedAt = defaults.string(forKey: generatedAtKey).flatMap { Self.isoFormatter.date(from: $0) } ?? Date()
        return ProfileResult(narrative: narrative, generatedAt: generatedAt, stats: .empty)
    }

    private static let isoFormatter = ISO8601DateFormatter()
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
