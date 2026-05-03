import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppStateManager.shared
    @StateObject private var downloadQueue = DownloadQueue.shared
    @StateObject private var transferManager = TransferManager.shared
    @StateObject private var updateManager = UpdateManager.shared
    @StateObject private var licenseManager = LicenseManager.shared
    @AppStorage("megaRemotePath") var megaRemotePath = "/Cloud/VidDL/"
    @AppStorage("gdriveRemoteName") var gdriveRemoteName = "gdrive"
    @AppStorage("gdriveRemotePath") var gdriveRemotePath = "VidDL/"
    @State private var showUpgradeOverlay = false
    @Namespace private var sidebarGlass

    var body: some View {
        ZStack {
            // Animated mesh gradient background
            MeshGradientBackground()
                .zIndex(-1)

            navigationBody
                .zIndex(0)

            if showUpgradeOverlay {
                UpgradeOverlay { showUpgradeOverlay = false }
                    .zIndex(1)
            }
        }
    }

    @ViewBuilder
    private var navigationBody: some View {
        if #available(macOS 26, *) {
            splitView
                .backgroundExtensionEffect()
        } else {
            splitView
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            // SIDEBAR — marketplace-style with colored icon bubbles
            VStack(spacing: 2) {
                ForEach(Array(NavDestination.allCases.enumerated()), id: \.element) { idx, dest in
                    SidebarNavItem(
                        dest: dest,
                        isSelected: appState.selectedDestination == dest,
                        badge: navBadge(for: dest),
                        namespace: sidebarGlass
                    ) {
                        appState.select(dest)
                    }
                    .scrollEntrance(delay: Double(idx) * 0.04)
                }
                Spacer()
                if !ProFeatureGate.isPro {
                    upgradeButton
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
                switch appState.selectedDestination {
                case .home:
                    HomeView(appState: appState,
                             megaRemotePath: megaRemotePath,
                             gdriveRemoteName: gdriveRemoteName,
                             gdriveRemotePath: gdriveRemotePath,
                             onUpgradeRequired: { showUpgradeOverlay = true })
                        .modifier(HomeDropDestination(
                            onUrlPaste: { _ in },
                            onFileDrop: { _ in }
                        ))
                        .padding()
                case .library:
                    LibraryView()
                        .padding()
                case .history:
                    HistoryView()
                        .padding()
                case .downloads:
                    DownloadQueueViewNew()
                        .padding()
                case .mega:
                    MegaView(megaRemotePath: $megaRemotePath)
                        .padding()
                case .scheduler:
                    SchedulerView()
                        .padding()
                case .transfers:
                    TransfersView(transferManager: transferManager)
                        .padding()
                case .processing:
                    ProcessingView()
                        .padding()
                case .settings:
                    SettingsView(gdriveRemoteName: $gdriveRemoteName,
                                 gdriveRemotePath: $gdriveRemotePath,
                                 megaRemotePath: $megaRemotePath)
                        .padding()
                }
            }
            .navigationTitle(appState.selectedDestination.rawValue)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 6) {
                        Button(action: { updateManager.checkForUpdates() }) {
                            Label(updateManager.currentVersion, systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Current version — click to check for updates")
                    }
                }
            }
            .onAppear {
                NotificationManager.shared.requestAuthorization()
            }
        }

    private func navBadge(for dest: NavDestination) -> Int? {
        switch dest {
        case .downloads:
            let q = downloadQueue.queue.filter { $0.isVisibleInDownloads && !$0.status.isTerminal }
            return q.isEmpty ? nil : q.count
        case .transfers:
            let c = transferManager.transfers.count + downloadQueue.queue.filter(\.isVisibleInTransfers).count
            return c == 0 ? nil : c
        default:
            return nil
        }
    }

    private var upgradeButton: some View {
        Button {
            appState.select(.settings)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "crown.fill")
                    .foregroundStyle(Theme.gold)
                Text("Upgrade to Pro")
                    .font(.caption.bold())
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.gold, Theme.amber], startPoint: .leading, endPoint: .trailing)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .glassCard(tint: Theme.gold, cornerRadius: 10)
        .padding(.bottom, 8)
    }
}

// MARK: - SidebarNavItem

private struct SidebarNavItem: View {
    let dest: NavDestination
    let isSelected: Bool
    let badge: Int?
    let namespace: Namespace.ID
    let action: () -> Void

    private var destColor: Color { Theme.destinationColor(dest) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Colored icon bubble
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(destColor.opacity(isSelected ? 0.35 : 0.18))
                        .frame(width: 30, height: 30)
                    Image(systemName: dest.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(destColor)
                }

                Text(dest.rawValue)
                    .font(.system(.body, design: .default).weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)

                Spacer()

                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(destColor, in: Capsule())
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.3), value: badge)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selectionBackground)
        }
        .buttonStyle(.plain)
        .pressEffect(scale: 0.96)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            if #available(macOS 26, *) {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(destColor), in: Capsule())
                    .glassEffectID(dest.rawValue, in: namespace)
            } else {
                Capsule()
                    .fill(destColor.opacity(0.18))
            }
        } else {
            Color.clear
        }
    }
}

