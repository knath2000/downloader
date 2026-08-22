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
                case CloudTarget.gdrive.rawValue:
                    try await GDriveManager.verifyRemoteFile(destination: path, expectedSize: nil, allowUnknownSize: true)
                case CloudTarget.mega.rawValue:
                    let remoteURL = URL(fileURLWithPath: path)
                    let files = try await MegaManager.listRemoteFiles(remotePath: remoteURL.deletingLastPathComponent().path)
                    guard files.contains(remoteURL.lastPathComponent) else { throw VerificationError.missing }
                case CloudTarget.seedbox.rawValue:
                    try await verifySeedbox(path: path)
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

    private static func verifySeedbox(path: String) async throws {
        let defaults = UserDefaults.standard
        let filename = URL(fileURLWithPath: path).lastPathComponent
        if defaults.string(forKey: "seedboxTransferMode") == "webdav" {
            guard let baseURL = defaults.string(forKey: "seedboxWebdavURL").flatMap(URLTrustPolicy.validated),
                  let user = defaults.string(forKey: "seedboxWebdavUser"),
                  let password = SecureStore.string(forKey: "seedboxWebdavPassword"), !password.isEmpty else {
                throw VerificationError.notConfigured
            }
            try await SeedboxManager(mode: .webdav(
                baseURL: baseURL,
                user: user,
                password: password,
                remotePath: defaults.string(forKey: "seedboxRemotePath") ?? "/",
                allowSelfSigned: defaults.bool(forKey: "seedboxWebdavAllowSelfSigned")
            )).verifyRemoteFile(filename: filename)
        } else {
            try await SeedboxManager(mode: .rclone(
                remoteName: defaults.string(forKey: "seedboxRemoteName") ?? "seedbox",
                remotePath: defaults.string(forKey: "seedboxRemotePath") ?? "/"
            )).verifyRemoteFile(filename: filename)
        }
    }

    private enum VerificationError: LocalizedError {
        case missing
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .missing: return "file was not found"
            case .notConfigured: return "destination is not configured"
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
            return decoded.sorted { $0.extractedAt > $1.extractedAt }
        }.value
        let currentIDs = Set(items.map(\.id))
        items = restored.filter { !currentIDs.contains($0.id) } + items
        isRestoring = false
        purgeExpired()
    }

    func save() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
        LibraryPipelineStore.shared.rebuild(libraryItems: items)
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
            mergeMetadata(into: &copy[idx], from: incoming)
            return copy
        }

        copy.insert(incoming, at: 0)
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
