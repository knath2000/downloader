import Foundation

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var items: [FeedItem] = []
    @Published var isLoading = false
    @Published var currentPage = 0
    @Published var hasMore = true
    @Published var selectedSite = AllPornStreamFeedScraper.supportedHost
    @Published var filters = FeedFilterState()
    @Published var sortMode: FeedSortMode = .newest
    @Published var error: String?

    var filteredItems: [FeedItem] {
        sortMode.sort(items.filter { filters.matches($0) })
    }

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
            let pageItems = try await scraper().fetchPage(page: nextPage)
            if pageItems.isEmpty {
                hasMore = false
                return
            }

            let existingIDs = Set(items.map(\.id))
            items.append(contentsOf: pageItems.filter { !existingIDs.contains($0.id) })
            currentPage = nextPage

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

    func resetPaginationForFilter() {
        if filters.date == .all {
            hasMore = true
        }
    }

    func clearFilters() {
        filters = FeedFilterState()
        resetPaginationForFilter()
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
        default:
            throw FeedScraperError.unsupportedSite(selectedSite)
        }
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
