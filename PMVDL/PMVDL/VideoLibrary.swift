import Foundation

@MainActor
class VideoLibrary: ObservableObject {
    static let shared = VideoLibrary()

    @Published var items: [LibraryItem] = []

    /// Default: 30 days
    var retentionDays: Int {
        get { UserDefaults.standard.integer(forKey: "libraryRetentionDays") == 0 ? 30 : UserDefaults.standard.integer(forKey: "libraryRetentionDays") }
        set { UserDefaults.standard.set(newValue, forKey: "libraryRetentionDays") }
    }

    private let userDefaultsKey = "videoLibrary"

    private init() {
        load()
        purgeExpired()
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data) {
            items = decoded.sorted { $0.extractedAt > $1.extractedAt }
        }
    }

    func save() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let before = items.count
        items.removeAll { $0.extractedAt < cutoff }
        if items.count != before { save() }
    }

    func add(_ item: LibraryItem) {
        items.insert(item, at: 0)
        save()
    }

    func addIfNew(_ item: LibraryItem) {
        let merged = Self.mergedLibraryItems(existing: items, incoming: item)
        guard merged != items else { return }
        items = merged
        save()
    }

    nonisolated static func mergedLibraryItems(existing: [LibraryItem], incoming: LibraryItem) -> [LibraryItem] {
        var copy = existing
        if let idx = copy.firstIndex(where: { $0.url == incoming.url }) {
            if (copy[idx].thumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
               let thumbnailURL = incoming.thumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !thumbnailURL.isEmpty {
                copy[idx].thumbnailURL = thumbnailURL
            }
            return copy
        }

        copy.insert(incoming, at: 0)
        return copy
    }

    func remove(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func updateRemotePaths(for item: LibraryItem, cloud: CloudTarget, path: String) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].remotePaths[cloud.rawValue] = path
        save()
    }

    func updateThumbnailURL(for item: LibraryItem, thumbnailURL: String) {
        updateThumbnailURL(forID: item.id, thumbnailURL: thumbnailURL)
    }

    func updateThumbnailURL(forID id: UUID, thumbnailURL: String) {
        let normalized = thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].thumbnailURL != normalized else { return }

        var copy = items
        copy[idx].thumbnailURL = normalized
        items = copy
        save()
    }
}
