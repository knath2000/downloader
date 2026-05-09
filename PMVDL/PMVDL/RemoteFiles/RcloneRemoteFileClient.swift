import Foundation

struct RcloneListEntry: Decodable {
    let Path: String?
    let Name: String?
    let Size: Int64?
    let ModTime: String?
    let IsDir: Bool?
    let MimeType: String?
}

enum RcloneRemoteFileParser {
    static func parseListJSON(
        _ data: Data,
        directory: String,
        provider: RemoteFileProviderID
    ) throws -> RemoteDirectoryListing {
        let decoded = try JSONDecoder().decode([RcloneListEntry].self, from: data)

        let items = decoded.compactMap { entry -> RemoteFileItem? in
            let name = entry.Name ?? entry.Path?.split(separator: "/").last.map(String.init)
            guard let name, !name.isEmpty else { return nil }

            let path = RemotePath.joining(directory: directory, name: name)
            let modifiedAt = parseRcloneDate(entry.ModTime)

            return RemoteFileItem(
                name: name,
                path: path,
                kind: entry.IsDir == true ? .folder : .file,
                size: entry.Size,
                modifiedAt: modifiedAt,
                contentType: entry.MimeType
            )
        }
        .sorted(by: sortRemoteItems)

        return RemoteDirectoryListing(
            provider: provider,
            path: RemotePath.normalizeDirectory(directory),
            items: items,
            loadedAt: Date()
        )
    }

    static func parseRcloneDate(_ value: String?) -> Date? {
        guard let value else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }

    static func sortRemoteItems(_ lhs: RemoteFileItem, _ rhs: RemoteFileItem) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .folder
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

final class RcloneRemoteFileClient: RemoteFileClient {
    let provider: RemoteFileProviderID

    private let remoteName: String
    private let rootPath: String
    private let rclone: URL

    init(
        provider: RemoteFileProviderID,
        remoteName: String,
        rootPath: String,
        rclone: URL
    ) {
        self.provider = provider
        self.remoteName = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rootPath = RemotePath.normalizeDirectory(rootPath)
        self.rclone = rclone
    }

    func list(path: String) async throws -> RemoteDirectoryListing {
        let directory = absoluteRemotePath(forUIPath: path)
        let destination = RemotePath.rclonePath(remoteName: remoteName, directory: directory)

        let result = try await SubprocessRunner.run(
            executable: rclone,
            arguments: ["lsjson", destination, "--max-depth", "1"],
            timeout: 30
        )

        guard result.exitStatus == 0 else {
            throw RemoteFileClientError.commandFailed(cleanRcloneError(result.stderr))
        }

        guard let data = result.stdout.data(using: .utf8) else {
            throw RemoteFileClientError.responseParsingFailed("rclone did not return UTF-8 JSON.")
        }

        return try RcloneRemoteFileParser.parseListJSON(
            data,
            directory: path,
            provider: provider
        )
    }

    func createFolder(named name: String, in directory: String) async throws {
        let path = absoluteRemotePath(forUIPath: RemotePath.joining(directory: directory, name: name))
        let destination = RemotePath.rclonePath(remoteName: remoteName, directory: path)

        let result = try await SubprocessRunner.run(
            executable: rclone,
            arguments: ["mkdir", destination],
            timeout: 30
        )

        guard result.exitStatus == 0 else {
            throw RemoteFileClientError.commandFailed(cleanRcloneError(result.stderr))
        }
    }

    func rename(itemAt path: String, to newName: String) async throws {
        let sourceAbsolute = absoluteRemotePath(forUIPath: path)
        let parent = RemotePath.parent(of: path)
        let destinationUI = RemotePath.joining(directory: parent, name: newName)
        let destinationAbsolute = absoluteRemotePath(forUIPath: destinationUI)

        let source = RemotePath.rcloneFile(remoteName: remoteName, path: sourceAbsolute)
        let destination = RemotePath.rcloneFile(remoteName: remoteName, path: destinationAbsolute)

        let result = try await SubprocessRunner.run(
            executable: rclone,
            arguments: ["moveto", source, destination],
            timeout: 120
        )

        guard result.exitStatus == 0 else {
            throw RemoteFileClientError.commandFailed(cleanRcloneError(result.stderr))
        }
    }

    func move(itemAt path: String, kind: RemoteFileKind, toDirectory directory: String, newName: String?) async throws {
        let sourceAbsolute = absoluteRemotePath(forUIPath: path)
        let targetName = newName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? newName!
            : RemotePath.basename(path)
        let destinationUI = RemotePath.joining(directory: directory, name: targetName)
        let destinationAbsolute = absoluteRemotePath(forUIPath: destinationUI)

        let source = RemotePath.rcloneFile(remoteName: remoteName, path: sourceAbsolute)
        let destination = RemotePath.rcloneFile(remoteName: remoteName, path: destinationAbsolute)

        let result = try await SubprocessRunner.run(
            executable: rclone,
            arguments: ["moveto", source, destination],
            timeout: 7200
        )

        guard result.exitStatus == 0 else {
            throw RemoteFileClientError.commandFailed(cleanRcloneError(result.stderr))
        }
    }

