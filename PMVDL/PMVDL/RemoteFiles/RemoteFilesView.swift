import AppKit
import SwiftUI

struct RemoteFilesView: View {
    let seedboxTransferMode: String
    let seedboxRemoteName: String
    let seedboxRemotePath: String
    let seedboxWebdavURL: String
    let seedboxWebdavUser: String
    let seedboxWebdavPassword: String

    @StateObject private var model = RemoteFilesViewModel()

    @State private var selectedProvider: RemoteFileProviderID = .seedbox
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""
    @State private var pendingRenameItem: RemoteFileItem?
    @State private var renameText = ""
    @State private var pendingDeleteItem: RemoteFileItem?
    @State private var editingItem: RemoteFileItem?
    @State private var sortMode: RemoteFileSortMode = .name
    @State private var density: RemoteFileDensity = .comfortable
    @FocusState private var searchFocused: Bool

    private var isBusy: Bool {
        model.isLoading || model.activeOperation != nil
    }

    private var visibleItems: [RemoteFileItem] {
        RemoteFilesDisplay.filteredAndSorted(
            items: model.items,
            query: model.searchText,
            sortMode: sortMode
        )
    }

    private var summary: RemoteFileSummary {
        RemoteFilesDisplay.summary(for: model.items)
    }

    private var visibleSummaryText: String {
        if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summary.title
        }

        return "\(visibleItems.count) of \(model.items.count) shown"
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            toolbar

