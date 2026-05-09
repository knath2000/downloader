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

struct PornHubFeedReturnState {
    let section: PornHubSection
    let items: [FeedItem]
    let currentPage: Int
    let hasMore: Bool
    let sortMode: FeedSortMode
    let anchorID: String?
}

@MainActor
final class FeedViewModel: ObservableObject {
    static let shared = FeedViewModel()

    @Published var items: [FeedItem] = [] {
        didSet { rebuildDerivedState() }
    }
    @Published var isLoading = false
    @Published var currentPage = 0
    @Published var hasMore = true
    @Published var selectedSite = AllPornStreamFeedScraper.supportedHost
    @Published var selectedPornHubSection: PornHubSection = .recommended
    @Published var pornHubUploaderURL: String?
    @Published var pornHubUploaderName: String?
    @Published var pornHubSubscriptions: [PornHubSubscription] = []
    @Published var isLoadingPornHubSubscriptions = false
    @Published var pornHubSubscriptionsError: String?
    @Published var filters = FeedFilterState() {
        didSet { rebuildDerivedState() }
    }
    @Published var sortMode: FeedSortMode = .newest {
        didSet { rebuildDerivedState() }
    }
    @Published var error: String?
    @Published var pendingScrollRestoreID: String?
    @Published private(set) var filteredItems: [FeedItem] = []
    @Published private(set) var dayBuckets: [FeedDayBucket] = []
    @Published private(set) var profileMatchReasons: [String: ProfileMatchReason] = [:]
    @Published private(set) var availableSites: [String] = []
    @Published private(set) var availableStudios: [String] = []
    @Published private(set) var availableCategories: [String] = []
    @Published private(set) var availableTags: [String] = []
    @Published private(set) var availableQualityLabels: [String] = []

    private var resolvingDateIDs: Set<String> = []
    private var visibleFeedAnchorID: String?
    private var pornHubReturnState: PornHubFeedReturnState?
    private var lastViewportPrefetchToken: String?

    init() {
        rebuildDerivedState()
    }

