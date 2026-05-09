import SwiftUI

struct FeedItem: Identifiable, Hashable {
    let id: String
    let title: String
    let url: String
    let thumbnailURL: String?
    let previewURLs: [String]
    let previewVideoURL: String?
    let referer: String?
    let uploadDate: Date
    let uploadDateIsApproximate: Bool
    let viewCount: Int
    let siteName: String
    let studio: String?
    let studioURL: String?
    let durationSeconds: Int?
    let categories: [String]
    let tags: [String]
    let performers: [String]
    let qualityLabels: [String]
    let sourceKind: FeedSourceKind

    init(
        id: String,
        title: String,
        url: String,
        thumbnailURL: String?,
        previewURLs: [String] = [],
        previewVideoURL: String? = nil,
        referer: String? = nil,
        uploadDate: Date,
        uploadDateIsApproximate: Bool = false,
        viewCount: Int,
        siteName: String,
        studio: String?,
        studioURL: String? = nil,
        durationSeconds: Int? = nil,
        categories: [String] = [],
        tags: [String] = [],
        performers: [String] = [],
        qualityLabels: [String] = [],
        sourceKind: FeedSourceKind = .siteFeed
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.previewURLs = previewURLs
        self.previewVideoURL = previewVideoURL
        self.referer = referer
        self.uploadDate = uploadDate
        self.uploadDateIsApproximate = uploadDateIsApproximate
        self.viewCount = viewCount
        self.siteName = siteName
        self.studio = studio
        self.studioURL = studioURL
        self.durationSeconds = durationSeconds
        self.categories = categories
        self.tags = tags
        self.performers = performers
        self.qualityLabels = qualityLabels
        self.sourceKind = sourceKind
    }

    func withUploadDate(_ date: Date, isApproximate: Bool) -> FeedItem {
        FeedItem(
            id: id,
            title: title,
            url: url,
            thumbnailURL: thumbnailURL,
            previewURLs: previewURLs,
            previewVideoURL: previewVideoURL,
            referer: referer,
            uploadDate: date,
            uploadDateIsApproximate: isApproximate,
            viewCount: viewCount,
            siteName: siteName,
            studio: studio,
            studioURL: studioURL,
            durationSeconds: durationSeconds,
            categories: categories,
            tags: tags,
            performers: performers,
            qualityLabels: qualityLabels,
            sourceKind: sourceKind
        )
    }
}

struct PornHubSubscription: Identifiable, Hashable {
    let name: String
    let url: String

    var id: String { url.lowercased() }
}

enum FeedSourceKind: String, Hashable, CaseIterable, Identifiable {
    case siteFeed
    case linkList
    case searchResults

    var id: String { rawValue }
}

enum PornHubSection: String, CaseIterable, Identifiable {
    case recommended
    case hot
    case subscriptions
    case liked
    case favorites
    case playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommended: return "Recommended"
        case .hot: return "Hot"
        case .subscriptions: return "Subscriptions"
        case .liked: return "Liked"
        case .favorites: return "Favorites"
        case .playlists: return "Playlists"
        }
    }

    var icon: String {
        switch self {
        case .recommended: return "sparkles"
        case .hot: return "flame.fill"
        case .subscriptions: return "bell.fill"
        case .liked: return "heart.fill"
        case .favorites: return "star.fill"
        case .playlists: return "list.bullet"
        }
    }

    var requiresLogin: Bool {
        switch self {
        case .recommended, .hot:
            return false
        case .subscriptions, .liked, .favorites, .playlists:
            return true
        }
    }

    var preservesFeedOrder: Bool {
        switch self {
        case .recommended, .hot:
            return false
        case .subscriptions, .liked, .favorites, .playlists:
            return true
        }
    }

    func feedURL(page: Int) -> URL? {
        switch self {
        case .recommended:
            var components = URLComponents(string: "https://www.pornhub.com/recommended")!
            if page > 1 {
                components.queryItems = [URLQueryItem(name: "page", value: "\(page)")]
            }
            return components.url
        case .hot:
            var components = URLComponents(string: "https://www.pornhub.com/video")!
            components.queryItems = [URLQueryItem(name: "o", value: "ht")]
            if page > 1 {
                components.queryItems?.append(URLQueryItem(name: "page", value: "\(page)"))
            }
            return components.url
        case .subscriptions:
            var components = URLComponents(string: "https://www.pornhub.com/subscriptions")!
            if page > 1 {
                components.queryItems = [URLQueryItem(name: "page", value: "\(page)")]
            }
            return components.url
        case .liked:
            var components = URLComponents(string: "https://www.pornhub.com/likedvideos")!
            if page > 1 {
                components.queryItems = [URLQueryItem(name: "page", value: "\(page)")]
            }
            return components.url
        case .favorites:
            var components = URLComponents(string: "https://www.pornhub.com/users/favorites")!
            if page > 1 {
                components.queryItems = [URLQueryItem(name: "page", value: "\(page)")]
            }
            return components.url
        case .playlists:
            var components = URLComponents(string: "https://www.pornhub.com/playlists")!
            if page > 1 {
                components.queryItems = [URLQueryItem(name: "page", value: "\(page)")]
            }
            return components.url
        }
    }
}

