import AppKit
import Foundation

@MainActor
final class RemoteFilesViewModel: ObservableObject {
    @Published private(set) var provider: RemoteFileProviderID = .seedbox
    @Published private(set) var currentPath = "/"
    @Published private(set) var items: [RemoteFileItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var activeOperation: RemoteFileOperation?
    @Published private(set) var operationProgress: RemoteFileOperationProgress?
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
            try await client.move(
                itemAt: item.path,
                kind: item.kind,
                toDirectory: RemotePath.parent(of: item.path),
                newName: newName
            )
        }
        if errorMessage == nil {
            await load(path: path)
        }
    }

    func delete(_ item: RemoteFileItem) async {
        await delete([item])
    }

    func delete(_ items: [RemoteFileItem]) async {
        guard let client else { return }
        guard !items.isEmpty else { return }
        let path = currentPath

        begin(.delete)
        do {
            for (index, item) in items.enumerated() {
                operationProgress = RemoteFileOperationProgress(
                    completed: index,
                    total: items.count,
                    currentName: item.name
                )
                try await client.delete(itemAt: item.path, kind: item.kind)
            }
            operationProgress = RemoteFileOperationProgress(
                completed: items.count,
                total: items.count,
                currentName: nil
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        finish()
        if errorMessage == nil {
            await load(path: path)
        }
    }

    func upload(localURL: URL, remoteName: String? = nil) async {
        await upload(localURLs: [localURL], toDirectory: currentPath, remoteName: remoteName)
    }

    func upload(localURLs: [URL], toDirectory directory: String? = nil, remoteName: String? = nil) async {
        guard let client else { return }
        guard !localURLs.isEmpty else { return }

        let targetDirectory = RemotePath.normalizeDirectory(directory ?? currentPath)
        let refreshPath = currentPath

        begin(.upload)
        do {
            for (index, url) in localURLs.enumerated() {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    throw RemoteFileClientError.unsupportedOperation("Folder upload from Files is not supported yet.")
                }

                operationProgress = RemoteFileOperationProgress(
                    completed: index,
                    total: localURLs.count,
                    currentName: url.lastPathComponent
                )
                try await client.uploadFile(from: url, to: targetDirectory, remoteName: remoteName)
            }
            operationProgress = RemoteFileOperationProgress(
                completed: localURLs.count,
                total: localURLs.count,
                currentName: nil
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        finish()
        if errorMessage == nil {
            await load(path: refreshPath)
        }
    }

    func move(_ items: [RemoteFileItem], toDirectory directory: String) async {
        guard let client else { return }
        guard !items.isEmpty else { return }

        let refreshPath = currentPath

        begin(.move)
        do {
            let targetNames = try await existingNames(in: directory)
            let plans = try RemoteFileOperationPlanner.movePlans(
                items: items,
                targetDirectory: directory,
                existingTargetNames: targetNames
            )

            guard !plans.isEmpty else {
                throw RemoteFileClientError.invalidPath("Selected items are already in \(RemotePath.normalizeDirectory(directory)).")
            }

            for (index, plan) in plans.enumerated() {
                operationProgress = RemoteFileOperationProgress(
                    completed: index,
                    total: plans.count,
                    currentName: plan.item.name
                )
                try await client.move(
                    itemAt: plan.item.path,
                    kind: plan.item.kind,
                    toDirectory: plan.targetDirectory,
                    newName: plan.newName
                )
            }
            operationProgress = RemoteFileOperationProgress(
                completed: plans.count,
                total: plans.count,
                currentName: nil
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        finish()
        if errorMessage == nil {
            await load(path: refreshPath)
        }
    }

    func copy(_ items: [RemoteFileItem], toDirectory directory: String, operation: RemoteFileOperation = .copy) async {
        guard let client else { return }
        guard !items.isEmpty else { return }

        let refreshPath = currentPath

        begin(operation)
        do {
            let targetNames = try await existingNames(in: directory)
            let plans = try RemoteFileOperationPlanner.copyPlans(
                items: items,
                targetDirectory: directory,
                existingTargetNames: targetNames
            )

            for (index, plan) in plans.enumerated() {
                operationProgress = RemoteFileOperationProgress(
                    completed: index,
                    total: plans.count,
                    currentName: plan.item.name
                )
                try await client.copy(
                    itemAt: plan.item.path,
                    kind: plan.item.kind,
                    toDirectory: plan.targetDirectory,
                    newName: plan.newName
                )
            }
            operationProgress = RemoteFileOperationProgress(
                completed: plans.count,
                total: plans.count,
                currentName: nil
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        finish()
        if errorMessage == nil {
            await load(path: refreshPath)
        }
    }

    func duplicate(_ items: [RemoteFileItem]) async {
        await copy(items, toDirectory: currentPath, operation: .duplicate)
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
        await downloadAndOpen([item])
    }

    func downloadAndOpen(_ items: [RemoteFileItem]) async {
        guard let client else { return }
        let files = items.filter { $0.kind == .file }
        guard !files.isEmpty else {
            errorMessage = "Select one or more files to download."
            return
        }

        begin(.download)
        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("VidDLRemoteFiles", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)

            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            for (index, item) in files.enumerated() {
                operationProgress = RemoteFileOperationProgress(
                    completed: index,
                    total: files.count,
                    currentName: item.name
                )
                let localURL = folder.appendingPathComponent(item.name)
                try await client.downloadFile(at: item.path, to: localURL)
                NSWorkspace.shared.open(localURL)
            }
            operationProgress = RemoteFileOperationProgress(
                completed: files.count,
                total: files.count,
                currentName: nil
            )
        } catch {
            errorMessage = error.localizedDescription
        }

        finish()
    }

    private func existingNames(in directory: String) async throws -> Set<String> {
        guard let client else {
            throw RemoteFileClientError.notConfigured("Remote file client is not configured.")
        }

        let target = RemotePath.normalizeDirectory(directory)
        if target == currentPath {
            return Set(items.map(\.name))
        }

        return Set(try await client.list(path: target).items.map(\.name))
    }

    private func begin(_ operation: RemoteFileOperation) {
        activeOperation = operation
        operationProgress = nil
        errorMessage = nil
    }

    private func finish() {
        activeOperation = nil
        operationProgress = nil
    }

    private func run(_ operation: RemoteFileOperation, action: @escaping () async throws -> Void) async {
        begin(operation)

        do {
            try await action()
        } catch {
            errorMessage = error.localizedDescription
        }

        finish()
    }
}
