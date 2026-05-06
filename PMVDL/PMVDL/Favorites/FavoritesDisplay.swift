import Foundation

enum FavoritesSortMode: String, CaseIterable, Identifiable {
    case newestFavorited
    case oldestFavorited
    case newestUploaded
    case mostViewed
    case titleAZ
    case site

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newestFavorited: return "Newest Saved"
        case .oldestFavorited: return "Oldest Saved"
        case .newestUploaded: return "Newest Uploaded"
        case .mostViewed: return "Most Viewed"
        case .titleAZ: return "Title A-Z"
        case .site: return "Site"
        }
    }
}

enum FavoritesDisplay {
    static func filteredAndSorted(
        items: [FeedFavoriteItem],
        query: String,
        sortMode: FavoritesSortMode
    ) -> [FeedFavoriteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = items.filter { item in
            guard !trimmed.isEmpty else { return true }
            return searchText(for: item).contains(trimmed)
        }

        return sorted(filtered, by: sortMode)
    }

    static func searchText(for item: FeedFavoriteItem) -> String {
        ([item.title, item.url, item.siteName, item.studio ?? ""] +
         item.categories +
         item.tags +
         item.performers +
         item.qualityLabels)
            .joined(separator: " ")
            .lowercased()
    }

    static func sorted(_ items: [FeedFavoriteItem], by sortMode: FavoritesSortMode) -> [FeedFavoriteItem] {
        switch sortMode {
        case .newestFavorited:
            return items.sorted { $0.favoritedAt > $1.favoritedAt }
        case .oldestFavorited:
            return items.sorted { $0.favoritedAt < $1.favoritedAt }
        case .newestUploaded:
            return items.sorted { $0.uploadDate > $1.uploadDate }
        case .mostViewed:
            return items.sorted { $0.viewCount > $1.viewCount }
        case .titleAZ:
            return items.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .site:
            return items.sorted {
                if $0.siteName == $1.siteName {
                    return $0.favoritedAt > $1.favoritedAt
                }
                return $0.siteName.localizedCaseInsensitiveCompare($1.siteName) == .orderedAscending
            }
        }
    }

    static func viewCount(_ value: Int) -> String {
        FeedDisplay.viewCount(value)
    }

    static func duration(_ seconds: Int) -> String {
        FeedDisplay.duration(seconds)
    }
}
