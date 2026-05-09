import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RemoteFilesView: View {
    private static let remoteDragType = UTType(importedAs: "com.viddl.remote-files")
    fileprivate static let remoteDropTypes: [UTType] = [remoteDragType, .fileURL]

    let seedboxTransferMode: String
    let seedboxRemoteName: String
    let seedboxRemotePath: String
    let seedboxWebdavURL: String
    let seedboxWebdavUser: String
    let seedboxWebdavPassword: String

    @StateObject private var model = RemoteFilesViewModel()

    @State private var selectedProvider: RemoteFileProviderID = .seedbox
    @State private var showingCreateFolder = false
    @State private var showingMoveSheet = false
    @State private var newFolderName = ""
    @State private var moveTargetPath = ""
    @State private var pendingRenameItem: RemoteFileItem?
    @State private var renameText = ""
    @State private var pendingDeleteItems: [RemoteFileItem] = []
    @State private var editingItem: RemoteFileItem?
    @State private var infoContext: RemoteFileInfoContext?
    @State private var sortMode: RemoteFileSortMode = .name
    @State private var density: RemoteFileDensity = .comfortable
    @State private var selection = RemoteFileSelectionState()
    @State private var dropTargetPath: String?
    @State private var isListDropTargeted = false
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

    private var selectedItems: [RemoteFileItem] {
        visibleItems.filter { selection.selectedIDs.contains($0.id) }
    }

    private var hasSelection: Bool {
        !selectedItems.isEmpty
    }

    private var visibleSummaryText: String {
        if model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summary.title
        }

        return "\(visibleItems.count) of \(model.items.count) shown"
    }

    private var selectionSummaryText: String {
        let count = selectedItems.count
        return "\(count) selected"
    }

    private var deleteDialogTitle: String {
        pendingDeleteItems.count == 1 ? "Delete remote item?" : "Delete remote items?"
    }

    private var deleteDialogMessage: String {
        if pendingDeleteItems.count == 1, let item = pendingDeleteItems.first {
            return "Delete \"\(item.name)\" from \(model.currentPath)? This cannot be undone."
        }

        return "Delete \(pendingDeleteItems.count) items from \(model.currentPath)? This cannot be undone."
    }

    private var supportedDropTypes: [UTType] {
        Self.remoteDropTypes
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
        .onChange(of: model.currentPath) { _, _ in
            clearSelection()
        }
        .onChange(of: model.items) { _, items in
            let validIDs = Set(items.map(\.id))
            let selected = selection.selectedIDs.intersection(validIDs)
            selection = RemoteFileSelectionState(
                selectedIDs: selected,
                anchorID: selected.contains(selection.anchorID ?? "") ? selection.anchorID : selected.first
            )
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: Binding(
                get: { !pendingDeleteItems.isEmpty },
                set: { if !$0 { pendingDeleteItems = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let items = pendingDeleteItems
                if !items.isEmpty {
                    removeItemsFromSelection(items)
                    Task { await model.delete(items) }
                }
                pendingDeleteItems = []
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteItems = []
            }
        } message: {
            Text(deleteDialogMessage)
        }
        .sheet(isPresented: $showingCreateFolder) {
            createFolderSheet
        }
        .sheet(isPresented: $showingMoveSheet) {
            moveSheet
        }
        .sheet(item: $pendingRenameItem) { item in
            renameSheet(item)
        }
        .sheet(item: $infoContext) { context in
            RemoteFileInfoSheet(context: context)
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

            Button("") {
                selectAllVisible()
            }
            .keyboardShortcut("a", modifiers: .command)

            Button("") {
                requestDeleteSelection()
            }
            .keyboardShortcut(.delete, modifiers: [])

            Button("") {
                startRenameSelection()
            }
            .keyboardShortcut(.return, modifiers: [])
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
                selectionStatus
                Spacer()
                primaryActions
            }
        }
        .padding(12)
        .frame(minHeight: 88, alignment: .center)
        .glassCard(tint: Theme.skyBlue.opacity(0.10), cornerRadius: 16)
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

    private var selectionStatus: some View {
        Text(hasSelection ? selectionSummaryText : "0 selected")
            .font(.caption.bold())
            .foregroundStyle(hasSelection ? Theme.skyBlue : Color.clear)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: 92, alignment: .leading)
            .background(hasSelection ? Theme.skyBlue.opacity(0.12) : Color.clear, in: Capsule())
            .accessibilityHidden(!hasSelection)
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

                if let progress = model.operationProgress, progress.total > 1 {
                    Text("\(min(progress.completed + 1, progress.total)) of \(progress.total)")
                        .font(.caption2.bold())
                        .foregroundStyle(Theme.textSecondary)
                }
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
                        contextItems: contextItems(for: item),
                        density: density,
                        isSelected: selection.selectedIDs.contains(item.id),
                        isDropTarget: dropTargetPath == item.path,
                        isLast: index == visibleItems.count - 1,
                        click: { handleRowClick(of: item) },
                        open: { item in Task { await model.open(item) } },
                        edit: { item in editingItem = item },
                        rename: { item in
                            renameText = item.name
                            pendingRenameItem = item
                        },
                        duplicate: { items in Task { await model.duplicate(items) } },
                        move: { items in showMoveSheet(for: items) },
                        info: { items in showInfo(for: items) },
                        delete: { items in pendingDeleteItems = items },
                        download: { items in Task { await model.downloadAndOpen(items) } },
                        dragProvider: { beginRemoteDrag(from: item) },
                        drop: { providers in handleDrop(providers, targetDirectory: item.path) },
                        dropTargetChanged: { isTargeted in
                            dropTargetPath = isTargeted ? item.path : nil
                        }
                    )
                    .disabled(isBusy)
                }
            }
            .padding(.vertical, 4)
            .glassCard(tint: Theme.skyBlue.opacity(0.06), cornerRadius: 16)
            .onDrop(
                of: supportedDropTypes,
                isTargeted: $isListDropTargeted
            ) { providers in
                handleDrop(providers, targetDirectory: model.currentPath)
            }
            .overlay {
                if isListDropTargeted {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Theme.skyBlue.opacity(0.50), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
            }
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

    private var moveSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill.badge.gearshape")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.gold)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Move Selection")
                        .font(.headline)
                    Text(selectionSummaryText)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            TextField("Target folder path", text: $moveTargetPath)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") {
                    showingMoveSheet = false
                }
                Button("Move") {
                    let target = moveTargetPath
                    let items = selectedItems
                    showingMoveSheet = false
                    clearSelection()
                    Task { await model.move(items, toDirectory: target) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.skyBlue)
                .disabled(moveTargetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedItems.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
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
        panel.allowsMultipleSelection = true

        if panel.runModal() == .OK {
            Task { await model.upload(localURLs: panel.urls, toDirectory: model.currentPath) }
        }
    }

    private func handleRowClick(of item: RemoteFileItem) {
        let flags = NSEvent.modifierFlags
        let mode: RemoteFileSelectionMode
        if flags.contains(.shift) {
            mode = .range
        } else if flags.contains(.command) {
            mode = .toggle
        } else {
            mode = .replace
        }

        selection = RemoteFileSelectionReducer.select(
            itemID: item.id,
            orderedIDs: visibleItems.map(\.id),
            state: selection,
            mode: mode
        )
    }

    private func contextItems(for item: RemoteFileItem) -> [RemoteFileItem] {
        if selection.selectedIDs.contains(item.id), !selectedItems.isEmpty {
            return selectedItems
        }
        return [item]
    }

    private func setSelection(to items: [RemoteFileItem]) {
        selection = RemoteFileSelectionState(
            selectedIDs: Set(items.map(\.id)),
            anchorID: items.first?.id
        )
    }

    private func selectAllVisible() {
        guard !visibleItems.isEmpty else { return }
        selection = RemoteFileSelectionReducer.selectAll(orderedIDs: visibleItems.map(\.id))
    }

    private func clearSelection() {
        selection = RemoteFileSelectionState()
    }

    private func removeItemsFromSelection(_ items: [RemoteFileItem]) {
        let removedIDs = Set(items.map(\.id))
        let selected = selection.selectedIDs.subtracting(removedIDs)
        selection = RemoteFileSelectionState(
            selectedIDs: selected,
            anchorID: selected.contains(selection.anchorID ?? "") ? selection.anchorID : selected.first
        )
    }

    private func requestDeleteSelection() {
        guard !selectedItems.isEmpty else { return }
        pendingDeleteItems = selectedItems
    }

    private func startRenameSelection() {
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        renameText = item.name
        pendingRenameItem = item
    }

    private func showMoveSheet(for items: [RemoteFileItem]) {
        guard !items.isEmpty else { return }
        setSelection(to: items)
        moveTargetPath = model.currentPath
        showingMoveSheet = true
    }

    private func showInfo(for items: [RemoteFileItem]) {
        guard !items.isEmpty else { return }
        infoContext = RemoteFileInfoContext(
            provider: model.provider,
            currentPath: model.currentPath,
            items: items
        )
    }

    private func beginRemoteDrag(from item: RemoteFileItem) -> NSItemProvider {
        let dragItems = selection.selectedIDs.contains(item.id) ? selectedItems : [item]
        if !selection.selectedIDs.contains(item.id) {
            setSelection(to: [item])
        }

        let payload = RemoteFileDragPayload(
            provider: model.provider,
            sourceDirectory: model.currentPath,
            itemIDs: dragItems.map(\.id)
        )
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: Self.remoteDragType.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func handleDrop(_ providers: [NSItemProvider], targetDirectory: String) -> Bool {
        let target = RemotePath.normalizeDirectory(targetDirectory)
        let remoteProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(Self.remoteDragType.identifier)
        }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        if let remoteProvider = remoteProviders.first {
            let copyRequested = NSEvent.modifierFlags.contains(.option)
            Task {
                guard let payload = await loadRemotePayload(from: remoteProvider) else { return }
                await performRemoteDrop(payload, targetDirectory: target, copyRequested: copyRequested)
            }
        }

        if !fileProviders.isEmpty {
            Task {
                let urls = await loadFileURLs(from: fileProviders)
                guard !urls.isEmpty else { return }
                await model.upload(localURLs: urls, toDirectory: target)
            }
        }

        return !remoteProviders.isEmpty || !fileProviders.isEmpty
    }

    @MainActor
    private func performRemoteDrop(
        _ payload: RemoteFileDragPayload,
        targetDirectory: String,
        copyRequested: Bool
    ) async {
        guard payload.provider == model.provider else {
            model.errorMessage = "Items can only be moved within the same provider."
            return
        }

        let itemByID = Dictionary(uniqueKeysWithValues: model.items.map { ($0.id, $0) })
        let items = payload.itemIDs.compactMap { itemByID[$0] }
        guard !items.isEmpty else { return }

        clearSelection()
        if copyRequested {
            await model.copy(items, toDirectory: targetDirectory)
        } else {
            await model.move(items, toDirectory: targetDirectory)
        }
    }

    private func loadRemotePayload(from provider: NSItemProvider) async -> RemoteFileDragPayload? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: Self.remoteDragType.identifier) { data, _ in
                guard let data, let payload = try? JSONDecoder().decode(RemoteFileDragPayload.self, from: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: payload)
            }
        }
    }

    private func loadFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadFileURL(from: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let nsurl = item as? NSURL, nsurl.isFileURL {
                    continuation.resume(returning: nsurl as URL)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func operationLabel(_ operation: RemoteFileOperation) -> String {
        switch operation {
        case .list: return "Loading"
        case .createFolder: return "Creating folder"
        case .rename: return "Renaming"
        case .move: return "Moving"
        case .copy: return "Copying"
        case .duplicate: return "Duplicating"
        case .delete: return "Deleting"
        case .upload: return "Uploading"
        case .download: return "Downloading"
        case .readText: return "Opening editor"
        case .saveText: return "Saving"
        }
    }

    private func handleExitCommand() {
        if searchFocused {
            if model.searchText.isEmpty {
                searchFocused = false
            } else {
                model.searchText = ""
            }
        } else {
            clearSelection()
        }
    }
}

private struct RemoteFileInfoContext: Identifiable {
    let id = UUID()
    let provider: RemoteFileProviderID
    let currentPath: String
    let items: [RemoteFileItem]
}

private struct RemoteFileInfoSheet: View {
    let context: RemoteFileInfoContext

    private var summary: RemoteFileSummary {
        RemoteFilesDisplay.summary(for: context.items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: context.items.count == 1 ? icon(for: context.items[0]) : "checklist")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(context.items.count == 1 && context.items[0].kind == .folder ? Theme.gold : Theme.skyBlue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.items.count == 1 ? context.items[0].name : "\(context.items.count) Items")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(context.provider.title)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Divider()

            if context.items.count == 1, let item = context.items.first {
                infoRow("Kind", item.kind == .folder ? "Folder" : "File")
                infoRow("Path", item.path)
                infoRow("Size", item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown")
                infoRow("Modified", item.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown")
                infoRow("Content Type", item.contentType ?? "Unknown")
            } else {
                infoRow("Location", context.currentPath)
                infoRow("Folders", "\(summary.folders)")
                infoRow("Files", "\(summary.files)")
                infoRow("Known Size", ByteCountFormatter.string(fromByteCount: summary.totalFileBytes, countStyle: .file))
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 92, alignment: .leading)

            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
    }

    private func icon(for item: RemoteFileItem) -> String {
        item.kind == .folder ? "folder.fill" : "doc.fill"
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
    let contextItems: [RemoteFileItem]
    let density: RemoteFileDensity
    let isSelected: Bool
    let isDropTarget: Bool
    let isLast: Bool
    let click: () -> Void
    let open: (RemoteFileItem) -> Void
    let edit: (RemoteFileItem) -> Void
    let rename: (RemoteFileItem) -> Void
    let duplicate: ([RemoteFileItem]) -> Void
    let move: ([RemoteFileItem]) -> Void
    let info: ([RemoteFileItem]) -> Void
    let delete: ([RemoteFileItem]) -> Void
    let download: ([RemoteFileItem]) -> Void
    let dragProvider: () -> NSItemProvider
    let drop: ([NSItemProvider]) -> Bool
    let dropTargetChanged: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
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
            .padding(.horizontal, 12)
            .padding(.vertical, density == .compact ? 7 : 10)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture {
                click()
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard item.kind == .folder else { return }
                    open(item)
                }
            )
            .onDrag {
                dragProvider()
            }
            .modifier(RemoteFileRowDropModifier(
                isEnabled: item.kind == .folder,
                types: RemoteFilesView.remoteDropTypes,
                drop: drop,
                isTargeted: dropTargetChanged
            ))

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
            item.kind == .folder ? open(item) : download([item])
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(rowFill)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isDropTarget ? Theme.gold.opacity(0.65) : Color.clear, lineWidth: 1.2)
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isDropTarget)
    }

    private var rowFill: Color {
        if isDropTarget {
            return Theme.gold.opacity(0.12)
        }
        if isSelected {
            return Theme.skyBlue.opacity(0.16)
        }
        return isHovered ? Theme.skyBlue.opacity(0.08) : Color.clear
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

    @ViewBuilder
    private var contextMenuContent: some View {
        if let item = singleContextItem {
            Button(item.kind == .folder ? "Open" : "Download/Open") {
                item.kind == .folder ? open(item) : download([item])
            }
        } else if !contextFiles.isEmpty {
            Button("Download/Open Files") {
                download(contextFiles)
            }
        }

        if let item = singleContextItem, RemoteFileTextPolicy.isLikelyTextEditable(item) {
            Button("Edit Text") { edit(item) }
        }

        if let item = singleContextItem {
            Button("Rename") { rename(item) }
        }

        Button("Duplicate") { duplicate(contextItems) }
        Button("Move To...") { move(contextItems) }
        Button("Info") { info(contextItems) }

        Divider()

        Button("Delete", role: .destructive) { delete(contextItems) }
    }

    private var singleContextItem: RemoteFileItem? {
        contextItems.count == 1 ? contextItems.first : nil
    }

    private var contextFiles: [RemoteFileItem] {
        contextItems.filter { $0.kind == .file }
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

private struct RemoteFileRowDropModifier: ViewModifier {
    let isEnabled: Bool
    let types: [UTType]
    let drop: ([NSItemProvider]) -> Bool
    let isTargeted: (Bool) -> Void

    @State private var targeted = false

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onDrop(of: types, isTargeted: $targeted) { providers in
                    drop(providers)
                }
                .onChange(of: targeted) { _, value in
                    isTargeted(value)
                }
        } else {
            content
        }
    }
}
