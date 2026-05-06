import Foundation

@MainActor
final class FeedFavoritesStore: ObservableObject {
    static let shared = FeedFavoritesStore()

    @Published private(set) var items: [FeedFavoriteItem] = []

    private let userDefaultsKey = "feedFavorites"

    var hasFavorites: Bool {
        !items.isEmpty
    }

    var count: Int {
        items.count
    }

    private init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([FeedFavoriteItem].self, from: data) else {
            items = []
            return
        }

        items = Self.sortedAndDeduped(decoded)
    }

    func save() {
        guard let encoded = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
    }

    func contains(url rawURL: String) -> Bool {
        let normalized = FeedFavoriteItem.normalizedURL(rawURL)
        return items.contains { $0.id == normalized }
    }

    func add(_ item: FeedFavoriteItem) {
        guard !contains(url: item.url) else { return }
        items.insert(item, at: 0)
        save()
    }

    func add(feedItem: FeedItem) {
        add(FeedFavoriteItem(feedItem: feedItem))
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    func remove(url rawURL: String) {
        let normalized = FeedFavoriteItem.normalizedURL(rawURL)
        remove(id: normalized)
    }

    func toggle(feedItem: FeedItem) {
        if contains(url: feedItem.url) {
            remove(url: feedItem.url)
        } else {
            add(feedItem: feedItem)
        }
    }

    nonisolated static func sortedAndDeduped(_ input: [FeedFavoriteItem]) -> [FeedFavoriteItem] {
        var seen = Set<String>()
        var output: [FeedFavoriteItem] = []

        for item in input.sorted(by: { $0.favoritedAt > $1.favoritedAt }) {
            guard !seen.contains(item.id) else { continue }
            seen.insert(item.id)
            output.append(item)
        }

        return output
    }
}
