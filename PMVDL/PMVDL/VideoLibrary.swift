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
        if !items.contains(where: { $0.url == item.url }) {
            add(item)
        }
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
}
