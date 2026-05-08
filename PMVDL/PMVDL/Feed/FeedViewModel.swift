import Foundation

struct ProfileMatchReason {
    let score: Int
    let matchedPerformers: [String]
    let matchedTitlePerformers: [String]
    let matchedCategories: [String]
    let matchedTags: [String]
    let matchedStudio: String?
    let matchedQuality: [String]

    var subtext: String {
        var parts = ["Score \(score)"]
        if !matchedPerformers.isEmpty { parts.append("Performers: \(matchedPerformers.joined(separator: ", "))") }
        if !matchedTitlePerformers.isEmpty { parts.append("Performer in title: \(matchedTitlePerformers.joined(separator: ", "))") }
        if !matchedCategories.isEmpty { parts.append("Categories: \(matchedCategories.joined(separator: ", "))") }
        if !matchedTags.isEmpty { parts.append("Tags: \(matchedTags.joined(separator: ", "))") }
        if let matchedStudio { parts.append("Studio: \(matchedStudio)") }
        if !matchedQuality.isEmpty { parts.append("Quality: \(matchedQuality.joined(separator: ", "))") }
        return parts.joined(separator: " - ")
    }
}

@MainActor
final class FeedViewModel: ObservableObject {
    static let shared = FeedViewModel()

    @Published var items: [FeedItem] = []
    @Published var isLoading = false
    @Published var currentPage = 0
    @Published var hasMore = true
    @Published var selectedSite = AllPornStreamFeedScraper.supportedHost
    @Published var selectedPornHubSection: PornHubSection = .recommended
    @Published var pornHubUploaderURL: String?
    @Published var pornHubUploaderName: String?
    @Published var filters = FeedFilterState()
    @Published var sortMode: FeedSortMode = .newest
    @Published var error: String?

    private var resolvingDateIDs: Set<String> = []

    var filteredItems: [FeedItem] {
        let base = items.filter { filters.matches($0) }
        guard sortMode == .profileCurated else {
            return sortMode.sort(base)
        }

        if case .loaded(let result) = ProfileViewModel.shared.state {
            let scored = base.map { ($0, profileMatchReason($0, stats: result.stats)) }
            let matched = scored.filter { $0.1.score > 0 }.sorted { $0.1.score > $1.1.score }
            return matched.map { $0.0 }
        }
        return base
    }

