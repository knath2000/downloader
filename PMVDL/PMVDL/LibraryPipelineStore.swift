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

    private let userDefaultsKey = "libraryPipelineSnapshot"
    private var cachedLibraryItems: [LibraryItem] = []
    private var cachedCompletedUploads: [CompletedUploadItem] = []
    private var cachedQueueItems: [DownloadQueueItem] = []

    private init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(LibraryPipelineSnapshot.self, from: data) else {
            snapshot = LibraryPipelineSnapshot(entries: [:])
            return
        }
        snapshot = decoded
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

        var records: [String: LibraryPipelineRecord] = snapshot.entries

        func ensure(_ rawURL: String) -> String {
            let key = Self.normalizedURL(rawURL)
            if records[key] == nil {
                records[key] = .empty
            }
            return key
        }

        for item in cachedLibraryItems {
            let key = ensure(item.url)
            for destination in LibraryPipelineDestination.allCases {
                if let path = item.remotePaths[destination.rawValue], !path.isEmpty {
                    records[key]?.stages[destination.rawValue] = .succeeded(path: path, date: item.extractedAt)
                } else if records[key]?.stages[destination.rawValue] == nil {
                    records[key]?.stages[destination.rawValue] = .notStarted
                }
            }
        }

        for item in cachedCompletedUploads {
            let key = ensure(item.url)
            let destination = Self.destination(for: item.destination)
            records[key]?.stages[destination.rawValue] = .succeeded(path: item.remotePath, date: item.completedAt)
        }

        for item in cachedQueueItems {
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

        snapshot = LibraryPipelineSnapshot(entries: records)
        save()
    }

    func hydrateFromStores(
        libraryItems: [LibraryItem],
        completedUploads: [CompletedUploadItem],
        queueItems: [DownloadQueueItem]
    ) {
        rebuild(
            libraryItems: libraryItems,
            completedUploads: completedUploads,
            queueItems: queueItems
        )
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

    static func normalizedURL(_ raw: String) -> String {
        DownloadedFeedIndex.normalizedURL(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func destination(for raw: String) -> LibraryPipelineDestination {
        let lower = raw.lowercased()
        if lower.contains("mega") { return .mega }
        if lower.contains("drive") || lower.contains("gdrive") { return .gdrive }
        if lower.contains("seedbox") { return .seedbox }
        return .local
    }
}
