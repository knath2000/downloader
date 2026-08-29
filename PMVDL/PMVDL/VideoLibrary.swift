import Foundation

struct LibraryItemMetadataUpdate {
    let id: UUID
    let uploaderName: String?
    let uploaderURL: String?
    let sourceSiteName: String?
    let thumbnailURL: String?
}

struct LibraryOrganizationUpdate {
    let id: UUID
    let tags: [String]
    let collectionName: String?
}

enum LibraryRemoteVerifier {
    static func verify(_ item: LibraryItem) async -> String {
        var confirmed: [String] = []
        var failures: [String] = []

        for (destination, path) in item.remotePaths where !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                switch destination {
                case CloudTarget.local.rawValue:
                    guard FileManager.default.fileExists(atPath: path) else { throw VerificationError.missing }
                case CloudTarget.mega.rawValue:
                    let remoteURL = URL(fileURLWithPath: path)
                    let files = try await MegaManager.listRemoteFiles(remotePath: remoteURL.deletingLastPathComponent().path)
                    guard files.contains(remoteURL.lastPathComponent) else { throw VerificationError.missing }
                case CloudTarget.gdrive.rawValue, CloudTarget.seedbox.rawValue:
                    failures.append("\(CloudTarget(rawValue: destination)?.displayName ?? destination): no longer supported")
                    continue
                default:
                    continue
                }
                confirmed.append(CloudTarget(rawValue: destination)?.displayName ?? destination)
            } catch {
                failures.append("\(CloudTarget(rawValue: destination)?.displayName ?? destination): \(error.localizedDescription)")
            }
        }

        if confirmed.isEmpty, failures.isEmpty { return "No saved destination to verify." }
        if failures.isEmpty { return "Confirmed \(confirmed.joined(separator: ", "))." }
        if confirmed.isEmpty { return failures.joined(separator: " · ") }
        return "Confirmed \(confirmed.joined(separator: ", ")) · \(failures.joined(separator: " · "))"
    }

    private enum VerificationError: LocalizedError {
        case missing

        var errorDescription: String? {
            switch self {
            case .missing: return "file was not found"
            }
        }
    }
}

@MainActor
class VideoLibrary: ObservableObject {
    static let shared = VideoLibrary()

    @Published var items: [LibraryItem] = []
    @Published private(set) var isRestoring = true

    /// Default: 30 days
    var retentionDays: Int {
        get { UserDefaults.standard.integer(forKey: "libraryRetentionDays") == 0 ? 30 : UserDefaults.standard.integer(forKey: "libraryRetentionDays") }
        set { UserDefaults.standard.set(newValue, forKey: "libraryRetentionDays") }
    }

    private let userDefaultsKey = "videoLibrary"

    private init() {}

    func restorePersistedLibrary() async {
        guard isRestoring else { return }
        if let snapshot = try? await LustreAgentClient().collections(), !snapshot.library.isEmpty {
            items = snapshot.library.map(\.libraryItem)
            isRestoring = false
            LibraryPipelineStore.shared.rebuild(libraryItems: items)
            return
        }
        let data = UserDefaults.standard.data(forKey: userDefaultsKey)
        let restored = await Task.detached(priority: .userInitiated) {
            let decoded = data.flatMap {
                try? JSONDecoder().decode([LibraryItem].self, from: $0)
            } ?? []
            return decoded.sorted {
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.extractedAt > $1.extractedAt
            }
        }.value
        let currentIDs = Set(items.map(\.id))
        items = restored.filter { !currentIDs.contains($0.id) } + items
        isRestoring = false
        // Reassign sequential sortOrders if there are legacy items without sortOrder
        reassignSequentialSortOrdersIfNeeded()
        purgeExpired()
    }

