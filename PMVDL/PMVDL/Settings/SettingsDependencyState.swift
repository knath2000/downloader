import Foundation

// MARK: - Snapshot

/// Immutable capture of all dependency check results. Lives in SettingsDependencyStore between tab
/// switches so the UI never reverts to uninitialized false defaults.
struct SettingsDependencySnapshot: Sendable, Equatable {
    let megaAvailable: Bool
    let megaLoggedIn: Bool
    let gdriveAvailable: Bool
    let gdriveConfigured: Bool
    let seedboxRcloneAvailable: Bool
    let seedboxRcloneConfigured: Bool
    let ytDlpAvailable: Bool
    let ffmpegAvailable: Bool
}

// MARK: - Input

/// Values that influence which dependency check results are shown.
/// Conforms to Equatable + Hashable so it can be used as `.task(id:)` identity.
struct SettingsDependencyInput: Equatable, Hashable, Sendable {
    let gdriveRemoteName: String
    let seedboxTransferMode: String
    let seedboxRemoteName: String
    let seedboxWebdavURL: String

    var resolvedGDriveRemoteName: String {
        let t = gdriveRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "gdrive" : t
    }

    var resolvedSeedboxRemoteName: String {
        let t = seedboxRemoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "seedbox" : t
    }

    var hasSeedboxWebDAVURL: Bool {
        URLTrustPolicy.validated(seedboxWebdavURL)?.scheme?.lowercased() == "https"
    }
}

// MARK: - Presentation tone

/// Semantic color intent for a dependency card or inline row.
/// Mapped to actual Theme colors in SettingsView to keep the presenter free of SwiftUI imports.
enum SettingsDependencyTone: Equatable {
    case checking
    case success
    case warning
    case error
}

// MARK: - Presentation models

struct SettingsDependencyCardModel: Equatable {
    let icon: String
    let title: String
    let status: String
    let detail: String
    let command: String?
    let footnote: String
    let tone: SettingsDependencyTone
    let isReady: Bool
    let isChecking: Bool
}

struct SettingsDependencyInlineModel: Equatable {
    let title: String
    let status: String
    let detail: String
    let command: String?
    let tone: SettingsDependencyTone
    let isReady: Bool
    let isChecking: Bool
}

struct SettingsDependencyViewModel: Equatable {
    let mega: SettingsDependencyCardModel
    let gdrive: SettingsDependencyCardModel
    let seedbox: SettingsDependencyCardModel
    let ytDlp: SettingsDependencyInlineModel
    let ffmpeg: SettingsDependencyInlineModel
}

// MARK: - Presenter

/// Pure function that converts a snapshot (or nil) + input into view models.
/// nil snapshot → "Checking…" neutral state (never "Missing" from uninitialized defaults).
/// Non-nil snapshot → exact card text/commands matching the SettingsView branch logic.
enum SettingsDependencyPresenter {
    static func model(snapshot: SettingsDependencySnapshot?, input: SettingsDependencyInput) -> SettingsDependencyViewModel {
        guard let snapshot else { return checkingModel(input: input) }
        return resolvedModel(snapshot: snapshot, input: input)
    }

    // MARK: Checking (no snapshot yet — first visit or store not yet seeded)

    private static func checkingModel(input: SettingsDependencyInput) -> SettingsDependencyViewModel {
        SettingsDependencyViewModel(
            mega: SettingsDependencyCardModel(
                icon: "hourglass",
                title: "Checking MEGAcmd…",
                status: "Checking",
                detail: "Looking for MEGAcmd and the current Mega sign-in session.",
                command: nil,
                footnote: "This should only take a moment.",
                tone: .checking,
                isReady: false,
                isChecking: true
            ),
            gdrive: SettingsDependencyCardModel(
                icon: "hourglass",
                title: "Checking Google Drive remote…",
                status: "Checking",
                detail: "Looking for rclone and the \(input.resolvedGDriveRemoteName) remote.",
                command: nil,
                footnote: "This should only take a moment.",
                tone: .checking,
                isReady: false,
                isChecking: true
            ),
            seedbox: SettingsDependencyCardModel(
                icon: "hourglass",
                title: "Checking remote server setup…",
                status: "Checking",
                detail: input.seedboxTransferMode == "webdav"
                    ? "Checking WebDAV remote server settings."
                    : "Looking for rclone and the \(input.resolvedSeedboxRemoteName) remote.",
                command: nil,
                footnote: "This should only take a moment.",
                tone: .checking,
                isReady: false,
                isChecking: true
            ),
            ytDlp: SettingsDependencyInlineModel(
                title: "yt-dlp",
                status: "Checking",
                detail: "Checking broad site extraction, audio, and subtitle support…",
                command: nil,
                tone: .checking,
                isReady: false,
                isChecking: true
            ),
            ffmpeg: SettingsDependencyInlineModel(
                title: "ffmpeg",
                status: "Checking",
                detail: "Checking HLS stream and video processing support…",
                command: nil,
                tone: .checking,
                isReady: false,
                isChecking: true
            )
        )
    }

