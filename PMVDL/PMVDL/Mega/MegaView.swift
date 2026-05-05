import AppKit
import SwiftUI

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

                Button(action: {
                    DownloadPaths.ensureDownloadDir()
                    NSWorkspace.shared.open(DownloadPaths.downloadDir)
                }) {
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
        let dir = DownloadPaths.downloadDir
        DownloadPaths.ensureDownloadDir()

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