    func save() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
        LibraryPipelineStore.shared.rebuild(libraryItems: items)
    }

    /// Reassigns sequential sortOrders to all items, preserving relative order
    private func reassignSequentialSortOrders() {
        for (index, item) in items.enumerated() {
            if item.sortOrder != index {
                items[index].sortOrder = index
            }
        }
    }

    /// Only reassigns if there are items with Int.max (legacy items without sortOrder)
    private func reassignSequentialSortOrdersIfNeeded() {
        let hasLegacyItems = items.contains { $0.sortOrder == Int.max }
        if hasLegacyItems {
            reassignSequentialSortOrders()
            save()
        }
    }

    /// Clears all custom sort orders, reverting to date-based sorting
    func resetSortOrder() {
        for index in items.indices {
            items[index].sortOrder = Int.max
        }
        save()
    }

    func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        let before = items.count
        items.removeAll { $0.extractedAt < cutoff }
        if items.count != before { save() }
    }

    func add(_ item: LibraryItem) {
        var newItem = item
        // Assign sortOrder = max + 1 for new items (append to end)
        let maxSortOrder = items.map(\.sortOrder).filter { $0 != Int.max }.max() ?? 0
        newItem.sortOrder = maxSortOrder + 1
        items.insert(newItem, at: 0)
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
            // Preserve existing sortOrder when merging
            mergeMetadata(into: &copy[idx], from: incoming)
            return copy
        }

        var newItem = incoming
        // Assign sortOrder if not already set (Int.max default)
        if newItem.sortOrder == Int.max {
            let maxSortOrder = copy.map(\.sortOrder).filter { $0 != Int.max }.max() ?? 0
            newItem.sortOrder = maxSortOrder + 1
        }
        copy.insert(newItem, at: 0)
        return copy
    }

    nonisolated private static func mergeMetadata(into item: inout LibraryItem, from incoming: LibraryItem) {
        setIfMissing(&item.thumbnailURL, incoming.thumbnailURL)
        setIfMissing(&item.uploaderName, incoming.uploaderName)
        setIfMissing(&item.uploaderURL, incoming.uploaderURL)
        setIfMissing(&item.sourceSiteName, incoming.sourceSiteName)
    }

    nonisolated private static func setIfMissing(_ current: inout String?, _ incoming: String?) {
        guard current?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
              let value = incoming?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return }
        current = value
    }

    func remove(_ item: LibraryItem) {
        items.removeAll { $0.id == item.id }
        save()
        Task { try? await LustreAgentClient().removeLibrary(sourcePageURL: item.url) }
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

    func updateFileSize(forID id: UUID, fileSize: Int64) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].fileSize != fileSize else { return }
        var copy = items
        copy[idx].fileSize = fileSize
        items = copy
        save()
    }

    func updateMetadata(_ updates: [LibraryItemMetadataUpdate]) {
        guard !updates.isEmpty else { return }
        var copy = items
        var didChange = false

        for update in updates {
            guard let idx = copy.firstIndex(where: { $0.id == update.id }) else { continue }
            var item = copy[idx]
            let before = item
            Self.setIfMissing(&item.uploaderName, update.uploaderName)
            Self.setIfMissing(&item.uploaderURL, update.uploaderURL)
            Self.setIfMissing(&item.sourceSiteName, update.sourceSiteName)
            Self.setIfMissing(&item.thumbnailURL, update.thumbnailURL)
            guard item != before else { continue }
            copy[idx] = item
            didChange = true
        }

        guard didChange else { return }
        items = copy
        save()
    }

    func updateOrganization(_ update: LibraryOrganizationUpdate) {
        guard let idx = items.firstIndex(where: { $0.id == update.id }) else { return }
        let tags = Array(Set(update.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        let collection = update.collectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard items[idx].tags != tags || items[idx].collectionName != (collection?.isEmpty == true ? nil : collection) else { return }
        items[idx].tags = tags.isEmpty ? nil : tags
        items[idx].collectionName = collection?.isEmpty == true ? nil : collection
        save()
        let item = items[idx]
        Task {
            try? await LustreAgentClient().organizeLibrary(
                sourcePageURL: item.url, tags: item.tags ?? [],
                collection: item.collectionName, favorite: false
            )
        }
    }
}