    // MARK: Resolved (snapshot is available)

    private static func resolvedModel(snapshot: SettingsDependencySnapshot, input: SettingsDependencyInput) -> SettingsDependencyViewModel {
        SettingsDependencyViewModel(
            mega: megaCard(snapshot: snapshot),
            gdrive: gdriveCard(snapshot: snapshot, input: input),
            seedbox: seedboxCard(snapshot: snapshot, input: input),
            ytDlp: ytDlpInline(snapshot: snapshot),
            ffmpeg: ffmpegInline(snapshot: snapshot)
        )
    }

    private static func megaCard(snapshot: SettingsDependencySnapshot) -> SettingsDependencyCardModel {
        if snapshot.megaLoggedIn {
            return SettingsDependencyCardModel(
                icon: "cloud.fill",
                title: "Mega upload is ready",
                status: "Ready",
                detail: "LustreStudio can find MEGAcmd and the current Mega session is signed in.",
                command: nil,
                footnote: "Uploads will use the remote path below.",
                tone: .success,
                isReady: true,
                isChecking: false
            )
        } else if snapshot.megaAvailable {
            return SettingsDependencyCardModel(
                icon: "person.crop.circle.badge.exclamationmark",
                title: "MEGAcmd is installed, but not signed in",
                status: "Sign in required",
                detail: "Mega uploads are disabled until MEGAcmd has an active Mega account session.",
                command: "mega-login",
                footnote: "Open MEGAcmd or run the command, sign in, then click Refresh Checks.",
                tone: .warning,
                isReady: false,
                isChecking: false
            )
        } else {
            return SettingsDependencyCardModel(
                icon: "exclamationmark.triangle.fill",
                title: "MEGAcmd is missing",
                status: "Missing",
                detail: "Mega uploads are disabled because LustreStudio cannot find MEGAcmd or the mega-exec command on this Mac.",
                command: "brew install --cask megacmd-app",
                footnote: "Install MEGAcmd, open it once to sign in, then click Refresh Checks.",
                tone: .error,
                isReady: false,
                isChecking: false
            )
        }
    }

    private static func gdriveCard(snapshot: SettingsDependencySnapshot, input: SettingsDependencyInput) -> SettingsDependencyCardModel {
        let remoteName = input.resolvedGDriveRemoteName
        if snapshot.gdriveConfigured {
            return SettingsDependencyCardModel(
                icon: "externaldrive.fill.badge.checkmark",
                title: "Google Drive upload is ready",
                status: "Configured",
                detail: "LustreStudio can find rclone and the \(remoteName) remote.",
                command: nil,
                footnote: "Uploads will use the remote path below.",
                tone: .success,
                isReady: true,
                isChecking: false
            )
        } else if snapshot.gdriveAvailable {
            return SettingsDependencyCardModel(
                icon: "externaldrive.badge.exclamationmark",
                title: "Google Drive remote is not configured",
                status: "Configure remote",
                detail: "rclone is installed, but LustreStudio cannot find a remote named \(remoteName).",
                command: "rclone config",
                footnote: "Create a Google Drive remote named exactly \(remoteName), then click Refresh Checks.",
                tone: .warning,
                isReady: false,
                isChecking: false
            )
        } else {
            return SettingsDependencyCardModel(
                icon: "externaldrive.badge.xmark",
                title: "rclone is missing",
                status: "Missing",
                detail: "Google Drive uploads are disabled because LustreStudio cannot find the rclone command on this Mac.",
                command: "brew install rclone",
                footnote: "Install rclone, create a Google Drive remote named \(remoteName), then click Refresh Checks.",
                tone: .error,
                isReady: false,
                isChecking: false
            )
        }
    }

