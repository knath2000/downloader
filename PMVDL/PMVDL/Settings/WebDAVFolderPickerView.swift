import SwiftUI

struct WebDAVFolderPickerView: View {
    let baseURL: URL
    let user: String
    let password: String
    let allowSelfSigned: Bool
    @Binding var selectedPath: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var files = RemoteFilesViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button(action: { Task { await files.goUp() } }) {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(files.currentPath == "/" || files.isLoading)

                    Text(files.currentPath)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(action: { Task { await files.load() } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(files.isLoading)
                }
                .padding()

                Divider()

                if files.isLoading && files.items.isEmpty {
                    ProgressView("Loading folders…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = files.errorMessage {
                    ContentUnavailableView("Could not load folders", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    List(files.items.filter(\.isFolder)) { item in
                        Button {
                            Task { await files.open(item) }
                        } label: {
                            Label(item.name, systemImage: "folder.fill")
                                .foregroundStyle(Theme.gold)
                        }
                        .buttonStyle(.plain)
                    }
                    .overlay {
                        if files.items.filter(\.isFolder).isEmpty && !files.isLoading {
                            ContentUnavailableView("No subfolders", systemImage: "folder")
                        }
                    }
                }
            }
            .navigationTitle("Choose WebDAV Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use This Folder") {
                        selectedPath = files.currentPath
                        dismiss()
                    }
                    .disabled(files.isLoading)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task {
            files.configure(client: WebDAVRemoteFileClient(
                baseURL: baseURL,
                rootPath: "/",
                user: user,
                password: password,
                allowSelfSigned: allowSelfSigned
            ))
            await files.load(path: selectedPath)
        }
    }
}
