import Foundation

enum RemoteFileProviderID: String, CaseIterable, Identifiable, Codable {
    case seedbox
    case mega
    case gdrive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .seedbox: return "Seedbox"
        case .mega: return "Mega"
        case .gdrive: return "Google Drive"
        }
    }

    var icon: String {
        switch self {
        case .seedbox: return "server.rack"
        case .mega: return "cloud.fill"
        case .gdrive: return "g.circle.fill"
        }
    }

    var isImplementedInFileManager: Bool {
        switch self {
        case .seedbox:
            return true
        case .mega, .gdrive:
            return false
        }
    }
}

enum RemoteFileKind: String, Codable, Equatable {
    case file
    case folder
}

struct RemoteFileItem: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let path: String
    let kind: RemoteFileKind
    let size: Int64?
    let modifiedAt: Date?
    let contentType: String?

    var isFolder: Bool { kind == .folder }
    var isFile: Bool { kind == .file }

    init(
        name: String,
        path: String,
        kind: RemoteFileKind,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        contentType: String? = nil
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.contentType = contentType
        self.id = path
    }
}

struct RemoteDirectoryListing: Equatable {
    let provider: RemoteFileProviderID
    let path: String
    let items: [RemoteFileItem]
    let loadedAt: Date
}

enum RemoteFileOperation: Equatable {
    case list
    case createFolder
    case rename
    case move
    case copy
    case duplicate
    case delete
    case upload
    case download
    case readText
    case saveText
}

struct RemoteFileOperationProgress: Equatable {
    let completed: Int
    let total: Int
    let currentName: String?
}

struct RemoteFileDragPayload: Codable, Equatable {
    let provider: RemoteFileProviderID
    let sourceDirectory: String
    let itemIDs: [String]
}

struct RemoteFileSelectionState: Equatable {
    var selectedIDs: Set<String> = []
    var anchorID: String?
}

enum RemoteFileSelectionMode {
    case replace
    case toggle
    case range
}

enum RemoteFileSelectionReducer {
    static func select(
        itemID: String,
        orderedIDs: [String],
        state: RemoteFileSelectionState,
        mode: RemoteFileSelectionMode
    ) -> RemoteFileSelectionState {
        switch mode {
        case .replace:
            return RemoteFileSelectionState(selectedIDs: [itemID], anchorID: itemID)

        case .toggle:
            var selected = state.selectedIDs
            if selected.contains(itemID) {
                selected.remove(itemID)
            } else {
                selected.insert(itemID)
            }
            return RemoteFileSelectionState(selectedIDs: selected, anchorID: itemID)

        case .range:
            guard
                let anchorID = state.anchorID,
                let anchorIndex = orderedIDs.firstIndex(of: anchorID),
                let itemIndex = orderedIDs.firstIndex(of: itemID)
            else {
                return RemoteFileSelectionState(selectedIDs: [itemID], anchorID: itemID)
            }

            let bounds = anchorIndex <= itemIndex ? anchorIndex...itemIndex : itemIndex...anchorIndex
            return RemoteFileSelectionState(
                selectedIDs: Set(orderedIDs[bounds]),
                anchorID: anchorID
            )
        }
    }

    static func selectAll(orderedIDs: [String]) -> RemoteFileSelectionState {
        RemoteFileSelectionState(selectedIDs: Set(orderedIDs), anchorID: orderedIDs.first)
    }
}

struct RemoteFileTransferPlan: Equatable {
    let item: RemoteFileItem
    let targetDirectory: String
    let newName: String
}

enum RemoteFileOperationPlanner {
    static func movePlans(
        items: [RemoteFileItem],
        targetDirectory: String,
        existingTargetNames: Set<String>
    ) throws -> [RemoteFileTransferPlan] {
        let target = RemotePath.normalizeDirectory(targetDirectory)
        var occupied = Set(existingTargetNames.map { $0.lowercased() })
        var plans: [RemoteFileTransferPlan] = []

        for item in items {
            try validateMove(item: item, targetDirectory: target)
            let sourceParent = RemotePath.parent(of: item.path)
            guard sourceParent != target else { continue }

            let name = RemotePath.sanitizeNameComponent(item.name)
            guard !occupied.contains(name.lowercased()) else {
                throw RemoteFileClientError.invalidPath("\"\(name)\" already exists in \(target).")
            }

            plans.append(RemoteFileTransferPlan(item: item, targetDirectory: target, newName: name))
            occupied.insert(name.lowercased())
        }

        return plans
    }

    static func copyPlans(
        items: [RemoteFileItem],
        targetDirectory: String,
        existingTargetNames: Set<String>
    ) throws -> [RemoteFileTransferPlan] {
        let target = RemotePath.normalizeDirectory(targetDirectory)
        var occupied = Set(existingTargetNames)
        var lowercasedOccupied = Set(existingTargetNames.map { $0.lowercased() })
        var plans: [RemoteFileTransferPlan] = []

        for item in items {
            if item.path == "/" {
                throw RemoteFileClientError.invalidPath("The remote root cannot be copied.")
            }

            let sourceParent = RemotePath.parent(of: item.path)
            let name = sourceParent == target || lowercasedOccupied.contains(item.name.lowercased())
                ? RemotePath.duplicateName(for: item.name, existingNames: occupied)
                : RemotePath.sanitizeNameComponent(item.name)

            plans.append(RemoteFileTransferPlan(item: item, targetDirectory: target, newName: name))
            occupied.insert(name)
            lowercasedOccupied.insert(name.lowercased())
        }

        return plans
    }

    static func validateMove(item: RemoteFileItem, targetDirectory: String) throws {
        let target = RemotePath.normalizeDirectory(targetDirectory)
        if item.path == "/" {
            throw RemoteFileClientError.invalidPath("The remote root cannot be moved.")
        }

        if item.kind == .folder, item.path == target || RemotePath.isDescendant(target, of: item.path) {
            throw RemoteFileClientError.invalidPath("A folder cannot be moved into itself.")
        }
    }
}

enum RemoteFileClientError: LocalizedError, Equatable {
    case notConfigured(String)
    case notAvailable(String)
    case invalidPath(String)
    case unsupportedProvider(String)
    case unsupportedOperation(String)
    case commandFailed(String)
    case httpFailed(Int)
    case responseParsingFailed(String)
    case fileTooLargeForTextEdit(maxBytes: Int64)
    case notTextEditable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let message):
            return message
        case .notAvailable(let message):
            return message
        case .invalidPath(let message):
            return message
        case .unsupportedProvider(let message):
            return message
        case .unsupportedOperation(let message):
            return message
        case .commandFailed(let message):
            return message
        case .httpFailed(let status):
            return "Remote server returned HTTP \(status)."
        case .responseParsingFailed(let message):
            return message
        case .fileTooLargeForTextEdit(let maxBytes):
            return "File is too large to edit as text. Limit: \(maxBytes) bytes."
        case .notTextEditable(let message):
            return message
        }
    }
}
