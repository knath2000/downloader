import Foundation

struct PornHubFeedReturnState {
    let section: PornHubSection
    let items: [FeedItem]
    let currentPage: Int
    let hasMore: Bool
    let sortMode: FeedSortMode
    let anchorID: String?
}

struct EpornerFeedReturnState {
    let section: EpornerSection
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
    @Published var selectedEpornerSection: EpornerSection = .recommended
    @Published var epornerUploaderURL: String?
    @Published var epornerUploaderName: String?
    @Published var epornerSubscriptions: [PornHubSubscription] = []
    @Published var isLoadingEpornerSubscriptions = false
    @Published var epornerSubscriptionsError: String?
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
    @Published private(set) var availableSites: [String] = []
    @Published private(set) var availableStudios: [String] = []
    @Published private(set) var availableCategories: [String] = []
    @Published private(set) var availableTags: [String] = []
    @Published private(set) var availableQualityLabels: [String] = []

    private var resolvingDateIDs: Set<String> = []
    private var visibleFeedAnchorID: String?
    private var pornHubReturnState: PornHubFeedReturnState?
    private var epornerReturnState: EpornerFeedReturnState?
    private var lastViewportPrefetchToken: String?

    init() {
        rebuildDerivedState()
    }

    private func buildFilteredItems() -> [FeedItem] {
        let base = items.filter { filters.matches($0) }
        return sortMode.sort(base)
    }

    func rebuildDerivedState() {
        let nextFilteredItems = buildFilteredItems()
        filteredItems = nextFilteredItems
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
            discardEpornerReturnState()
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
            if Self.shouldBlockEpornerLoadForLogin(
                selectedSite: selectedSite,
                selectedEpornerSection: selectedEpornerSection,
                epornerUploaderURL: epornerUploaderURL,
                isLoggedIn: EpornerSessionManager.shared.isLoggedIn
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
                selectedEpornerSection: selectedEpornerSection,
                epornerUploaderURL: epornerUploaderURL,
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

        let token = "\(selectedSite)|\(selectedPornHubSection.rawValue)|\(pornHubUploaderURL ?? "")|\(selectedEpornerSection.rawValue)|\(epornerUploaderURL ?? "")|\(currentPage)|\(filteredItems.count)"
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

        var resolvedDates: [String: Date] = [:]

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
                guard let date else { continue }
                resolvedDates[id] = date
            }
        }

        guard !resolvedDates.isEmpty else { return }

