import SwiftUI

@MainActor
struct DownloadQueueViewNew: View {
    @StateObject private var queue = DownloadQueue.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                Text("Downloads").font(.headline).foregroundStyle(Theme.textPrimary)
                Spacer()

                Button("Pause All") { queue.pauseAll() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(queue.queue.allSatisfy { $0.status.isTerminal || $0.status == .paused })
                Button("Resume All") { queue.resumeAll() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!queue.queue.contains(where: { $0.status == .paused || $0.status == .failed("") }))
                Button("Clear Done") { queue.clearCompleted() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!queue.queue.contains(where: { $0.status.isTerminal }))
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if queue.queue.isEmpty {
                VStack {
                    Image(systemName: "arrow.down.circle")
                        .resizable().scaledToFit()
                        .frame(width: 40, height: 40)
                        .foregroundStyle(Theme.accent.opacity(0.4))
                        .padding()
                    Text("No downloads").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(queue.queue.indices, id: \.self) { idx in
                            let item = queue.queue[idx]
                            DownloadQueueRow(item: item,
                                onRemove: { queue.remove(item) },
                                onPause: { queue.pause(item) },
                                onResume: { queue.resume(item) },
                                onMoveUp: { queue.moveUp(item) },
                                onMoveDown: { queue.moveDown(item) })
                            .cardStyle()
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
            }

            Spacer()
        }
    }
}

struct DownloadQueueRow: View {
    let item: DownloadQueueItem
    let onRemove: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                statusIcon
                VStack(alignment: .leading) {
                    Text(item.displayTitle ?? item.filename)
                        .font(.caption.bold())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(item.quality)
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                statusText
            }

            if isShowingProgress {
                ProgressView(value: item.progress, total: 100.0)
                    .progressViewStyle(.linear)
                    .tint(progressTint)
            }

            HStack {
                HStack(spacing: 4) {
                    Button(action: onMoveUp) { Image(systemName: "arrow.up") }
                        .buttonStyle(.bordered).controlSize(.mini)
                    Button(action: onMoveDown) { Image(systemName: "arrow.down") }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
                Spacer()
                if isPaused {
                    Button("Resume") { onResume() }
                        .buttonStyle(.bordered).controlSize(.mini)
                } else if isShowingProgress {
                    Button("Pause") { onPause() }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
                Button("Remove", role: .destructive) { onRemove() }
                    .buttonStyle(.bordered).controlSize(.mini)
            }
        }
        .padding(8)
    }

    var statusIcon: some View {
        Group {
            switch item.status {
            case .pending:
                Image(systemName: "clock.fill").foregroundStyle(Theme.warning)
            case .downloading, .uploading:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
            case .paused:
                Image(systemName: "pause.circle.fill").foregroundStyle(Theme.textSecondary)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.error)
            }
        }
    }

    var statusText: some View {
        Group {
            switch item.status {
            case .pending:
                Text("Queued").font(.caption).foregroundStyle(Theme.textSecondary)
            case .downloading:
                Text(String(format: "Downloading %.1f%%", item.progress))
                    .font(.caption).foregroundStyle(Theme.accent)
            case .uploading:
                Text(String(format: "Uploading %.1f%%", item.progress))
                    .font(.caption).foregroundStyle(Theme.accent)
            case .completed:
                Text("Done").font(.caption).foregroundStyle(Theme.success)
            case .paused:
                Text("Paused").font(.caption).foregroundStyle(Theme.textSecondary)
            case .failed(let reason):
                Text(reason.isEmpty ? "Failed" : reason)
                    .font(.caption).foregroundStyle(Theme.error)
            }
        }
    }

    var progressTint: Color {
        switch item.status {
        case .downloading, .uploading: return Theme.accent
        case .completed: return Theme.success
        case .failed: return Theme.error
        default: return Theme.accent
        }
    }

    var isShowingProgress: Bool {
        switch item.status {
        case .downloading, .uploading: return true
        default: return false
        }
    }

    var isPaused: Bool { item.status == .paused }
}