    func copy(itemAt path: String, kind: RemoteFileKind, toDirectory directory: String, newName: String?) async throws {
        let sourceAbsolute = absoluteRemotePath(forUIPath: path)
        let targetName = newName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? newName!
            : RemotePath.basename(path)
        let destinationUI = RemotePath.joining(directory: directory, name: targetName)
        let destinationAbsolute = absoluteRemotePath(forUIPath: destinationUI)

        let source: String
        let destination: String
        let arguments: [String]

        if kind == .folder {
            source = RemotePath.rcloneFile(remoteName: remoteName, path: sourceAbsolute)
            destination = RemotePath.rcloneFile(remoteName: remoteName, path: destinationAbsolute)
            arguments = ["copy", source, destination, "--create-empty-src-dirs"]
        } else {
            source = RemotePath.rcloneFile(remoteName: remoteName, path: sourceAbsolute)
            destination = RemotePath.rcloneFile(remoteName: remoteName, path: destinationAbsolute)
            arguments = ["copyto", source, destination]
        }

        let result = try await SubprocessRunner.run(
            executable: rclone,
            arguments: arguments,
            timeout: 7200
        )

        guard result.exitStatus == 0 else {
            throw RemoteFileClientError.commandFailed(cleanRcloneError(result.stderr))
        }
    }

    func delete(itemAt path: String, kind: RemoteFileKind) async throws {
        let absolute = absoluteRemotePath(forUIPath: path)
        let destination: String
        let command: String

        if kind == .folder {
            destination = RemotePath.rclonePath(remoteName: remoteName, directory: absolute)
            command = "rmdir"
        } else {
            destination = RemotePath.rcloneFile(remoteName: remoteName, path: absolute)
            command = "deletefile"
        }

        let result = try await SubprocessRunner.run(
            executable: rclone,
            arguments: [command, destination],
            timeout: 120
        )

        guard result.exitStatus == 0 else {
            throw RemoteFileClientError.commandFailed(cleanRcloneError(result.stderr))
        }
    }

    func downloadFile(at path: String, to localURL: URL) async throws {
        let absolute = absoluteRemotePath(forUIPath: path)
        let source = RemotePath.rcloneFile(remoteName: remoteName, path: absolute)

        let result = try await SubprocessRunner.run(
            executable: rclone,
            arguments: ["copyto", source, localURL.path],
            timeout: 7200
        )

        guard result.exitStatus == 0 else {
            throw RemoteFileClientError.commandFailed(cleanRcloneError(result.stderr))
        }
    }

    func uploadFile(from localURL: URL, to directory: String, remoteName remoteFileName: String?) async throws {
        let name = remoteFileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? remoteFileName!
            : localURL.lastPathComponent

        let destinationUI = RemotePath.joining(directory: directory, name: name)
        let absolute = absoluteRemotePath(forUIPath: destinationUI)
        let destination = RemotePath.rcloneFile(remoteName: remoteName, path: absolute)

        let result = try await SubprocessRunner.run(
            executable: rclone,
            arguments: ["copyto", localURL.path, destination, "--progress", "--transfers=1", "-v"],
            timeout: 7200
        )

        guard result.exitStatus == 0 else {
            throw RemoteFileClientError.commandFailed(cleanRcloneError(result.stderr))
        }
    }

    func readTextFile(at path: String, maxBytes: Int64) async throws -> String {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddl_remote_edit_\(UUID().uuidString)")
            .appendingPathExtension((path as NSString).pathExtension)

        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await downloadFile(at: path, to: tempURL)

        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        if let size = attrs[.size] as? Int64, size > maxBytes {
            throw RemoteFileClientError.fileTooLargeForTextEdit(maxBytes: maxBytes)
        }

        do {
            return try String(contentsOf: tempURL, encoding: .utf8)
        } catch {
            throw RemoteFileClientError.notTextEditable("File is not valid UTF-8 text.")
        }
    }

    func saveTextFile(_ text: String, to path: String) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddl_remote_save_\(UUID().uuidString)")
            .appendingPathExtension((path as NSString).pathExtension)

        defer { try? FileManager.default.removeItem(at: tempURL) }

        try text.write(to: tempURL, atomically: true, encoding: .utf8)

        let parent = RemotePath.parent(of: path)
        let name = RemotePath.basename(path)
        try await uploadFile(from: tempURL, to: parent, remoteName: name)
    }

    private func absoluteRemotePath(forUIPath uiPath: String) -> String {
        let root = RemotePath.normalizeDirectory(rootPath)
        let ui = RemotePath.normalizeDirectory(uiPath)

        if root == "/" {
            return ui
        }

        if ui == "/" {
            return root
        }

        return RemotePath.normalizeDirectory(root + "/" + String(ui.dropFirst()))
    }

    private func cleanRcloneError(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "rclone command failed." : trimmed
    }
}