@MainActor
final class HistoryManager: ObservableObject {
    static let shared = HistoryManager()

    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var completedUploads: [CompletedUploadItem] = []

    private let userDefaultsKey = "linkHistory"
    private let completedUploadsKey = "completedUploadHistory"
    private let limit = 100

    private init() {
        load()
    }

    func record(url: String, source: VideoSource) {
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty else { return }
        let title = cleanTitle(source.title, fallback: fallbackTitle(for: normalizedURL))
        let provider = providerName(for: source)
        items.removeAll { $0.url == normalizedURL }
        items.insert(HistoryItem(url: normalizedURL, title: title, provider: provider), at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        save()
    }

    func recordCompletedUpload(url: String, source: VideoSource, destination: String, remotePath: String) {
        let normalizedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedURL.isEmpty, !remotePath.isEmpty else { return }
        let title = cleanTitle(source.title, fallback: fallbackTitle(for: normalizedURL))
        let provider = providerName(for: source)
        completedUploads.removeAll { $0.remotePath == remotePath }
        completedUploads.insert(
            CompletedUploadItem(
                url: normalizedURL,
                title: title,
                provider: provider,
                destination: destination,
                remotePath: remotePath
            ),
            at: 0
        )
        if completedUploads.count > limit {
            completedUploads = Array(completedUploads.prefix(limit))
        }
        saveCompletedUploads()
    }

    func remove(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func removeCompletedUpload(_ item: CompletedUploadItem) {
        completedUploads.removeAll { $0.id == item.id }
        saveCompletedUploads()
    }

    func clear() {
        items.removeAll()
        completedUploads.removeAll()
        save()
        saveCompletedUploads()
    }

    func load() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded.sorted { $0.recordedAt > $1.recordedAt }
        }
        if let data = UserDefaults.standard.data(forKey: completedUploadsKey),
           let decoded = try? JSONDecoder().decode([CompletedUploadItem].self, from: data) {
            completedUploads = decoded.sorted { $0.completedAt > $1.completedAt }
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    private func saveCompletedUploads() {
        if let encoded = try? JSONEncoder().encode(completedUploads) {
            UserDefaults.standard.set(encoded, forKey: completedUploadsKey)
        }
    }

    private func cleanTitle(_ title: String?, fallback: String) -> String {
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func fallbackTitle(for url: String) -> String {
        if let last = URL(string: url)?.lastPathComponent.removingPercentEncoding,
           !last.isEmpty {
            return last.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        }
        return "Untitled Video"
    }

    private func providerName(for source: VideoSource) -> String {
        let raw = source.siteName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return source.displaySiteName }
        if raw == "NativeVideoPage" || raw == "ProviderLink" {
            return source.displaySiteName
        }
        return raw
    }
}

struct HistoryView: View {
    @StateObject private var history = HistoryManager.shared
    @State private var searchText = ""

    private var filteredItems: [HistoryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return history.items }
        return history.items.filter {
            $0.title.lowercased().contains(query)
            || $0.provider.lowercased().contains(query)
            || $0.url.lowercased().contains(query)
        }
    }

    private var filteredCompletedUploads: [CompletedUploadItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return history.completedUploads }
        return history.completedUploads.filter {
            $0.title.lowercased().contains(query)
            || $0.provider.lowercased().contains(query)
            || $0.destination.lowercased().contains(query)
            || $0.remotePath.lowercased().contains(query)
            || $0.url.lowercased().contains(query)
        }
    }

