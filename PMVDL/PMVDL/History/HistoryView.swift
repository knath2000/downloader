import AppKit
import SwiftUI

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
