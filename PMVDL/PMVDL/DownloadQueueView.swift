import SwiftUI

@MainActor
struct DownloadQueueViewNew: View {
    @StateObject private var queue = DownloadQueue.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                Text("Downloads").font(.headline)
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
                        .foregroundStyle(.secondary)
                        .padding()
                    Text("No downloads").font(.caption).foregroundStyle(.secondary)
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
                            Divider().padding(.leading, 8)
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
                        .lineLimit(1).truncationMode(.middle)
                    Text(item.quality)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                statusText
            }

            if isShowingProgress {
                ProgressView(value: item.progress, total: 100.0)
                    .progressViewStyle(.linear)
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
        .padding(.vertical, 4)
    }

    var statusIcon: some View {
        Group {
            switch item.status {
            case .pending:
                Image(systemName: "clock.fill").foregroundStyle(.orange)
            case .downloading, .uploading:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .paused:
                Image(systemName: "pause.circle.fill").foregroundStyle(.yellow)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }

    var statusText: some View {
        Group {
            switch item.status {
            case .pending:
                Text("Queued").font(.caption).foregroundStyle(.secondary)
            case .downloading:
                Text(String(format: "Downloading %.1f%%", item.progress))
                    .font(.caption).foregroundStyle(.blue)
            case .uploading:
                Text(String(format: "Uploading %.1f%%", item.progress))
                    .font(.caption).foregroundStyle(.blue)
            case .completed:
                Text("Done").font(.caption).foregroundStyle(.green)
            case .paused:
                Text("Paused").font(.caption).foregroundStyle(.yellow)
            case .failed(let reason):
                Text(reason.isEmpty ? "Failed" : reason)
                    .font(.caption).foregroundStyle(.red)
            }
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