    private var totalCount: Int {
        history.items.count + history.completedUploads.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.gold)
                Text("History")
                    .font(Theme.sectionHeader)
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.gold, Theme.amber], startPoint: .leading, endPoint: .trailing)
                    )
                Spacer()
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .font(.caption)
                Text("\(totalCount)")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accentDim, in: Capsule())
                Button("Clear") {
                    history.clear()
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(totalCount == 0)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if totalCount == 0 {
                VStack {
                    Image(systemName: "clock")
                        .resizable().scaledToFit()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(Theme.accent.opacity(0.4))
                        .padding()
                    Text("No recent links yet").font(.caption).foregroundStyle(Theme.textSecondary)
                    Text("Extract a video URL to add it here")
                        .font(.caption2).foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty && filteredCompletedUploads.isEmpty {
                VStack {
                    Image(systemName: "magnifyingglass")
                        .resizable().scaledToFit()
                        .frame(width: 34, height: 34)
                        .foregroundStyle(Theme.accent.opacity(0.35))
                        .padding()
                    Text("No matching links").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if !filteredCompletedUploads.isEmpty {
                            HistorySectionHeader(title: "Completed Uploads", count: filteredCompletedUploads.count)
                            ForEach(filteredCompletedUploads) { item in
                                CompletedUploadRow(item: item)
                                    .glassCard(tint: Theme.gold.opacity(0.4), cornerRadius: 12)
                                    .contextMenu {
                                        Button("Copy Remote Path") { ClipboardManager.copy(item.remotePath) }
                                        Button("Copy Source Link") { ClipboardManager.copy(item.url) }
                                        if let url = URL(string: item.url), url.scheme?.hasPrefix("http") == true {
                                            Button("Open Source Link") { NSWorkspace.shared.open(url) }
                                        }
                                        Divider()
                                        Button("Remove", role: .destructive) {
                                            history.removeCompletedUpload(item)
                                        }
                                    }
                            }
                        }

                        if !filteredItems.isEmpty {
                            HistorySectionHeader(title: "Recent Links", count: filteredItems.count)
                            ForEach(filteredItems) { item in
                                HistoryRow(item: item)
                                    .glassCard(tint: Theme.skyBlue.opacity(0.25), cornerRadius: 12)
                                    .contextMenu {
                                        Button("Extract Again") { extractAgain(item) }
                                        Button("Copy Link") { ClipboardManager.copy(item.url) }
                                        Button("Open Link") {
                                            if let url = URL(string: item.url) {
                                                NSWorkspace.shared.open(url)
                                            }
                                        }
                                        Divider()
                                        Button("Remove", role: .destructive) {
                                            history.remove(item)
                                        }
                                    }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
        }
    }

    private func extractAgain(_ item: HistoryItem) {
        AppStateManager.shared.pendingExtractURL = item.url
        AppStateManager.shared.select(.home)
    }
}

struct HistorySectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(Theme.textSecondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.accentDim, in: Capsule())
            Spacer()
        }
        .padding(.top, 6)
        .padding(.horizontal, 2)
    }
}

struct CompletedUploadRow: View {
    let item: CompletedUploadItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.caption.bold())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(item.provider)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accentDim, in: Capsule())
                    Text(item.destination)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.success)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.success.opacity(0.12), in: Capsule())
                }

                Text(item.remotePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(item.completedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)

            Button {
                ClipboardManager.copy(item.remotePath)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy remote path")
        }
        .padding(8)
    }
}

struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link.circle.fill")
                .foregroundStyle(Theme.accent)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.caption.bold())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(item.provider)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accentDim, in: Capsule())
                }

                Text(item.url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(item.recordedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)

            Button {
                ClipboardManager.copy(item.url)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy link")

            Button {
                AppStateManager.shared.pendingExtractURL = item.url
                AppStateManager.shared.select(.home)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Extract again")
        }
        .padding(8)
    }
}

// ===== MEGA LOCAL UPLOAD VIEW =====
struct MegaView: View {
    @Binding var megaRemotePath: String
    @State private var files: [MegaLocalVideoFile] = []
    @State private var selectedFiles: Set<URL> = []
    @State private var uploadStates: [URL: MegaLocalUploadState] = [:]
    @State private var isUploading = false
    @State private var megaAvailable = MegaManager.isAvailable
    @State private var megaLoggedIn = false