    private static func seedboxCard(snapshot: SettingsDependencySnapshot, input: SettingsDependencyInput) -> SettingsDependencyCardModel {
        if input.seedboxTransferMode == "webdav" {
            let hasURL = input.hasSeedboxWebDAVURL
            return SettingsDependencyCardModel(
                icon: hasURL ? "checkmark.circle.fill" : "link.badge.plus",
                title: hasURL ? "WebDAV direct transfer is configured" : "WebDAV URL is required",
                status: hasURL ? "Configured" : "Missing URL",
                detail: hasURL
                    ? "LustreStudio will stream direct video URLs to WebDAV without rclone."
                    : "Enter the WebDAV base URL for your remote server.",
                command: nil,
                footnote: "HLS and yt-dlp sources still require rclone for the fallback upload step.",
                tone: hasURL ? .success : .warning,
                isReady: hasURL,
                isChecking: false
            )
        } else if snapshot.seedboxRcloneConfigured {
            return SettingsDependencyCardModel(
                icon: "externaldrive.fill.badge.checkmark",
                title: "Remote server is ready",
                status: "Configured",
                detail: "LustreStudio can find rclone and the \(input.resolvedSeedboxRemoteName) remote.",
                command: nil,
                footnote: "Direct videos will stream through rclone rcat to the remote path below.",
                tone: .success,
                isReady: true,
                isChecking: false
            )
        } else if snapshot.seedboxRcloneAvailable {
            return SettingsDependencyCardModel(
                icon: "externaldrive.badge.exclamationmark",
                title: "Remote server is not configured",
                status: "Configure remote",
                detail: "rclone is installed, but LustreStudio cannot find a remote named \(input.resolvedSeedboxRemoteName).",
                command: "rclone config",
                footnote: "Create a remote named exactly \(input.resolvedSeedboxRemoteName), then click Refresh Checks.",
                tone: .warning,
                isReady: false,
                isChecking: false
            )
        } else {
            return SettingsDependencyCardModel(
                icon: "externaldrive.badge.xmark",
                title: "rclone is missing",
                status: "Missing",
                detail: "Remote server transfers are disabled because LustreStudio cannot find the rclone command on this Mac.",
                command: "brew install rclone",
                footnote: "Install rclone and create an SFTP remote for rclone rcat or HLS fallback uploads.",
                tone: .error,
                isReady: false,
                isChecking: false
            )
        }
    }

    private static func ytDlpInline(snapshot: SettingsDependencySnapshot) -> SettingsDependencyInlineModel {
        if snapshot.ytDlpAvailable {
            return SettingsDependencyInlineModel(
                title: "yt-dlp",
                status: "Ready",
                detail: "Installed for broad site extraction, audio, and subtitles",
                command: nil,
                tone: .success,
                isReady: true,
                isChecking: false
            )
        } else {
            return SettingsDependencyInlineModel(
                title: "yt-dlp",
                status: "Missing",
                detail: "Missing. Install it to improve extraction and audio/subtitle downloads.",
                command: "brew install yt-dlp",
                tone: .warning,
                isReady: false,
                isChecking: false
            )
        }
    }

    private static func ffmpegInline(snapshot: SettingsDependencySnapshot) -> SettingsDependencyInlineModel {
        if snapshot.ffmpegAvailable {
            return SettingsDependencyInlineModel(
                title: "ffmpeg",
                status: "Ready",
                detail: "Installed for HLS streams and video processing",
                command: nil,
                tone: .success,
                isReady: true,
                isChecking: false
            )
        } else {
            return SettingsDependencyInlineModel(
                title: "ffmpeg",
                status: "Missing",
                detail: "Missing. Install it for HLS streams and post-processing.",
                command: "brew install ffmpeg",
                tone: .warning,
                isReady: false,
                isChecking: false
            )
        }
    }
}