enum FeedDateFilter: String, CaseIterable, Identifiable {
    case today
    case yesterday
    case last3Days
    case thisWeek
    case last7Days
    case thisMonth
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .last3Days: return "Last 3 Days"
        case .thisWeek: return "This Week"
        case .last7Days: return "Last 7 Days"
        case .thisMonth: return "This Month"
        case .all: return "All"
        }
    }

    func matches(_ date: Date, calendar: Calendar = .current, now: Date = Date()) -> Bool {
        switch self {
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
            return calendar.isDate(date, inSameDayAs: yesterday)
        case .last3Days:
            guard let start = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: now)) else { return false }
            return date >= start && date <= now
        case .thisWeek:
            return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        case .last7Days:
            guard let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) else { return false }
            return date >= start && date <= now
        case .thisMonth:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .all:
            return true
        }
    }
}

enum FeedSortMode: String, CaseIterable, Identifiable {
    case feedOrder
    case newest
    case oldest
    case mostViewed
    case shortest
    case longest
    case titleAZ
    case siteThenNewest
    case profileCurated = "profileCurated"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feedOrder: return "Feed Order"
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .mostViewed: return "Most Viewed"
        case .shortest: return "Shortest"
        case .longest: return "Longest"
        case .titleAZ: return "Title A-Z"
        case .siteThenNewest: return "Site + Newest"
        case .profileCurated: return "Profile Match"
        }
    }

    func sort(_ items: [FeedItem]) -> [FeedItem] {
        switch self {
        case .feedOrder:
            return items
        case .newest:
            return items.sorted { $0.uploadDate > $1.uploadDate }
        case .oldest:
            return items.sorted { $0.uploadDate < $1.uploadDate }
        case .mostViewed:
            return items.sorted { $0.viewCount > $1.viewCount }
        case .shortest:
            return items.sorted {
                ($0.durationSeconds ?? Int.max, $0.title) < ($1.durationSeconds ?? Int.max, $1.title)
            }
        case .longest:
            return items.sorted {
                ($0.durationSeconds ?? -1, $0.title) > ($1.durationSeconds ?? -1, $1.title)
            }
        case .titleAZ:
            return items.sorted {
                FeedDisplay.title(for: $0).localizedCaseInsensitiveCompare(FeedDisplay.title(for: $1)) == .orderedAscending
            }
        case .siteThenNewest:
            return items.sorted {
                if $0.siteName == $1.siteName {
                    return $0.uploadDate > $1.uploadDate
                }
                return $0.siteName.localizedCaseInsensitiveCompare($1.siteName) == .orderedAscending
            }
        case .profileCurated:
            return items
        }
    }
}

struct FeedSiteCapabilities {
    let hasRealDates: Bool
    let hasViewCounts: Bool
    let hasDuration: Bool
    let hasStudios: Bool
    let hasQualityLabels: Bool
    let groupsByDate: Bool

    var availableSortModes: [FeedSortMode] {
        FeedSortMode.allCases.filter { mode in
            switch mode {
            case .feedOrder:
                return !groupsByDate
            case .newest, .oldest:
                return hasRealDates
            case .mostViewed:
                return hasViewCounts
            case .shortest, .longest:
                return hasDuration
            case .titleAZ:
                return true
            case .siteThenNewest:
                return false
            case .profileCurated:
                return true
            }
        }
    }

