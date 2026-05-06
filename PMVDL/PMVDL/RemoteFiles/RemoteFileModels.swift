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
    case delete
    case upload
    case download
    case readText
    case saveText
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
