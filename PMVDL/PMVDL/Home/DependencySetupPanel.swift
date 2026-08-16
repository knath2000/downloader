import SwiftUI

struct DependencySetupPanel: View {
    let gdriveRemoteName: String
    @State private var checks: [DependencyCheck] = []

    private var actionableChecks: [DependencyCheck] {
        checks.filter { !$0.isReady }
    }

    var body: some View {
        Group {
            if !actionableChecks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundStyle(Theme.amber)
                        Text("Setup")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Button {
                            Task { await refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh setup checks")
                    }

                    VStack(spacing: 8) {
                        ForEach(checks) { check in
                            DependencyCheckRow(check: check)
                        }
                    }
                }
                .padding(12)
                .glassCard(tint: Theme.amber.opacity(0.16), cornerRadius: 12)
            }
        }
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        let remoteName = gdriveRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedRemoteName = remoteName.isEmpty ? "gdrive" : remoteName
        let agentReady = LustreAgentController.shared.health?.status == "ok"
        let agentDetail = LustreAgentController.shared.lastError ?? "Persistent downloads continue after LustreStudio quits"
        let next = await Task.detached {
            let ytDlpReady = ScraperEngine.isYTDLPAvailable
            let ffmpegReady = VideoProcessor.findFFmpeg() != nil
            let rcloneReady = GDriveManager.isAvailable
            let gdriveReady = rcloneReady && GDriveManager.isConfigured(remoteName: resolvedRemoteName)

            return [
                DependencyCheck(
                    id: "yt-dlp",
                    title: "yt-dlp",
                    detail: "Broad site extraction, audio, and subtitles",
                    status: ytDlpReady ? "Ready" : "Missing",
                    command: ytDlpReady ? nil : "brew install yt-dlp",
                    isReady: ytDlpReady
                ),
                DependencyCheck(
                    id: "ffmpeg",
                    title: "ffmpeg",
                    detail: "HLS downloads and video verification",
                    status: ffmpegReady ? "Ready" : "Missing",
                    command: ffmpegReady ? nil : "brew install ffmpeg",
                    isReady: ffmpegReady
                ),
                DependencyCheck(
                    id: "agent",
                    title: "Background Agent",
                    detail: agentDetail,
                    status: agentReady ? "Running" : "Needs repair",
                    command: nil,
                    isReady: agentReady
                ),
                DependencyCheck(
                    id: "gdrive",
                    title: "Google Drive",
                    detail: "rclone remote named \(resolvedRemoteName)",
                    status: gdriveReady ? "Configured" : (rcloneReady ? "Configure" : "Missing"),
                    command: gdriveReady ? nil : (rcloneReady ? "rclone config" : "brew install rclone"),
                    isReady: gdriveReady
                )
            ]
        }.value
        checks = next
    }
}

struct DependencyCheck: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let status: String
    let command: String?
    let isReady: Bool
}

struct DependencyCheckRow: View {
    let check: DependencyCheck

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: check.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(check.isReady ? Theme.success : Theme.warning)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(check.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(check.status.uppercased())
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(check.isReady ? Theme.success : Theme.warning)
                    Spacer()
                }

                Text(check.detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)

                if let command = check.command {
                    HStack(spacing: 6) {
                        Text(command)
                            .font(.system(size: 10, design: .monospaced).weight(.medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            copy(command)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy command")
                    }
                }
            }
        }
        .padding(8)
        .background(Theme.surface2.opacity(check.isReady ? 0.18 : 0.32), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