            if let error = model.errorMessage {
                errorBanner(error)
            }

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            shortcutHost
        }
        .onExitCommand {
            handleExitCommand()
        }
        .task(id: seedboxConfigID) {
            await configureAndLoad()
        }
        .confirmationDialog(
            "Delete remote item?",
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { if !$0 { pendingDeleteItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let item = pendingDeleteItem {
                    Task { await model.delete(item) }
                }
                pendingDeleteItem = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteItem = nil
            }
        } message: {
            Text(pendingDeleteItem.map { "Delete \"\($0.name)\" from \(model.currentPath)? This cannot be undone." } ?? "")
        }
        .sheet(isPresented: $showingCreateFolder) {
            createFolderSheet
        }
        .sheet(item: $pendingRenameItem) { item in
            renameSheet(item)
        }
        .sheet(item: $editingItem) { item in
            RemoteFileEditorView(
                item: item,
                loadText: { try await model.readText(item) },
                saveText: { text in try await model.saveText(text, to: item) }
            )
        }
    }

    private var seedboxConfigID: String {
        [
            seedboxTransferMode,
            seedboxRemoteName,
            seedboxRemotePath,
            seedboxWebdavURL,
            seedboxWebdavUser
        ].joined(separator: "|")
    }

    private var shortcutHost: some View {
        Group {
            Button("") {
                searchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("") {
                guard !isBusy else { return }
                Task { await model.load() }
            }
            .keyboardShortcut("r", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.skyBlue.opacity(0.18))
                    .frame(width: 42, height: 42)

                Image(systemName: "folder.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(Theme.skyBlue)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Files")
                        .font(.system(.title2, design: .rounded).weight(.black))
                        .foregroundStyle(Theme.textPrimary)

                    Text(providerStatusText)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(providerStatusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(providerStatusColor.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(providerStatusColor.opacity(0.28), lineWidth: 0.5))
                }

                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            providerPicker
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard(tint: Theme.skyBlue.opacity(0.12), cornerRadius: 18)
    }

    private var providerPicker: some View {
        HStack(spacing: 8) {
            Text("Provider")
                .font(.caption.bold())
                .foregroundStyle(Theme.textSecondary)

            Picker("Provider", selection: $selectedProvider) {
                ForEach(RemoteFileProviderID.allCases) { provider in
                    Label(provider.title, systemImage: provider.icon)
                        .tag(provider)
                        .disabled(!provider.isImplementedInFileManager)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            .disabled(isBusy)
            .onChange(of: selectedProvider) { _, provider in
                if !provider.isImplementedInFileManager {
                    selectedProvider = .seedbox
                    model.errorMessage = "\(provider.title) file browsing is coming soon."
                }
            }
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            fullToolbar
            compactToolbar
        }
        .padding(12)
        .glassCard(tint: Theme.skyBlue.opacity(0.10), cornerRadius: 16)
    }

    private var fullToolbar: some View {
        HStack(spacing: 10) {
            navigationControls
            breadcrumbBar
            operationIndicator

            Spacer(minLength: 8)

            searchField
            sortPicker
            densityMenu
            primaryActions
        }
    }

    private var compactToolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                navigationControls
                breadcrumbBar
                operationIndicator
                Spacer()
            }

            HStack(spacing: 10) {
                searchField
                sortPicker
                densityMenu
                Spacer()
                primaryActions
            }
        }
    }

    private var navigationControls: some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.goUp() }
            } label: {
                Label("Up", systemImage: "arrow.up")
            }
            .controlSize(.small)
            .disabled(model.currentPath == "/" || isBusy)
            .help("Go to parent folder")

            Button {
                Task { await model.load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(isBusy)
            .help("Refresh current folder")
        }
    }

    private var breadcrumbBar: some View {
        RemoteBreadcrumbBar(path: model.currentPath) { path in
            Task { await model.load(path: path) }
        }
        .disabled(isBusy)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(searchFocused ? Theme.skyBlue : Theme.textSecondary)

            TextField("Search files", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)

            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.surface0.opacity(0.62), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    searchFocused ? Theme.skyBlue.opacity(0.45) : Theme.skyBlue.opacity(0.12),
                    lineWidth: 0.8
                )
        )
        .frame(width: 240)
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $sortMode) {
            ForEach(RemoteFileSortMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden()
        .frame(width: 118)
        .controlSize(.small)
        .help("Sort files")
    }

    private var densityMenu: some View {
        Menu {
            Picker("Density", selection: $density) {
                ForEach(RemoteFileDensity.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
        } label: {
            Label(density.title, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .help("Row density")
    }

    private var primaryActions: some View {
        HStack(spacing: 8) {
            Button {
                newFolderName = ""
                showingCreateFolder = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .controlSize(.small)
            .disabled(isBusy)

            Button {
                chooseUploadFile()
            } label: {
                Label("Upload", systemImage: "arrow.up.doc")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(Theme.skyBlue)
            .disabled(isBusy)
        }
    }

    @ViewBuilder
    private var operationIndicator: some View {
        if let operation = model.activeOperation {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)

                Text(operationLabel(operation))
                    .font(.caption2.bold())
            }
            .foregroundStyle(Theme.skyBlue)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.skyBlue.opacity(0.12), in: Capsule())
        }
    }

    private var headerSubtitle: String {
        "\(model.currentPath) · \(visibleSummaryText)"
    }

    private var providerStatusText: String {
        if model.errorMessage != nil {
            return "Needs attention"
        }
        if isBusy {
            return "Working"
        }
        return "Connected"
    }

    private var providerStatusColor: Color {
        if model.errorMessage != nil {
            return Theme.warning
        }
        if isBusy {
            return Theme.skyBlue
        }
        return Theme.success
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.items.isEmpty {
            loadingState
        } else if visibleItems.isEmpty {
            emptyState
        } else {
            fileList
        }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    RemoteFileRow(
                        item: item,
                        density: density,
                        isLast: index == visibleItems.count - 1,
                        open: { Task { await model.open(item) } },
                        edit: { editingItem = item },
                        rename: {
                            renameText = item.name
                            pendingRenameItem = item
                        },
                        delete: { pendingDeleteItem = item },
                        download: { Task { await model.open(item) } }
                    )
                    .disabled(isBusy)
                }
            }
            .padding(.vertical, 4)
            .glassCard(tint: Theme.skyBlue.opacity(0.06), cornerRadius: 16)
        }
    }

    private var createFolderSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.skyBlue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("New Folder")
                        .font(.headline)
                    Text("Create inside \(model.currentPath)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    showingCreateFolder = false
                }
                Button("Create") {
                    let name = newFolderName
                    showingCreateFolder = false
                    Task { await model.createFolder(named: name) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.skyBlue)
                .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func renameSheet(_ item: RemoteFileItem) -> some View {
        let trimmedName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: item.kind == .folder ? "folder.fill" : "doc.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(item.kind == .folder ? Theme.gold : Theme.skyBlue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename")
                        .font(.headline)
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    pendingRenameItem = nil
                }
                Button("Rename") {
                    let value = trimmedName
                    pendingRenameItem = nil
                    Task { await model.rename(item, to: value) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.skyBlue)
                .disabled(trimmedName.isEmpty || trimmedName == item.name)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var loadingState: some View {
        VStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Theme.skyBlue.opacity(0.12))
                        .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.textSecondary.opacity(0.20))
                            .frame(width: index % 2 == 0 ? 220 : 320, height: 10)

                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.textSecondary.opacity(0.12))
                            .frame(width: 150, height: 8)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                if index < 6 {
                    Divider()
                        .overlay(Theme.skyBlue.opacity(0.08))
                        .padding(.leading, 58)
                }
            }
        }
        .redacted(reason: .placeholder)
        .glassCard(tint: Theme.skyBlue.opacity(0.06), cornerRadius: 16)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.skyBlue.opacity(0.14))
                    .frame(width: 68, height: 68)

                Image(systemName: model.searchText.isEmpty ? "folder" : "magnifyingglass")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.skyBlue)
            }

            Text(model.searchText.isEmpty ? "This folder is empty" : "No matching files")
                .font(.system(.headline, design: .rounded).weight(.black))
                .foregroundStyle(Theme.textPrimary)

            Text(model.searchText.isEmpty ? "Upload a file or create a folder to get started." : "Try another search term or clear the current filter.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                if model.searchText.isEmpty {
                    Button {
                        newFolderName = ""
                        showingCreateFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }

                    Button {
                        chooseUploadFile()
                    } label: {
                        Label("Upload", systemImage: "arrow.up.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.skyBlue)
                } else {
                    Button("Clear Search") {
                        model.searchText = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.skyBlue)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCard(tint: Theme.skyBlue.opacity(0.10), cornerRadius: 18)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text("Files could not complete the request")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.textPrimary)

                Text(message)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            Button("Retry") {
                Task { await model.load() }
            }
            .buttonStyle(.borderless)

            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .glassCard(tint: Theme.warning.opacity(0.14), cornerRadius: 12)
    }

    private func configureAndLoad() async {
        do {
            let client = try SeedboxRemoteFileClientFactory.make(
                transferMode: seedboxTransferMode,
                remoteName: seedboxRemoteName,
                remotePath: seedboxRemotePath,
                webdavURL: seedboxWebdavURL,
                webdavUser: seedboxWebdavUser,
                webdavPassword: seedboxWebdavPassword
            )
            selectedProvider = .seedbox
            model.configure(client: client)
            await model.load(path: "/")
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func chooseUploadFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.upload(localURL: url) }
        }
    }

    private func operationLabel(_ operation: RemoteFileOperation) -> String {
        switch operation {
        case .list: return "Loading"
        case .createFolder: return "Creating folder"
        case .rename: return "Renaming"
        case .delete: return "Deleting"
        case .upload: return "Uploading"
        case .download: return "Downloading"
        case .readText: return "Opening editor"
        case .saveText: return "Saving"
        }
    }

    private func handleExitCommand() {
        guard searchFocused else { return }
        if model.searchText.isEmpty {
            searchFocused = false
        } else {
            model.searchText = ""
        }
    }
}