    private func buildFilteredItems() -> [FeedItem] {
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

    private func buildProfileMatchReasons() -> [String: ProfileMatchReason] {
        guard sortMode == .profileCurated,
              case .loaded(let result) = ProfileViewModel.shared.state else { return [:] }
        return Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, profileMatchReason($0, stats: result.stats))
        })
    }

    func rebuildDerivedState() {
        let nextFilteredItems = buildFilteredItems()
        filteredItems = nextFilteredItems
        profileMatchReasons = buildProfileMatchReasons()
        dayBuckets = Dictionary(grouping: nextFilteredItems) { item in
            Calendar.current.startOfDay(for: item.uploadDate)
        }
        .map { FeedDayBucket(date: $0.key, items: $0.value) }
        .sorted { $0.date > $1.date }
        availableSites = sortedValues(items.map(\.siteName))
        availableStudios = sortedValues(items.compactMap(\.studio))
        availableCategories = sortedValues(items.flatMap(\.categories))
        availableTags = topValues(items.flatMap(\.tags), limit: 30)
        availableQualityLabels = preferredQualityLabels(from: items)
    }

    var dateFilter: FeedDateFilter {
        get { filters.date }
        set { filters.date = newValue }
    }

    func loadInitial() async {
        guard items.isEmpty else { return }
        await refresh()
    }

    func refresh(clearPornHubReturnState: Bool = true) async {
        if clearPornHubReturnState {
            discardPornHubReturnState()
        }
        lastViewportPrefetchToken = nil
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
            if Self.shouldBlockPornHubLoadForLogin(
                selectedSite: selectedSite,
                selectedPornHubSection: selectedPornHubSection,
                pornHubUploaderURL: pornHubUploaderURL,
                isLoggedIn: PornHubSessionManager.shared.isLoggedIn
            ) {
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

            if Self.shouldStopPaginationForDateMiss(
                selectedSite: selectedSite,
                selectedPornHubSection: selectedPornHubSection,
                pornHubUploaderURL: pornHubUploaderURL,
                filters: filters,
                pageItems: pageItems
            ) {
                hasMore = false
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMoreMatchingCurrentFilters(pageBudget: Int = 4) async {
        guard !isLoading, hasMore else { return }

        let initialVisibleCount = filteredItems.count
        let maxPages = filters.isDefault ? 1 : max(pageBudget, 1)

        for _ in 0..<maxPages {
            let previousPage = currentPage
            await loadMore()

            if error != nil || currentPage == previousPage || !hasMore {
                break
            }
            if filters.isDefault || filteredItems.count > initialVisibleCount {
                break
            }
        }
    }

    func prefetchMoreIfNeeded(appearedItemID: String, threshold: Int, pageBudget: Int = 3) async {
        guard hasMore, !isLoading else { return }
        let triggerIDs = Self.viewportPrefetchTriggerIDs(
            for: filteredItems.map(\.id),
            threshold: threshold
        )
        guard triggerIDs.contains(appearedItemID) else { return }

        let token = "\(selectedSite)|\(selectedPornHubSection.rawValue)|\(pornHubUploaderURL ?? "")|\(currentPage)|\(filteredItems.count)"
        guard lastViewportPrefetchToken != token else { return }
        lastViewportPrefetchToken = token
        await loadMoreMatchingCurrentFilters(pageBudget: pageBudget)
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
        discardPornHubReturnState()
        pornHubUploaderURL = nil
        pornHubUploaderName = nil
        selectedPornHubSection = section
        applyPornHubDefaultSortForCurrentContext()
        await refresh()
    }

    func navigateToPornHubUploader(url: String, name: String) async {
        guard let normalizedURL = PornHubFeedScraper.normalizedUploaderURL(url) else { return }
        capturePornHubReturnStateIfNeeded()
        pornHubUploaderURL = normalizedURL
        pornHubUploaderName = name
        applyPornHubDefaultSortForCurrentContext()
        await refresh(clearPornHubReturnState: false)
    }

    @discardableResult
    func configurePornHubUploaderFromProfile(url: String, name: String) -> Bool {
        guard let normalizedURL = PornHubFeedScraper.normalizedUploaderURL(url) else { return false }
        selectedSite = PornHubFeedScraper.supportedHost
        selectedPornHubSection = .recommended
        filters = FeedFilterState()
        discardPornHubReturnState()
        pornHubUploaderURL = normalizedURL
        pornHubUploaderName = name
        applyPornHubDefaultSortForCurrentContext()
        return true
    }

    func openPornHubUploaderFromProfile(url: String, name: String) async {
        guard configurePornHubUploaderFromProfile(url: url, name: name) else { return }
        await refresh(clearPornHubReturnState: false)
    }

    func pornHubUploaderBack() async {
        if restorePornHubReturnState() {
            return
        }
        pornHubUploaderURL = nil
        pornHubUploaderName = nil
        applyPornHubDefaultSortForCurrentContext()
        await refresh()
    }

    func clearPornHubContext() {
        pornHubUploaderURL = nil
        pornHubUploaderName = nil
        discardPornHubReturnState()
    }

    func applyPornHubDefaultSortForCurrentContext() {
        guard selectedSite == PornHubFeedScraper.supportedHost else { return }
        sortMode = usesPornHubSourceOrder ? .feedOrder : .newest
    }

    func recordVisibleFeedAnchor(_ id: String?) {
        visibleFeedAnchorID = id
    }

    func clearPendingScrollRestoreID(_ id: String) {
        guard pendingScrollRestoreID == id else { return }
        pendingScrollRestoreID = nil
    }

    func discardPornHubReturnState() {
        pornHubReturnState = nil
        pendingScrollRestoreID = nil
    }

    func capturePornHubReturnStateIfNeeded() {
        guard selectedSite == PornHubFeedScraper.supportedHost,
              pornHubUploaderURL == nil,
              !items.isEmpty else { return }
        pornHubReturnState = PornHubFeedReturnState(
            section: selectedPornHubSection,
            items: items,
            currentPage: currentPage,
            hasMore: hasMore,
            sortMode: sortMode,
            anchorID: visibleFeedAnchorID ?? filteredItems.first?.id
        )
    }

    @discardableResult
    func restorePornHubReturnState() -> Bool {
        guard let state = pornHubReturnState else { return false }
        pornHubReturnState = nil
        selectedPornHubSection = state.section
        pornHubUploaderURL = nil
        pornHubUploaderName = nil
        items = state.items
        currentPage = state.currentPage
        hasMore = state.hasMore
        sortMode = state.sortMode
        error = nil
        pendingScrollRestoreID = state.anchorID
        return true
    }

    func loadPornHubSubscriptionsIfNeeded() async {
        guard selectedSite == PornHubFeedScraper.supportedHost,
              PornHubSessionManager.shared.isLoggedIn,
              pornHubSubscriptions.isEmpty,
              !isLoadingPornHubSubscriptions else { return }

        isLoadingPornHubSubscriptions = true
        pornHubSubscriptionsError = nil
        defer { isLoadingPornHubSubscriptions = false }

        do {
            pornHubSubscriptions = try await PornHubFeedScraper.fetchSubscriptions()
        } catch {
            pornHubSubscriptionsError = error.localizedDescription
        }
    }

    func refreshPornHubSubscriptions() async {
        guard selectedSite == PornHubFeedScraper.supportedHost,
              PornHubSessionManager.shared.isLoggedIn,
              !isLoadingPornHubSubscriptions else { return }

        isLoadingPornHubSubscriptions = true
        pornHubSubscriptionsError = nil
        defer { isLoadingPornHubSubscriptions = false }

        do {
            pornHubSubscriptions = try await PornHubFeedScraper.fetchSubscriptions()
        } catch {
            pornHubSubscriptionsError = error.localizedDescription
        }
    }

    private func preferredQualityLabels(from items: [FeedItem]) -> [String] {
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

    private var usesPornHubSourceOrder: Bool {
        selectedSite == PornHubFeedScraper.supportedHost &&
            (pornHubUploaderURL != nil || selectedPornHubSection.preservesFeedOrder)
    }

    nonisolated static func shouldStopPaginationForDateMiss(
        selectedSite: String,
        selectedPornHubSection: PornHubSection,
        pornHubUploaderURL: String?,
        filters: FeedFilterState,
        pageItems: [FeedItem]
    ) -> Bool {
        guard filters.date != .all,
              !pageItems.contains(where: { filters.date.matches($0.uploadDate) }) else { return false }

        let isPornHubSourceOrderedFeed = selectedSite == PornHubFeedScraper.supportedHost &&
            (pornHubUploaderURL != nil || selectedPornHubSection.preservesFeedOrder)
        return !isPornHubSourceOrderedFeed
    }

    nonisolated static func viewportPrefetchTriggerIDs(for itemIDs: [String], threshold: Int) -> Set<String> {
        guard !itemIDs.isEmpty else { return [] }
        let threshold = max(threshold, 1)
        let startIndex = itemIDs.count > threshold ? itemIDs.count - threshold : itemIDs.count - 1
        return Set(itemIDs[startIndex..<itemIDs.count])
    }

    nonisolated static func shouldBlockPornHubLoadForLogin(
        selectedSite: String,
        selectedPornHubSection: PornHubSection,
        pornHubUploaderURL: String?,
        isLoggedIn: Bool
    ) -> Bool {
        selectedSite == PornHubFeedScraper.supportedHost &&
            pornHubUploaderURL == nil &&
            selectedPornHubSection.requiresLogin &&
            !isLoggedIn
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