    private let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "cloud.fill").foregroundStyle(Theme.accent)
                Text("Mega").font(.headline).foregroundStyle(Theme.textPrimary)
                Spacer()

                Button(action: refreshAll) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(isUploading)

                Button(action: { NSWorkspace.shared.open(DownloadManager.shared.downloadDir) }) {
                    Label("Open Folder", systemImage: "folder")
                }
                .buttonStyle(.bordered).controlSize(.small)

                Button(action: selectAll) {
                    Label("Select All", systemImage: "checklist")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(files.isEmpty || isUploading)

                Button(action: clearSelection) {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(selectedFiles.isEmpty || isUploading)

                Button(action: uploadSelected) {
                    Label("Upload Selected", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(selectedFiles.isEmpty || !megaAvailable || !megaLoggedIn || isUploading)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            HStack(spacing: 8) {
                connectionIcon
                Text(connectionMessage)
                    .font(.caption)
                    .foregroundStyle(connectionColor)
                Spacer()
                Text(uploadRemotePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if files.isEmpty {
                VStack {
                    Image(systemName: "film")
                        .resizable().scaledToFit()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(Theme.accent.opacity(0.4))
                        .padding()
                    Text("No local videos in Downloads/VidDL")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(files) { file in
                            MegaLocalVideoRow(
                                file: file,
                                isSelected: Binding(
                                    get: { selectedFiles.contains(file.url) },
                                    set: { isSelected in
                                        if isSelected { selectedFiles.insert(file.url) }
                                        else { selectedFiles.remove(file.url) }
                                    }
                                ),
                                state: uploadStates[file.url] ?? .idle
                            )
                            .disabled(isUploading)
                            .glassCard(tint: Theme.hotPink.opacity(0.25), cornerRadius: 12)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }

            Spacer()
        }
        .onAppear(perform: refreshAll)
    }

    private var uploadRemotePath: String {
        let trimmed = megaRemotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return MegaManager.defaultPath }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    private var connectionIcon: some View {
        Group {
            if !megaAvailable {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.error)
            } else if !megaLoggedIn {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
            }
        }
    }

    private var connectionMessage: String {
        if !megaAvailable { return "Mega CLI not installed" }
        if !megaLoggedIn { return "Mega account not connected" }
        return "Mega connected"
    }

    private var connectionColor: Color {
        if !megaAvailable { return Theme.error }
        if !megaLoggedIn { return Theme.warning }
        return Theme.success
    }

    private func refreshAll() {
        refreshFiles()
        refreshMegaConnection()
    }

    private func refreshMegaConnection() {
        Task {
            let available = await Task.detached { MegaManager.isAvailable }.value
            let loggedIn = available ? await Task.detached { MegaManager.isLoggedIn }.value : false
            megaAvailable = available
            megaLoggedIn = loggedIn
        }
    }

    private func refreshFiles() {
        let dir = DownloadManager.shared.downloadDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        )) ?? []

        files = urls.compactMap { url in
            guard videoExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(resourceKeys))
            guard values?.isRegularFile == true else { return nil }
            return MegaLocalVideoFile(
                url: url,
                size: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? Date.distantPast
            )
        }
        .sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.name < $1.name }
            return $0.modifiedAt > $1.modifiedAt
        }

        let current = Set(files.map(\.url))
        selectedFiles = selectedFiles.filter { current.contains($0) }
        uploadStates = uploadStates.filter { current.contains($0.key) }
    }

    private func selectAll() {
        selectedFiles = Set(files.map(\.url))
    }

    private func clearSelection() {
        selectedFiles.removeAll()
    }

    private func uploadSelected() {
        guard !isUploading, megaAvailable, megaLoggedIn else { return }
        let uploadFiles = files.filter { selectedFiles.contains($0.url) }
        guard !uploadFiles.isEmpty else { return }

        isUploading = true
        Task {
            for file in uploadFiles {
                uploadStates[file.url] = .uploading("Queued", 0)
                do {
                    let result = try await MegaManager.uploadLocalFile(file.url, remotePath: uploadRemotePath) { event in
                        uploadStates[file.url] = .uploading(event.message, event.percent)
                    }
                    let uploadedName = result.remotePath.split(separator: "/").last.map(String.init) ?? file.name
                    uploadStates[file.url] = .done("Uploaded as \(uploadedName)")
                    NotificationManager.shared.notifyUploadComplete(filename: uploadedName, destination: uploadRemotePath)
                } catch {
                    uploadStates[file.url] = .failed(error.localizedDescription)
                    NotificationManager.shared.notifyUploadFailed(filename: file.name, reason: error.localizedDescription)
                }
            }
            selectedFiles.removeAll()
            isUploading = false
            refreshAll()
        }
    }
}

struct MegaLocalVideoFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modifiedAt: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

enum MegaLocalUploadState: Equatable {
    case idle
    case uploading(String, Double)
    case done(String)
    case failed(String)
}