    static let allPornStream = FeedSiteCapabilities(
        hasRealDates: true,
        hasViewCounts: true,
        hasDuration: false,
        hasStudios: true,
        hasQualityLabels: false,
        groupsByDate: true
    )

    static let rentry = FeedSiteCapabilities(
        hasRealDates: true,
        hasViewCounts: false,
        hasDuration: false,
        hasStudios: true,
        hasQualityLabels: false,
        groupsByDate: true
    )

    static let hqporner = FeedSiteCapabilities(
        hasRealDates: true,
        hasViewCounts: false,
        hasDuration: true,
        hasStudios: false,
        hasQualityLabels: true,
        groupsByDate: true
    )

    static let pornhub = FeedSiteCapabilities(
        hasRealDates: true,
        hasViewCounts: true,
        hasDuration: true,
        hasStudios: true,
        hasQualityLabels: false,
        groupsByDate: false
    )

    static func capabilities(for site: String) -> FeedSiteCapabilities {
        switch site {
        case AllPornStreamFeedScraper.supportedHost:
            return .allPornStream
        case RentryFeedScraper.supportedHost:
            return .rentry
        case HQPornerFeedScraper.supportedHost:
            return .hqporner
        case PornHubFeedScraper.supportedHost:
            return .pornhub
        default:
            return .allPornStream
        }
    }
}

struct FeedSiteTheme {
    let accent: Color
    let backgroundTint: Color
    let displayName: String
    let icon: String
    let logoText: (prefix: String, suffix: String)?

    static let allPornStream = FeedSiteTheme(
        accent: Color(hex: "#00BCD4"),
        backgroundTint: Color(hex: "#001820"),
        displayName: "AllPornStream",
        icon: "play.rectangle.on.rectangle.fill",
        logoText: ("AllPorn", "STREAM")
    )

    static let rentry = FeedSiteTheme(
        accent: Color(hex: "#7CB342"),
        backgroundTint: Color(hex: "#0A1A08"),
        displayName: "OnlyFan420",
        icon: "lock.open.fill",
        logoText: ("OnlyFan", "420")
    )

    static let hqporner = FeedSiteTheme(
        accent: Color(hex: "#FF6070"),
        backgroundTint: Color(hex: "#1A0508"),
        displayName: "HQPorner",
        icon: "film.stack.fill",
        logoText: ("HQ", "PORNER")
    )

    static let pornhub = FeedSiteTheme(
        accent: Color(hex: "#FF9000"),
        backgroundTint: Color(hex: "#1A0F00"),
        displayName: "PornHub",
        icon: "play.circle.fill",
        logoText: ("Porn", "Hub")
    )

    static func theme(for site: String) -> FeedSiteTheme {
        switch site {
        case AllPornStreamFeedScraper.supportedHost:
            return .allPornStream
        case RentryFeedScraper.supportedHost:
            return .rentry
        case HQPornerFeedScraper.supportedHost:
            return .hqporner
        case PornHubFeedScraper.supportedHost:
            return .pornhub
        default:
            return .allPornStream
        }
    }
}

struct FeedDayBucket: Identifiable {
    let date: Date
    let items: [FeedItem]

    var id: Date { date }
}

struct FeedActiveFilterChip: Identifiable, Equatable {
    let id: String
    let title: String
}

struct FeedFilterState: Equatable {
    var date: FeedDateFilter = .all
    var query = ""
    var minViews: Int?
    var minDurationSeconds: Int?
    var maxDurationSeconds: Int?
    var selectedSites: Set<String> = []
    var selectedStudios: Set<String> = []
    var selectedCategories: Set<String> = []
    var selectedTags: Set<String> = []
    var selectedQualityLabels: Set<String> = []
    var requireAllTags = false

    var isDefault: Bool {
        self == FeedFilterState()
    }

