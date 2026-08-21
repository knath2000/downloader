import Foundation

struct LibraryPipelineSnapshot: Codable, Equatable {
    var entries: [String: LibraryPipelineRecord]
}

struct LibraryPipelineRecord: Codable, Equatable {
    var stages: [String: LibraryPipelineStage]

    static let empty = LibraryPipelineRecord(stages: [:])
}

enum LibraryPipelineStage: Codable, Equatable {
    case notStarted
    case running
    case succeeded(path: String, date: Date)
    case failed(message: String, date: Date)
}

enum LibraryPipelineDestination: String, CaseIterable, Codable, Identifiable {
    case local
    case mega
    case gdrive
    case seedbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "Local"
        case .mega: return "Mega"
        case .gdrive: return "Drive"
        case .seedbox: return "Seedbox"
        }
    }

    var tintKey: String {
        switch self {
        case .local: return "local"
        case .mega: return "mega"
        case .gdrive: return "gdrive"
        case .seedbox: return "seedbox"
        }
    }
}

@MainActor
final class LibraryPipelineStore: ObservableObject {
    static let shared = LibraryPipelineStore()

    @Published private(set) var snapshot = LibraryPipelineSnapshot(entries: [:])
    @Published private(set) var isRestoring = true

    private let userDefaultsKey = "libraryPipelineSnapshot"
    private var cachedLibraryItems: [LibraryItem] = []
    private var cachedCompletedUploads: [CompletedUploadItem] = []
    private var cachedQueueItems: [DownloadQueueItem] = []

    private init() {}

    func restorePersistedSnapshot() async {
        guard isRestoring else { return }
        let data = UserDefaults.standard.data(forKey: userDefaultsKey)
        let restored = await Task.detached(priority: .userInitiated) {
            data.flatMap {
                try? JSONDecoder().decode(LibraryPipelineSnapshot.self, from: $0)
            } ?? LibraryPipelineSnapshot(entries: [:])
        }.value
        snapshot = restored
        isRestoring = false
    }

    func rebuild(
        libraryItems: [LibraryItem]? = nil,
        completedUploads: [CompletedUploadItem]? = nil,
        queueItems: [DownloadQueueItem]? = nil
    ) {
        if let libraryItems {
            cachedLibraryItems = libraryItems
        }
        if let completedUploads {
            cachedCompletedUploads = completedUploads
        }
        if let queueItems {
            cachedQueueItems = queueItems
        }

        snapshot = Self.rebuiltSnapshot(
            from: snapshot,
            libraryItems: cachedLibraryItems,
            completedUploads: cachedCompletedUploads,
            queueItems: cachedQueueItems
        )
        save()
    }

    func hydrateFromStores(
        libraryItems: [LibraryItem],
        completedUploads: [CompletedUploadItem],
        queueItems: [DownloadQueueItem]
    ) async {
        cachedLibraryItems = libraryItems
        cachedCompletedUploads = completedUploads
        cachedQueueItems = queueItems
        let currentSnapshot = snapshot
        let rebuilt = await Task.detached(priority: .userInitiated) {
            Self.rebuiltSnapshot(
                from: currentSnapshot,
                libraryItems: libraryItems,
                completedUploads: completedUploads,
                queueItems: queueItems
            )
        }.value
        snapshot = rebuilt
        let userDefaultsKey = userDefaultsKey
        Task.detached(priority: .utility) {
            guard let encoded = try? JSONEncoder().encode(rebuilt) else { return }
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    nonisolated private static func rebuiltSnapshot(
        from snapshot: LibraryPipelineSnapshot,
        libraryItems: [LibraryItem],
        completedUploads: [CompletedUploadItem],
        queueItems: [DownloadQueueItem]
    ) -> LibraryPipelineSnapshot {
        var records = snapshot.entries

        func ensure(_ rawURL: String) -> String {
            let key = Self.normalizedURL(rawURL)
            if records[key] == nil {
                records[key] = .empty
            }
            return key
        }

        for item in libraryItems {
            let key = ensure(item.url)
            for destination in LibraryPipelineDestination.allCases {
                if let path = item.remotePaths[destination.rawValue], !path.isEmpty {
                    records[key]?.stages[destination.rawValue] = .succeeded(path: path, date: item.extractedAt)
                } else if records[key]?.stages[destination.rawValue] == nil {
                    records[key]?.stages[destination.rawValue] = .notStarted
                }
            }
        }

        for item in completedUploads {
            let key = ensure(item.url)
            let destination = Self.destination(for: item.destination)
            records[key]?.stages[destination.rawValue] = .succeeded(path: item.remotePath, date: item.completedAt)
        }

        for item in queueItems {
            let key = ensure(item.url)
            let destination = Self.destination(for: item.targetCloud.rawValue)
            switch item.status {
            case .pending, .waiting, .downloading, .verifying, .uploading:
                records[key]?.stages[destination.rawValue] = .running
            case .completed:
                let path = item.finalPath ?? item.statusMessage ?? destination.title
                records[key]?.stages[destination.rawValue] = .succeeded(path: path, date: item.createdAt)
            case .failed(let reason):
                let message = reason.isEmpty ? (item.statusMessage ?? "Failed") : reason
                records[key]?.stages[destination.rawValue] = .failed(message: message, date: item.createdAt)
            case .paused:
                if records[key]?.stages[destination.rawValue] == nil {
                    records[key]?.stages[destination.rawValue] = .notStarted
                }
            case .processing:
                continue
            }
        }

        return LibraryPipelineSnapshot(entries: records)
    }

    func record(for rawURL: String) -> LibraryPipelineRecord {
        snapshot.entries[Self.normalizedURL(rawURL)] ?? .empty
    }

    func stage(for rawURL: String, destination: LibraryPipelineDestination) -> LibraryPipelineStage {
        record(for: rawURL).stages[destination.rawValue] ?? .notStarted
    }

    func searchText(for rawURL: String) -> String {
        LibraryPipelineDestination.allCases.map { destination in
            let stage = stage(for: rawURL, destination: destination)
            switch stage {
            case .notStarted:
                return destination.title
            case .running:
                return "\(destination.title) running"
            case .succeeded(let path, _):
                return "\(destination.title) succeeded \(path)"
            case .failed(let message, _):
                return "\(destination.title) failed \(message)"
            }
        }
        .joined(separator: " ")
        .lowercased()
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
    }

    nonisolated static func normalizedURL(_ raw: String) -> String {
        DownloadedFeedIndex.normalizedURL(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func destination(for raw: String) -> LibraryPipelineDestination {
        let lower = raw.lowercased()
        if lower.contains("mega") { return .mega }
        if lower.contains("drive") || lower.contains("gdrive") { return .gdrive }
        if lower.contains("seedbox") { return .seedbox }
        return .local
    }
}