struct MegaLocalVideoRow: View {
    let file: MegaLocalVideoFile
    @Binding var isSelected: Bool
    let state: MegaLocalUploadState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("", isOn: $isSelected)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                Image(systemName: "film.fill")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.caption.bold())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(formatBytes(file.size)) · \(formatDate(file.modifiedAt))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                statusView
            }

            if case .uploading(let message, let percent) = state {
                ProgressView(value: percent, total: 100.0)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(8)
    }

    private var statusView: some View {
        Group {
            switch state {
            case .idle:
                EmptyView()
            case .uploading(_, let percent):
                Text(String(format: "%.0f%%", percent))
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            case .done:
                Label("Done", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.success)
            case .failed(let message):
                Label(message.isEmpty ? "Failed" : message, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.error)
                    .lineLimit(1)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// ===== TRANSFERS VIEW =====
struct TransfersView: View {
    @ObservedObject var transferManager: TransferManager
    @StateObject private var queue = DownloadQueue.shared

    private var viddlUploads: [DownloadQueueItem] {
        queue.queue.filter(\.isVisibleInTransfers)
    }

    private var megaCmdTransfers: [TransferItem] {
        let names = viddlUploads.flatMap { item -> [String] in
            [
                item.filename,
                item.displayTitle ?? "",
                VideoFileNaming.mp4FileName(title: item.displayTitle, fallback: item.filename)
            ].filter { !$0.isEmpty }
        }
        return transferManager.transfers.filter { transfer in
            guard transfer.filename != "unknown" else { return true }
            return !names.contains { name in
                name == transfer.filename || name.localizedCaseInsensitiveContains(transfer.filename)
            }
        }
    }

    private var hasVisibleTransfers: Bool {
        !viddlUploads.isEmpty || !megaCmdTransfers.isEmpty
    }

    private var hasCancelableTransfers: Bool {
        viddlUploads.contains { $0.status == .uploading }
        || megaCmdTransfers.contains { isCancelable($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.accent)
                Text("Mega Transfers").font(.headline).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Cancel All", role: .destructive) {
                    cancelAllVisibleTransfers()
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!hasCancelableTransfers)
                Button(transferManager.isActive ? "Stop Polling" : "Start Polling") {
                    if transferManager.isActive { transferManager.stop() }
                    else { transferManager.start() }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if !hasVisibleTransfers {
                VStack {
                    Image(systemName: "arrow.up.circle")
                        .resizable().scaledToFit()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(Theme.accent.opacity(0.5))
                        .padding()
                    Text("No uploads in progress").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        if !viddlUploads.isEmpty {
                            HistorySectionHeader(title: "VidDL Uploads", count: viddlUploads.count)
                            ForEach(viddlUploads) { item in
                                VidDLUploadRow(
                                    item: item,
                                    onCancel: { cancelVidDLUpload(item) },
                                    onRemove: { queue.remove(item) }
                                )
                                    .glassCard(tint: Theme.coral.opacity(0.3), cornerRadius: 12)
                            }
                        }

                        if !megaCmdTransfers.isEmpty {
                            HistorySectionHeader(title: "MEGAcmd Activity", count: megaCmdTransfers.count)
                            ForEach(megaCmdTransfers) { t in
                                TransferRow(item: t, onCancel: {
                                    Task { await transferManager.cancelTransfer(tag: t.tag) }
                                })
                                .glassCard(tint: Theme.hotPink.opacity(0.3), cornerRadius: 12)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }
            Spacer()
        }
        .onAppear { transferManager.start() }
        .onDisappear { transferManager.stop() }
    }

    private func cancelVidDLUpload(_ item: DownloadQueueItem) {
        Task { @MainActor in
            await cancelVidDLUploadNow(item)
        }
    }

    private func cancelAllVisibleTransfers() {
        Task { @MainActor in
            for item in viddlUploads where item.status == .uploading {
                await cancelVidDLUploadNow(item)
            }
            for transfer in megaCmdTransfers where isCancelable(transfer) {
                await transferManager.cancelTransfer(tag: transfer.tag)
            }
        }
    }

    private func cancelVidDLUploadNow(_ item: DownloadQueueItem) async {
        await MegaManager.cancelUpload(id: item.id, filenames: uploadFilenames(for: item))
        let currentProgress = queue.queue.first(where: { $0.id == item.id })?.progress ?? item.progress
        queue.updateProgress(id: item.id, status: .failed("Canceled"), progress: currentProgress)
        if let tag = item.megatag, !tag.isEmpty {
            await transferManager.cancelTransfer(tag: tag)
        }
    }

    private func uploadFilenames(for item: DownloadQueueItem) -> [String] {
        [
            item.filename,
            item.displayTitle ?? "",
            VideoFileNaming.mp4FileName(title: item.displayTitle, fallback: item.filename)
        ].filter { !$0.isEmpty }
    }

    private func isCancelable(_ transfer: TransferItem) -> Bool {
        transfer.state == "ACTIVE" || transfer.state == "QUEUED"
    }
}

struct VidDLUploadRow: View {
    let item: DownloadQueueItem
    let onCancel: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                statusIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle ?? item.filename)
                        .font(.caption.bold())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Mega • \(item.quality)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                statusText
                if item.status == .uploading {
                    Button("Cancel", role: .destructive) { onCancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }

            if item.status == .uploading {
                ProgressView(value: item.progress, total: 100.0)
                    .tint(Theme.accent)
                    .progressViewStyle(.linear)
            }

            HStack {
                if let finalPath = item.finalPath, !finalPath.isEmpty {
                    Text(finalPath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if case .failed = item.status {
                    Button("Remove", role: .destructive) { onRemove() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: some View {
        switch item.status {
        case .uploading:
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.accent)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.error)
        default:
            Image(systemName: "clock.fill").foregroundStyle(Theme.warning)
        }
    }

    @ViewBuilder private var statusText: some View {
        switch item.status {
        case .uploading:
            Text(String(format: "%.0f%%", item.progress))
                .font(.caption)
                .foregroundStyle(Theme.accent)
        case .failed(let reason):
            Text(reason.isEmpty ? "Failed" : reason)
                .font(.caption)
                .foregroundStyle(Theme.error)
                .lineLimit(1)
        default:
            Text("Queued")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// ===== SETTINGS VIEW =====
struct SettingsView: View {
    @Binding var gdriveRemoteName: String
    @Binding var gdriveRemotePath: String
    @Binding var megaRemotePath: String
    @StateObject private var license = LicenseManager.shared
    @StateObject private var updater = UpdateManager.shared
    @State private var activateEmail = ""
    @State private var activationResult = ""
    @State private var isActivating = false
    @State private var isCheckingDependencies = false
    @State private var megaAvailable = MegaManager.isAvailable
    @State private var megaLoggedIn = false
    @State private var gdriveAvailable = GDriveManager.isAvailable
    @State private var gdriveConfigured = false
    @State private var ytDlpAvailable = ScraperEngine.isYTDLPAvailable
    @State private var ffmpegAvailable = ScraperEngine.isFFmpegAvailable

    private var trimmedActivationEmail: String {
        activateEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resolvedGDriveRemoteName: String {
        let trimmed = gdriveRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "gdrive" : trimmed
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "gearshape.fill").foregroundStyle(Theme.accent)
                    Text("Settings").font(.headline).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if isCheckingDependencies {
                        ProgressView()
                            .scaleEffect(0.65)
                            .controlSize(.small)
                    }
                    Button {
                        Task { await refreshDependencyChecks() }
                    } label: {
                        Label("Refresh Checks", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isCheckingDependencies)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                Form {
                    Section("Mega Upload") {
                        megaSetupCard
                        TextField("Remote path", text: $megaRemotePath)
                            .textFieldStyle(.roundedBorder)
                        Text("VidDL uploads completed Mega transfers into this folder after MEGAcmd is installed and signed in.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Section("Google Drive Upload") {
                        gdriveSetupCard
                        TextField("Remote name", text: $gdriveRemoteName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Remote path", text: $gdriveRemotePath)
                            .textFieldStyle(.roundedBorder)
                        Text("The remote name must match the Google Drive remote created in rclone.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Section("Notifications") {
                        Toggle("Upload complete", isOn: Binding(
                            get: { NotificationManager.shared.isEnabled(.uploadComplete) },
                            set: { NotificationManager.shared.setEnabled(.uploadComplete, enabled: $0) }
                        ))
                        Toggle("Upload failed", isOn: Binding(
                            get: { NotificationManager.shared.isEnabled(.uploadFailed) },
                            set: { NotificationManager.shared.setEnabled(.uploadFailed, enabled: $0) }
                        ))
                        Toggle("Extraction complete", isOn: Binding(
                            get: { NotificationManager.shared.isEnabled(.scrapeComplete) },
                            set: { NotificationManager.shared.setEnabled(.scrapeComplete, enabled: $0) }
                        ))
                    }
                    Section("Updates") {
                        HStack {
                            Text("Current: \(updater.currentVersion)")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Check for Updates") {
                                updater.checkForUpdates()
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    Section("Extensions") {
                        LabeledContent("Safari Extension", value: "Install via Safari → Extensions")
                        LabeledContent("Share Extension", value: "Available in Share menu")
                    }
                    Section("Download Options") {
                        Toggle("Auto-download subtitles", isOn: Binding(
                            get: { DownloadManager.shared.subtitlesEnabled },
                            set: { DownloadManager.shared.subtitlesEnabled = $0 }
                        ))
                        if DownloadManager.shared.subtitlesEnabled {
                            Picker("Subtitle mode",
                                   selection: Binding(get: { DownloadManager.shared.embeddedSubsMode ? 1 : 0 },
                                                      set: { DownloadManager.shared.embeddedSubsMode = $0 == 1 })) {
                                Text("Sidecar files").tag(0)
                                Text("Embedded").tag(1)
                            }
                        }
                        SettingsDependencyInlineRow(
                            title: "yt-dlp",
                            readyText: "Installed for broad site extraction, audio, and subtitles",
                            missingText: "Missing. Install it to improve extraction and audio/subtitle downloads.",
                            command: "brew install yt-dlp",
                            isReady: ytDlpAvailable,
                            color: Theme.skyBlue
                        )
                        SettingsDependencyInlineRow(
                            title: "ffmpeg",
                            readyText: "Installed for HLS streams and video processing",
                            missingText: "Missing. Install it for HLS streams and post-processing.",
                            command: "brew install ffmpeg",
                            isReady: ffmpegAvailable,
                            color: Theme.coral
                        )
                        Button("Open Downloads Folder") {
                            NSWorkspace.shared.open(DownloadManager.shared.downloadDir)
                        }.buttonStyle(.plain).font(.caption)
                    }

                    // ===== PRO LICENSING =====
                    if !ProFeatureGate.isPro {
                        Section("Upgrade to Pro") {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "crown.fill").foregroundStyle(.yellow)
                                    Text("VidDL Pro — $0.99 one-time").font(.subheadline.bold())
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("• Unlimited batch downloads")
                                    Text("• Schedule downloads")
                                    Text("• Multi-cloud simultaneous upload")
                                    Text("• Priority support")
                                }
                                .font(.caption).foregroundStyle(.secondary)

                                TextField("Email", text: $activateEmail)
                                    .textFieldStyle(.roundedBorder).font(.caption)
                                Text("Enter the email to use for your Pro license.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                if !activationResult.isEmpty {
                                    Text(activationResult)
                                        .font(.caption)
                                        .foregroundStyle(activationResult.hasPrefix("OK") ? .green : .red)
                                }
                                if !license.lastError.isEmpty {
                                    Text(license.lastError)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                Text("Free downloads remaining: \(license.freeDownloadsRemaining)")
                                    .font(.caption2).foregroundStyle(.secondary)

                                HStack {
                                    Button("Buy Pro") {
                                        Task {
                                            isActivating = true
                                            let ok = await license.startCheckout(email: trimmedActivationEmail)
                                            activationResult = ok ? "Checkout opened. After payment, return here or click Open VidDL on the success page." : "Checkout failed."
                                            isActivating = false
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(isActivating || trimmedActivationEmail.isEmpty)

                                    Button("Activate Pro") {
                                        Task {
                                            isActivating = true
                                            let ok = await license.activate(email: trimmedActivationEmail)
                                            activationResult = ok ? "OK — Pro activated!" : "No active Pro license found."
                                            isActivating = false
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(isActivating || trimmedActivationEmail.isEmpty)
                                }
                            }
                            .padding(4)
                            .onAppear {
                                if activateEmail.isEmpty {
                                    activateEmail = license.activationEmail
                                }
                            }
                            .onChange(of: activateEmail) { _, _ in
                                activationResult = ""
                                license.lastError = ""
                            }
                        }
                    } else {
                        Section("Pro License") {
                            HStack {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                Text("Pro activated for \(license.activationEmail)")
                                    .font(.caption)
                                Spacer()
                                Button("Deactivate") {
                                    license.deactivateLocalLicense()
                                    activationResult = "License deactivated."
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    Section("About") {
                        Button("About VidDL") { showAboutWindow() }
                            .buttonStyle(.plain).font(.caption)
                    }
                }
                .padding(.horizontal)
                .frame(maxHeight: .infinity)
            }
        }
        .task {
            await refreshDependencyChecks()
        }
        .onChange(of: gdriveRemoteName) { _, _ in
            Task { await refreshDependencyChecks() }
        }
    }

    @ViewBuilder
    private var megaSetupCard: some View {
        if megaLoggedIn {
            SettingsDependencyCard(
                icon: "cloud.fill",
                title: "Mega upload is ready",
                status: "Ready",
                detail: "VidDL can find MEGAcmd and the current Mega session is signed in.",
                command: nil,
                footnote: "Uploads will use the remote path below.",
                color: Theme.success,
                isReady: true
            )
        } else if megaAvailable {
            SettingsDependencyCard(
                icon: "person.crop.circle.badge.exclamationmark",
                title: "MEGAcmd is installed, but not signed in",
                status: "Sign in required",
                detail: "Mega uploads are disabled until MEGAcmd has an active Mega account session.",
                command: "mega-login",
                footnote: "Open MEGAcmd or run the command, sign in, then click Refresh Checks.",
                color: Theme.warning,
                isReady: false
            )
        } else {
            SettingsDependencyCard(
                icon: "exclamationmark.triangle.fill",
                title: "MEGAcmd is missing",
                status: "Missing",
                detail: "Mega uploads are disabled because VidDL cannot find MEGAcmd or the mega-exec command on this Mac.",
                command: "brew install --cask megacmd-app",
                footnote: "Install MEGAcmd, open it once to sign in, then click Refresh Checks.",
                color: Theme.error,
                isReady: false
            )
        }
    }

    @ViewBuilder
    private var gdriveSetupCard: some View {
        if gdriveConfigured {
            SettingsDependencyCard(
                icon: "externaldrive.fill.badge.checkmark",
                title: "Google Drive upload is ready",
                status: "Configured",
                detail: "VidDL can find rclone and the \(resolvedGDriveRemoteName) remote.",
                command: nil,
                footnote: "Uploads will use the remote path below.",
                color: Theme.success,
                isReady: true
            )
        } else if gdriveAvailable {
            SettingsDependencyCard(
                icon: "externaldrive.badge.exclamationmark",
                title: "Google Drive remote is not configured",
                status: "Configure remote",
                detail: "rclone is installed, but VidDL cannot find a remote named \(resolvedGDriveRemoteName).",
                command: "rclone config",
                footnote: "Create a Google Drive remote named exactly \(resolvedGDriveRemoteName), then click Refresh Checks.",
                color: Theme.warning,
                isReady: false
            )
        } else {
            SettingsDependencyCard(
                icon: "externaldrive.badge.xmark",
                title: "rclone is missing",
                status: "Missing",
                detail: "Google Drive uploads are disabled because VidDL cannot find the rclone command on this Mac.",
                command: "brew install rclone",
                footnote: "Install rclone, create a Google Drive remote named \(resolvedGDriveRemoteName), then click Refresh Checks.",
                color: Theme.error,
                isReady: false
            )
        }
    }

    private func refreshDependencyChecks() async {
        if isCheckingDependencies { return }
        isCheckingDependencies = true
        let remoteName = resolvedGDriveRemoteName
        let snapshot = await Task.detached {
            let megaReady = MegaManager.isAvailable
            let rcloneReady = GDriveManager.isAvailable
            return SettingsDependencySnapshot(
                megaAvailable: megaReady,
                megaLoggedIn: megaReady && MegaManager.isLoggedIn,
                gdriveAvailable: rcloneReady,
                gdriveConfigured: rcloneReady && GDriveManager.isConfigured(remoteName: remoteName),
                ytDlpAvailable: ScraperEngine.isYTDLPAvailable,
                ffmpegAvailable: ScraperEngine.isFFmpegAvailable
            )
        }.value
        megaAvailable = snapshot.megaAvailable
        megaLoggedIn = snapshot.megaLoggedIn
        gdriveAvailable = snapshot.gdriveAvailable
        gdriveConfigured = snapshot.gdriveConfigured
        ytDlpAvailable = snapshot.ytDlpAvailable
        ffmpegAvailable = snapshot.ffmpegAvailable
        isCheckingDependencies = false
    }
}

private struct SettingsDependencySnapshot: Sendable {
    let megaAvailable: Bool
    let megaLoggedIn: Bool
    let gdriveAvailable: Bool
    let gdriveConfigured: Bool
    let ytDlpAvailable: Bool
    let ffmpegAvailable: Bool
}

private struct SettingsDependencyCard: View {
    let icon: String
    let title: String
    let status: String
    let detail: String
    let command: String?
    let footnote: String
    let color: Color
    let isReady: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(color.opacity(isReady ? 0.18 : 0.24))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Text(status.uppercased())
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(color.opacity(0.16), in: Capsule())
                    }

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let command {
                SettingsCommandRow(command: command)
            }

            Text(footnote)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .glassCard(tint: color.opacity(isReady ? 0.10 : 0.18), cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(isReady ? 0.25 : 0.45), lineWidth: 1)
        )
    }
}

private struct SettingsDependencyInlineRow: View {
    let title: String
    let readyText: String
    let missingText: String
    let command: String
    let isReady: Bool
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(isReady ? Theme.success : Theme.warning)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(isReady ? "READY" : "MISSING")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(isReady ? Theme.success : Theme.warning)
                Spacer()
            }

            Text(isReady ? readyText : missingText)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !isReady {
                SettingsCommandRow(command: command)
            }
        }
        .padding(10)
        .background(Theme.surface2.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke((isReady ? Theme.success : color).opacity(0.25), lineWidth: 1)
        )
    }
}

private struct SettingsCommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(size: 11, design: .monospaced).weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            Button {
                ClipboardManager.copy(command)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }
}

// ===== TRANSFER ROW =====
struct TransferRow: View {
    let item: TransferItem
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                if item.state == "ACTIVE" {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.accent)
                } else if item.state == "QUEUED" {
                    Image(systemName: "clock.fill").foregroundStyle(Theme.warning)
                } else if item.state == "FAILED" {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.error)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                }
                Text(item.filename)
                    .font(.caption.bold())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(item.state == "QUEUED" ? "Queued" : String(format: "%.0f%%", item.progress))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if item.state == "ACTIVE" || item.state == "QUEUED" {
                ProgressView(value: item.progress, total: 100.0)
                    .tint(item.state == "QUEUED" ? Theme.warning : Theme.accent)
                    .progressViewStyle(.linear)
                HStack {
                    Text(item.size).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
            } else {
                HStack {
                    if item.state == "COMPLETED" {
                        Text("Upload complete").font(.caption).foregroundStyle(Theme.success)
                    } else if item.state == "FAILED" {
                        Text("Upload failed").font(.caption).foregroundStyle(Theme.error)
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
    }
}
