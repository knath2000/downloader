import Foundation

struct FeedItem: Identifiable, Hashable {
    let id: String
    let title: String
    let url: String
    let thumbnailURL: String?
    let uploadDate: Date
    let viewCount: Int
    let siteName: String
    let studio: String?
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
        uploadDate: Date,
        viewCount: Int,
        siteName: String,
        studio: String?,
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
        self.uploadDate = uploadDate
        self.viewCount = viewCount
        self.siteName = siteName
        self.studio = studio
        self.durationSeconds = durationSeconds
        self.categories = categories
        self.tags = tags
        self.performers = performers
        self.qualityLabels = qualityLabels
        self.sourceKind = sourceKind
    }
}

enum FeedSourceKind: String, Hashable, CaseIterable, Identifiable {
    case siteFeed
    case linkList
    case searchResults

    var id: String { rawValue }
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
    case newest
    case oldest
    case mostViewed
    case shortest
    case longest
    case titleAZ
    case siteThenNewest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .mostViewed: return "Most Viewed"
        case .shortest: return "Shortest"
        case .longest: return "Longest"
        case .titleAZ: return "Title A-Z"
        case .siteThenNewest: return "Site + Newest"
        }
    }

    func sort(_ items: [FeedItem]) -> [FeedItem] {
        switch self {
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