        var updated = items
        var didChange = false
        for index in updated.indices {
            if let date = resolvedDates[updated[index].id] {
                updated[index] = updated[index].withUploadDate(date, isApproximate: false)
                didChange = true
            }
        }
        if didChange {
            items = updated
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

    func selectEpornerSection(_ section: EpornerSection) async {
        guard selectedEpornerSection != section else { return }
        discardEpornerReturnState()
        epornerUploaderURL = nil
        epornerUploaderName = nil
        selectedEpornerSection = section
        applyEpornerDefaultSortForCurrentContext()
        await refresh()
    }

    func navigateToEpornerUploader(url: String, name: String) async {
        guard let normalizedURL = EpornerFeedScraper.normalizedUploaderURL(url) else { return }
        captureEpornerReturnStateIfNeeded()
        epornerUploaderURL = normalizedURL
        epornerUploaderName = name
        applyEpornerDefaultSortForCurrentContext()
        await refresh(clearPornHubReturnState: false)
    }

    func epornerUploaderBack() async {
        if restoreEpornerReturnState() {
            return
        }
        epornerUploaderURL = nil
        epornerUploaderName = nil
        applyEpornerDefaultSortForCurrentContext()
        await refresh()
    }

    func clearEpornerContext() {
        epornerUploaderURL = nil
        epornerUploaderName = nil
        discardEpornerReturnState()
    }

    func applyPornHubDefaultSortForCurrentContext() {
        guard selectedSite == PornHubFeedScraper.supportedHost else { return }
        sortMode = usesPornHubSourceOrder ? .feedOrder : .newest
    }

    func applyEpornerDefaultSortForCurrentContext() {
        guard selectedSite == EpornerFeedScraper.supportedHost else { return }
        sortMode = usesEpornerSourceOrder ? .feedOrder : .newest
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

    func discardEpornerReturnState() {
        epornerReturnState = nil
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

    func captureEpornerReturnStateIfNeeded() {
        guard selectedSite == EpornerFeedScraper.supportedHost,
              epornerUploaderURL == nil,
              !items.isEmpty else { return }
        epornerReturnState = EpornerFeedReturnState(
            section: selectedEpornerSection,
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

    @discardableResult
    func restoreEpornerReturnState() -> Bool {
        guard let state = epornerReturnState else { return false }
        epornerReturnState = nil
        selectedEpornerSection = state.section
        epornerUploaderURL = nil
        epornerUploaderName = nil
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

    func loadEpornerSubscriptionsIfNeeded() async {
        guard selectedSite == EpornerFeedScraper.supportedHost,
              EpornerSessionManager.shared.isLoggedIn,
              epornerSubscriptions.isEmpty,
              !isLoadingEpornerSubscriptions else { return }

        isLoadingEpornerSubscriptions = true
        epornerSubscriptionsError = nil
        defer { isLoadingEpornerSubscriptions = false }

        do {
            epornerSubscriptions = try await EpornerFeedScraper.fetchSubscriptions()
        } catch {
            epornerSubscriptionsError = error.localizedDescription
        }
    }

    func refreshEpornerSubscriptions() async {
        guard selectedSite == EpornerFeedScraper.supportedHost,
              EpornerSessionManager.shared.isLoggedIn,
              !isLoadingEpornerSubscriptions else { return }

        isLoadingEpornerSubscriptions = true
        epornerSubscriptionsError = nil
        defer { isLoadingEpornerSubscriptions = false }

        do {
            epornerSubscriptions = try await EpornerFeedScraper.fetchSubscriptions()
        } catch {
            epornerSubscriptionsError = error.localizedDescription
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
        case EpornerFeedScraper.supportedHost:
            return EpornerFeedScraper.self
        default:
            throw FeedScraperError.unsupportedSite(selectedSite)
        }
    }

    private var usesPornHubSourceOrder: Bool {
        selectedSite == PornHubFeedScraper.supportedHost &&
            (pornHubUploaderURL != nil || selectedPornHubSection.preservesFeedOrder)
    }

    private var usesEpornerSourceOrder: Bool {
        selectedSite == EpornerFeedScraper.supportedHost &&
            (epornerUploaderURL != nil || selectedEpornerSection.preservesFeedOrder)
    }

    nonisolated static func shouldStopPaginationForDateMiss(
        selectedSite: String,
        selectedPornHubSection: PornHubSection,
        pornHubUploaderURL: String?,
        selectedEpornerSection: EpornerSection,
        epornerUploaderURL: String?,
        filters: FeedFilterState,
        pageItems: [FeedItem]
    ) -> Bool {
        guard filters.date != .all,
              !pageItems.contains(where: { filters.date.matches($0.uploadDate) }) else { return false }

        let isSourceOrderedFeed = (selectedSite == PornHubFeedScraper.supportedHost &&
                                   (pornHubUploaderURL != nil || selectedPornHubSection.preservesFeedOrder)) ||
                                  (selectedSite == EpornerFeedScraper.supportedHost &&
                                   (epornerUploaderURL != nil || selectedEpornerSection.preservesFeedOrder))
        return !isSourceOrderedFeed
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

    nonisolated static func shouldBlockEpornerLoadForLogin(
        selectedSite: String,
        selectedEpornerSection: EpornerSection,
        epornerUploaderURL: String?,
        isLoggedIn: Bool
    ) -> Bool {
        selectedSite == EpornerFeedScraper.supportedHost &&
            epornerUploaderURL == nil &&
            selectedEpornerSection.requiresLogin &&
            !isLoggedIn
    }

    private func feedPage(page: Int) async throws -> [FeedItem] {
        if selectedSite == PornHubFeedScraper.supportedHost {
            return try await PornHubFeedScraper.fetchPage(page: page, section: selectedPornHubSection)
        }
        if selectedSite == EpornerFeedScraper.supportedHost {
            return try await EpornerFeedScraper.fetchPage(page: page, section: selectedEpornerSection)
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
