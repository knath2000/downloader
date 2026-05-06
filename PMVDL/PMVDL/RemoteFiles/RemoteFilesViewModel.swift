import AppKit
import Foundation

@MainActor
final class RemoteFilesViewModel: ObservableObject {
    @Published private(set) var provider: RemoteFileProviderID = .seedbox
    @Published private(set) var currentPath = "/"
    @Published private(set) var items: [RemoteFileItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var activeOperation: RemoteFileOperation?
    @Published var errorMessage: String?
    @Published var searchText = ""

    private var client: RemoteFileClient?

    var filteredItems: [RemoteFileItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.name.lowercased().contains(query) || $0.path.lowercased().contains(query)
        }
    }

    func configure(client: RemoteFileClient) {
        self.client = client
        provider = client.provider
        currentPath = "/"
        items = []
        errorMessage = nil
    }

    func load(path: String? = nil) async {
        guard let client else {
            errorMessage = "Remote file client is not configured."
            return
        }

        let targetPath = path ?? currentPath

        isLoading = true
        activeOperation = .list
        errorMessage = nil

        do {
            let listing = try await client.list(path: targetPath)
            currentPath = listing.path
            items = listing.items
        } catch {
            errorMessage = error.localizedDescription
        }

        activeOperation = nil
        isLoading = false
    }

    func goUp() async {
        await load(path: RemotePath.parent(of: currentPath))
    }

    func open(_ item: RemoteFileItem) async {
        if item.kind == .folder {
            await load(path: item.path)
        } else {
            await downloadAndOpen(item)
        }
    }

    func createFolder(named name: String) async {
        guard let client else { return }
        let path = currentPath
        await run(.createFolder) {
            try await client.createFolder(named: name, in: path)
        }
        if errorMessage == nil {
            await load(path: path)
        }
    }

    func rename(_ item: RemoteFileItem, to newName: String) async {
        guard let client else { return }
        let path = currentPath
        await run(.rename) {
            try await client.rename(itemAt: item.path, to: newName)
        }
        if errorMessage == nil {
            await load(path: path)
        }
    }

    func delete(_ item: RemoteFileItem) async {
        guard let client else { return }
        let path = currentPath
        await run(.delete) {
            try await client.delete(itemAt: item.path, kind: item.kind)
        }
        if errorMessage == nil {
            await load(path: path)
        }
    }

    func upload(localURL: URL, remoteName: String? = nil) async {
        guard let client else { return }
        let path = currentPath
        await run(.upload) {
            try await client.uploadFile(from: localURL, to: path, remoteName: remoteName)
        }
        if errorMessage == nil {
            await load(path: path)
        }
    }

    func readText(_ item: RemoteFileItem) async throws -> String {
        guard let client else {
            throw RemoteFileClientError.notConfigured("Remote file client is not configured.")
        }

        guard RemoteFileTextPolicy.isLikelyTextEditable(item) else {
            throw RemoteFileClientError.notTextEditable("This file does not look like an editable text file.")
        }

        return try await client.readTextFile(
            at: item.path,
            maxBytes: RemoteFileTextPolicy.maxEditableBytes
        )
    }

    func saveText(_ text: String, to item: RemoteFileItem) async throws {
        guard let client else {
            throw RemoteFileClientError.notConfigured("Remote file client is not configured.")
        }

        try await client.saveTextFile(text, to: item.path)
        await load(path: currentPath)
    }

    private func downloadAndOpen(_ item: RemoteFileItem) async {
        guard let client else { return }

        await run(.download) {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("VidDLRemoteFiles", isDirectory: true)

            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let localURL = folder.appendingPathComponent(item.name)
            try await client.downloadFile(at: item.path, to: localURL)
            NSWorkspace.shared.open(localURL)
        }
    }

    private func run(_ operation: RemoteFileOperation, action: @escaping () async throws -> Void) async {
        activeOperation = operation
        errorMessage = nil

        do {
            try await action()
        } catch {
            errorMessage = error.localizedDescription
        }

        activeOperation = nil
    }
}