private struct RemoteBreadcrumbBar: View {
    let path: String
    let navigate: (String) -> Void

    private var parts: [String] {
        RemoteFilesDisplay.breadcrumbParts(for: path)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                Button {
                    navigate("/")
                } label: {
                    Label("Root", systemImage: "internaldrive")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(parts.isEmpty ? Theme.textPrimary : Theme.skyBlue)

                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))

                    Button {
                        navigate(RemoteFilesDisplay.path(upTo: index, in: parts))
                    } label: {
                        Text(part)
                            .font(.system(
                                size: 12,
                                weight: index == parts.count - 1 ? .bold : .semibold,
                                design: .monospaced
                            ))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == parts.count - 1 ? Theme.textPrimary : Theme.skyBlue)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(minWidth: 160, maxWidth: 400, alignment: .leading)
        .background(Theme.surface0.opacity(0.62), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.skyBlue.opacity(0.18), lineWidth: 0.5))
    }
}

private struct RemoteFileRow: View {
    let item: RemoteFileItem
    let density: RemoteFileDensity
    let isLast: Bool
    let open: () -> Void
    let edit: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    let download: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        iconView

                        VStack(alignment: .leading, spacing: density == .compact ? 2 : 4) {
                            HStack(spacing: 8) {
                                Text(item.name)
                                    .font(.system(size: density == .compact ? 12 : 13, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                if let badge = extensionBadge {
                                    Text(badge)
                                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                                        .foregroundStyle(iconTint)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(iconTint.opacity(0.12), in: Capsule())
                                }
                            }

                            Text(RemoteFilesDisplay.metadataText(for: item))
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                rowActions
            }
            .padding(.horizontal, 12)
            .padding(.vertical, density == .compact ? 7 : 10)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }

            if !isLast {
                Divider()
                    .overlay(Theme.skyBlue.opacity(0.08))
                    .padding(.leading, 58)
            }
        }
        .contextMenu {
            contextMenuContent
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: Text(item.kind == .folder ? "Open" : "Download")) {
            item.kind == .folder ? open() : download()
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(isHovered ? Theme.skyBlue.opacity(0.08) : Color.clear)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }

    private var iconView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(iconTint.opacity(item.kind == .folder ? 0.16 : 0.12))
                .frame(width: density == .compact ? 30 : 34, height: density == .compact ? 30 : 34)

            Image(systemName: item.kind == .folder ? "folder.fill" : fileIcon)
                .font(.system(size: density == .compact ? 15 : 17, weight: .semibold))
                .foregroundStyle(iconTint)
        }
    }

    private var rowActions: some View {
        HStack(spacing: 8) {
            if RemoteFileTextPolicy.isLikelyTextEditable(item) {
                Button("Edit", action: edit)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.lavender)
                    .opacity(isHovered ? 1 : 0.72)
            }

            Button(item.kind == .folder ? "Open" : "Download") {
                item.kind == .folder ? open() : download()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.skyBlue)
            .font(.system(size: 12, weight: .bold))

            Menu {
                contextMenuContent
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button(item.kind == .folder ? "Open" : "Download/Open") {
            item.kind == .folder ? open() : download()
        }

        if RemoteFileTextPolicy.isLikelyTextEditable(item) {
            Button("Edit Text") { edit() }
        }

        Button("Rename") { rename() }

        Divider()

        Button("Delete", role: .destructive) { delete() }
    }

    private var iconTint: Color {
        if item.kind == .folder {
            return Theme.gold.opacity(0.82)
        }

        switch RemoteFilesDisplay.fileExtension(name: item.name) {
        case "mp4", "mov", "mkv", "webm", "avi":
            return Theme.skyBlue
        case "jpg", "jpeg", "png", "webp", "gif":
            return Theme.hotPink
        case "txt", "md", "json", "yaml", "yml", "xml", "csv", "log":
            return Theme.lavender
        default:
            return Theme.textSecondary
        }
    }

    private var fileIcon: String {
        switch RemoteFilesDisplay.fileExtension(name: item.name) {
        case "mp4", "mov", "mkv", "webm", "avi":
            return "film.fill"
        case "jpg", "jpeg", "png", "webp", "gif":
            return "photo.fill"
        case "txt", "md", "json", "yaml", "yml", "xml", "csv", "log":
            return "doc.text.fill"
        default:
            return "doc.fill"
        }
    }

    private var extensionBadge: String? {
        guard item.kind == .file else { return nil }
        let ext = RemoteFilesDisplay.fileExtension(name: item.name).uppercased()
        guard !ext.isEmpty else { return nil }

        switch ext {
        case "MP4", "MKV", "MOV", "WEBM", "TXT", "MD", "JSON", "YAML", "YML", "CSV":
            return ext
        default:
            return nil
        }
    }

    private var accessibilityLabel: Text {
        Text("\(item.kind == .folder ? "Folder" : "File"), \(item.name), \(RemoteFilesDisplay.metadataText(for: item))")
    }
}