    var activeCount: Int {
        var count = 0
        if date != .all { count += 1 }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        if minViews != nil { count += 1 }
        if minDurationSeconds != nil || maxDurationSeconds != nil { count += 1 }
        if !selectedSites.isEmpty { count += 1 }
        if !selectedStudios.isEmpty { count += 1 }
        if !selectedCategories.isEmpty { count += 1 }
        if !selectedTags.isEmpty { count += 1 }
        if !selectedQualityLabels.isEmpty { count += 1 }
        return count
    }

    var activeChips: [FeedActiveFilterChip] {
        var chips: [FeedActiveFilterChip] = []
        if date != .all {
            chips.append(FeedActiveFilterChip(id: "date", title: date.title))
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            chips.append(FeedActiveFilterChip(id: "query", title: "Search: \(trimmedQuery)"))
        }

        if let minViews {
            chips.append(FeedActiveFilterChip(id: "views", title: "\(FeedDisplay.viewCount(minViews))+"))
        }

        if let durationTitle = durationChipTitle {
            chips.append(FeedActiveFilterChip(id: "duration", title: durationTitle))
        }

        chips.append(contentsOf: selectedQualityLabels.sorted().map {
            FeedActiveFilterChip(id: "quality:\($0)", title: $0)
        })
        chips.append(contentsOf: selectedStudios.sorted().map {
            FeedActiveFilterChip(id: "studio:\($0)", title: $0)
        })
        chips.append(contentsOf: selectedCategories.sorted().map {
            FeedActiveFilterChip(id: "category:\($0)", title: $0)
        })
        chips.append(contentsOf: selectedTags.sorted().map {
            FeedActiveFilterChip(id: "tag:\($0)", title: "#\($0)")
        })
        return chips
    }

    mutating func removeActiveChip(id: String) {
        switch id {
        case "date":
            date = .all
        case "query":
            query = ""
        case "views":
            minViews = nil
        case "duration":
            minDurationSeconds = nil
            maxDurationSeconds = nil
        default:
            if let value = value(after: "quality:", in: id) {
                selectedQualityLabels.remove(value)
            } else if let value = value(after: "studio:", in: id) {
                selectedStudios.remove(value)
            } else if let value = value(after: "category:", in: id) {
                selectedCategories.remove(value)
            } else if let value = value(after: "tag:", in: id) {
                selectedTags.remove(value)
                if selectedTags.isEmpty {
                    requireAllTags = false
                }
            }
        }
    }

    func matches(_ item: FeedItem, calendar: Calendar = .current, now: Date = Date()) -> Bool {
        guard date.matches(item.uploadDate, calendar: calendar, now: now) else { return false }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !trimmedQuery.isEmpty {
            let haystack = ([item.title, item.siteName, item.studio ?? ""] + item.categories + item.tags + item.performers + item.qualityLabels)
                .joined(separator: " ")
                .lowercased()
            guard haystack.contains(trimmedQuery) else { return false }
        }

        if let minViews, item.viewCount < minViews { return false }
        if let minDurationSeconds, (item.durationSeconds ?? -1) < minDurationSeconds { return false }
        if let maxDurationSeconds, (item.durationSeconds ?? Int.max) > maxDurationSeconds { return false }
        if !selectedSites.isEmpty, !selectedSites.contains(item.siteName) { return false }
        if !selectedStudios.isEmpty, !selectedStudios.contains(item.studio ?? "") { return false }
        if !selectedCategories.isEmpty, selectedCategories.isDisjoint(with: Set(item.categories)) { return false }
        if !selectedQualityLabels.isEmpty, selectedQualityLabels.isDisjoint(with: Set(item.qualityLabels)) { return false }

        if !selectedTags.isEmpty {
            let itemTags = Set(item.tags)
            if requireAllTags {
                guard selectedTags.isSubset(of: itemTags) else { return false }
            } else {
                guard !selectedTags.isDisjoint(with: itemTags) else { return false }
            }
        }

        return true
    }

    private var durationChipTitle: String? {
        switch (minDurationSeconds, maxDurationSeconds) {
        case (nil, nil):
            return nil
        case (nil, let max?):
            return "< \(FeedDisplay.duration(max + 1))"
        case (let min?, nil):
            return "\(FeedDisplay.duration(min))+"
        case (let min?, let max?):
            return "\(FeedDisplay.duration(min))-\(FeedDisplay.duration(max))"
        }
    }

    private func value(after prefix: String, in id: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }
}