    var profileMatchReasons: [String: ProfileMatchReason] {
        guard sortMode == .profileCurated,
              case .loaded(let result) = ProfileViewModel.shared.state else { return [:] }
        return Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, profileMatchReason($0, stats: result.stats))
        })
    }

    private init() {}

    var dateFilter: FeedDateFilter {
        get { filters.date }
        set { filters.date = newValue }
    }

    var dayBuckets: [FeedDayBucket] {
        Dictionary(grouping: filteredItems) { item in
            Calendar.current.startOfDay(for: item.uploadDate)
        }
        .map { FeedDayBucket(date: $0.key, items: $0.value) }
        .sorted { $0.date > $1.date }
    }

    func loadInitial() async {
        guard items.isEmpty else { return }
        await refresh()
    }

    func refresh() async {
        currentPage = 0
        hasMore = true
        items = []
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let nextPage = currentPage + 1
            if selectedSite == PornHubFeedScraper.supportedHost,
               selectedPornHubSection.requiresLogin,
               !PornHubSessionManager.shared.isLoggedIn {
                hasMore = false
                return
            }

            let pageItems = try await feedPage(page: nextPage)
            if pageItems.isEmpty {
                hasMore = false
                return
            }

            let existingIDs = Set(items.map(\.id))
            items.append(contentsOf: pageItems.filter { !existingIDs.contains($0.id) })
            currentPage = nextPage
            if pageItems.contains(where: \.uploadDateIsApproximate) {
                Task { await resolveApproximateDates() }
            }

            if selectedSite == RentryFeedScraper.supportedHost {
                hasMore = false
                return
            }

            if filters.date != .all, !pageItems.contains(where: { filters.date.matches($0.uploadDate) }) {
                hasMore = false
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resolveApproximateDates() async {
        let approximate = items.filter {
            $0.uploadDateIsApproximate &&
                $0.siteName == HQPornerFeedScraper.supportedHost &&
                !resolvingDateIDs.contains($0.id)
        }
        guard !approximate.isEmpty else { return }

        resolvingDateIDs.formUnion(approximate.map(\.id))

        await withTaskGroup(of: (String, Date?).self) { group in
            for item in approximate {
                let id = item.id
                let url = item.url
                group.addTask {
                    let date = await HQPornerFeedScraper.fetchUploadDate(for: url)
                    return (id, date)
                }
            }

            for await (id, date) in group {
                resolvingDateIDs.remove(id)
                guard let date,
                      let index = items.firstIndex(where: { $0.id == id }) else { continue }
                items[index] = items[index].withUploadDate(date, isApproximate: false)
            }
        }
    }

    func resetPaginationForFilter() {
        if filters.date == .all {
            hasMore = true
        }
    }

    func clearFilters() {
        filters = FeedFilterState()
        resetPaginationForFilter()
    }

    private func profileMatchReason(_ item: FeedItem, stats: ProfileStats) -> ProfileMatchReason {
        var score = 0
        var matchedPerformers: [String] = []
        var matchedTitlePerformers: [String] = []
        var matchedCategories: [String] = []
        var matchedTags: [String] = []
        var matchedStudio: String?
        var matchedQuality: [String] = []
        let title = FeedDisplay.title(for: item)

        for (i, entry) in stats.topPerformers.enumerated() {
            let explicitMatch = item.performers.contains { $0.caseInsensitiveCompare(entry.name) == .orderedSame }
            let titleMatch = titleContainsProfileName(entry.name, in: title)
            if explicitMatch {
                score += max(10 - i, 1) * entry.count
                matchedPerformers.append(entry.name)
            } else if titleMatch {
                score += max(9 - i, 1) * entry.count
                matchedTitlePerformers.append(entry.name)
            }
        }
        for (i, entry) in stats.topCategories.enumerated() {
            if item.categories.contains(where: { $0.caseInsensitiveCompare(entry.name) == .orderedSame }) {
                score += max(8 - i, 1) * entry.count
                matchedCategories.append(entry.name)
            }
        }
        for tag in item.tags {
            if let entry = stats.topTags.first(where: { $0.name.caseInsensitiveCompare(tag) == .orderedSame }) {
                score += entry.count
                matchedTags.append(entry.name)
            }
        }
        if let studio = item.studio,
           let entry = stats.topStudios.first(where: { $0.name.caseInsensitiveCompare(studio) == .orderedSame }) {
            score += 5
            matchedStudio = entry.name
        }
        for (i, entry) in stats.preferredQuality.enumerated() {
            if item.qualityLabels.contains(where: { $0.caseInsensitiveCompare(entry.name) == .orderedSame }) {
                score += max(3 - i, 1)
                matchedQuality.append(entry.name)
            }
        }
        return ProfileMatchReason(
            score: score,
            matchedPerformers: matchedPerformers,
            matchedTitlePerformers: matchedTitlePerformers,
            matchedCategories: matchedCategories,
            matchedTags: matchedTags,
            matchedStudio: matchedStudio,
            matchedQuality: matchedQuality
        )
    }

    private func titleContainsProfileName(_ name: String, in title: String) -> Bool {
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

    private func containsSequence(_ needle: [String], in haystack: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for index in 0...(haystack.count - needle.count) {
            if Array(haystack[index..<(index + needle.count)]) == needle {
                return true
            }
        }
        return false
    }

    private func normalizedTokens(_ value: String) -> [String] {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
    }

    func selectPornHubSection(_ section: PornHubSection) async {
        guard selectedPornHubSection != section else { return }
        pornHubUploaderURL = nil
        pornHubUploaderName = nil
        selectedPornHubSection = section
        await refresh()
    }

    func navigateToPornHubUploader(url: String, name: String) async {
        pornHubUploaderURL = url
        pornHubUploaderName = name
        await refresh()
    }

    func pornHubUploaderBack() async {
        pornHubUploaderURL = nil
        pornHubUploaderName = nil
        await refresh()
    }

    var availableSites: [String] {
        sortedValues(items.map(\.siteName))
    }

    var availableStudios: [String] {
        sortedValues(items.compactMap(\.studio))
    }

    var availableCategories: [String] {
        sortedValues(items.flatMap(\.categories))
    }

    var availableTags: [String] {
        topValues(items.flatMap(\.tags), limit: 30)
    }

    var availableQualityLabels: [String] {
        let preferred = ["4K", "2160p", "1440p", "1080p", "720p", "60FPS", "HD"]
        let values = Set(items.flatMap(\.qualityLabels))
        return values.sorted { lhs, rhs in
            let l = preferred.firstIndex(of: lhs) ?? Int.max
            let r = preferred.firstIndex(of: rhs) ?? Int.max
            if l == r {
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            return l < r
        }
    }

    private func scraper() throws -> any FeedScraper.Type {
        switch selectedSite {
        case AllPornStreamFeedScraper.supportedHost:
            return AllPornStreamFeedScraper.self
        case RentryFeedScraper.supportedHost:
            return RentryFeedScraper.self
        case HQPornerFeedScraper.supportedHost:
            return HQPornerFeedScraper.self
        case PornHubFeedScraper.supportedHost:
            return PornHubFeedScraper.self
        default:
            throw FeedScraperError.unsupportedSite(selectedSite)
        }
    }

    private func feedPage(page: Int) async throws -> [FeedItem] {
        if selectedSite == PornHubFeedScraper.supportedHost {
            return try await PornHubFeedScraper.fetchPage(page: page, section: selectedPornHubSection)
        }
        return try await scraper().fetchPage(page: page)
    }

    private func sortedValues(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func topValues(_ values: [String], limit: Int) -> [String] {
        let counts = values.reduce(into: [String: Int]()) { output, value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            output[trimmed, default: 0] += 1
        }
        return counts.sorted {
            if $0.value == $1.value {
                return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
            return $0.value > $1.value
        }
        .prefix(limit)
        .map(\.key)
    }
}

enum FeedDisplay {
    static func title(for item: FeedItem) -> String {
        var title = item.title.replacingOccurrences(
            of: #"\s*/\s*\d{2}\.\d{2}\.\d{4}(?=\))"#,
            with: "",
            options: .regularExpression
        )
        title = title.replacingOccurrences(
            of: #"\s*/\s*\d{2}\.\d{2}\.\d{4}$"#,
            with: "",
            options: .regularExpression
        )
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static func uploadTime(for date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func viewCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM views", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK views", Double(count) / 1_000)
        }
        return "\(count) views"
    }

    static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remaining = seconds % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let hourMinutes = minutes % 60
            return hourMinutes == 0 ? "\(hours)h" : "\(hours)h \(hourMinutes)m"
        }
        return remaining == 0 ? "\(minutes)m" : "\(minutes)m \(remaining)s"
    }
}
