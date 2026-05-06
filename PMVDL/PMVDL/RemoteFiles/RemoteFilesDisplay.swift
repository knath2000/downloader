import Foundation

enum RemoteFileSortMode: String, CaseIterable, Identifiable {
    case name
    case kind
    case modified
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .modified: return "Modified"
        case .size: return "Size"
        }
    }
}

enum RemoteFileDensity: String, CaseIterable, Identifiable {
    case comfortable
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }
}

struct RemoteFileSummary: Equatable {
    let folders: Int
    let files: Int
    let totalFileBytes: Int64

    var title: String {
        var parts: [String] = []
        parts.append("\(folders) \(folders == 1 ? "folder" : "folders")")
        parts.append("\(files) \(files == 1 ? "file" : "files")")

        if totalFileBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: totalFileBytes, countStyle: .file))
        }

        return parts.joined(separator: " · ")
    }
}

enum RemoteFilesDisplay {
    static func filteredAndSorted(
        items: [RemoteFileItem],
        query: String,
        sortMode: RemoteFileSortMode
    ) -> [RemoteFileItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filtered = items.filter { item in
            guard !trimmed.isEmpty else { return true }
            return item.name.lowercased().contains(trimmed)
                || item.path.lowercased().contains(trimmed)
                || (item.contentType?.lowercased().contains(trimmed) ?? false)
        }

        return sorted(items: filtered, by: sortMode)
    }

    static func sorted(items: [RemoteFileItem], by sortMode: RemoteFileSortMode) -> [RemoteFileItem] {
        items.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind == .folder
            }

            switch sortMode {
            case .name:
                return compareNames(lhs.name, rhs.name)

            case .kind:
                let lhsExt = fileExtension(name: lhs.name)
                let rhsExt = fileExtension(name: rhs.name)
                if lhsExt != rhsExt {
                    return lhsExt.localizedCaseInsensitiveCompare(rhsExt) == .orderedAscending
                }
                return compareNames(lhs.name, rhs.name)

            case .modified:
                let lhsDate = lhs.modifiedAt ?? .distantPast
                let rhsDate = rhs.modifiedAt ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return compareNames(lhs.name, rhs.name)

            case .size:
                let lhsSize = lhs.size ?? -1
                let rhsSize = rhs.size ?? -1
                if lhsSize != rhsSize {
                    return lhsSize > rhsSize
                }
                return compareNames(lhs.name, rhs.name)
            }
        }
    }

    static func summary(for items: [RemoteFileItem]) -> RemoteFileSummary {
        let folders = items.filter { $0.kind == .folder }.count
        let files = items.filter { $0.kind == .file }.count
        let bytes = items.compactMap { $0.kind == .file ? $0.size : nil }.reduce(0, +)
        return RemoteFileSummary(folders: folders, files: files, totalFileBytes: bytes)
    }

    static func fileExtension(name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    static func metadataText(for item: RemoteFileItem) -> String {
        var parts: [String] = []

        if item.kind == .folder {
            parts.append("Folder")
        } else if let size = item.size {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        } else {
            parts.append("File")
        }

        if let modifiedAt = item.modifiedAt {
            parts.append(modifiedAt.formatted(date: .abbreviated, time: .shortened))
        }

        return parts.joined(separator: " · ")
    }

    static func breadcrumbParts(for path: String) -> [String] {
        let normalized = RemotePath.normalizeDirectory(path)
        guard normalized != "/" else { return [] }
        return normalized.split(separator: "/").map(String.init)
    }

    static func path(upTo index: Int, in parts: [String]) -> String {
        guard !parts.isEmpty else { return "/" }
        return "/" + parts.prefix(index + 1).joined(separator: "/")
    }

    private static func compareNames(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }
}
