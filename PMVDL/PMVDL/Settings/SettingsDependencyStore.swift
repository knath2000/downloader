import Foundation

// MARK: - Checker protocol

/// Abstraction over subprocess calls so the store can be tested without running mega/rclone.
protocol SettingsDependencyChecking: Sendable {
    func snapshot(for input: SettingsDependencyInput) async -> SettingsDependencySnapshot
}

// MARK: - Live checker

/// Runs real subprocess checks in a detached utility task off the main actor.
struct LiveSettingsDependencyChecker: SettingsDependencyChecking {
    func snapshot(for input: SettingsDependencyInput) async -> SettingsDependencySnapshot {
        let remoteName = input.resolvedGDriveRemoteName
        let seedboxRemoteName = input.resolvedSeedboxRemoteName
        return await Task.detached(priority: .utility) {
            let megaReady = MegaManager.isAvailable
            let rcloneReady = GDriveManager.isAvailable
            let seedboxRcloneReady = SeedboxManager.isRcloneAvailable
            return SettingsDependencySnapshot(
                megaAvailable: megaReady,
                megaLoggedIn: megaReady && MegaManager.isLoggedIn,
                gdriveAvailable: rcloneReady,
                gdriveConfigured: rcloneReady && GDriveManager.isConfigured(remoteName: remoteName),
                seedboxRcloneAvailable: seedboxRcloneReady,
                seedboxRcloneConfigured: seedboxRcloneReady && SeedboxManager.isRcloneConfigured(remoteName: seedboxRemoteName),
                ytDlpAvailable: ScraperEngine.isYTDLPAvailable,
                ffmpegAvailable: ScraperEngine.isFFmpegAvailable
            )
        }.value
    }
}

// MARK: - Store

/// Persistent, shared store for dependency-check results.
///
/// Lives across Settings tab switches so the UI always renders the *last known* snapshot
/// rather than uninitialized false-default booleans. A new SettingsView will immediately
/// observe a non-nil snapshot if checks have already run, eliminating the "Missing" flicker.
///
/// Refresh contract:
/// - Calling `refresh(input:force:)` while a check is already in flight queues the new
///   input as `pendingInput`. When the current check finishes it re-runs with the latest
///   input, ensuring settings changes made during a running check are never silently dropped.
/// - `snapshot` is never cleared to nil when refreshing — the UI shows the stale state
///   (plus the `isRefreshing` spinner) until the new snapshot arrives.
@MainActor
final class SettingsDependencyStore: ObservableObject {

    /// Singleton used by the production app.  Tests inject a fake checker via `init(checker:)`.
    static let shared = SettingsDependencyStore(checker: LiveSettingsDependencyChecker())

    // MARK: Published state

    /// Last completed check result.  nil only before the very first check finishes.
    @Published private(set) var snapshot: SettingsDependencySnapshot?

    /// True while a subprocess check is running.
    @Published private(set) var isRefreshing = false

    /// The input used for the most recently *started* refresh.
    @Published private(set) var lastInput: SettingsDependencyInput?

    // MARK: Private

    private let checker: SettingsDependencyChecking

    /// Input received while a check was already in flight.
    /// Processed immediately after the current check completes.
    private var pendingInput: SettingsDependencyInput?

    // MARK: Init

    init(checker: SettingsDependencyChecking) {
        self.checker = checker
    }

    // MARK: Public API

    /// Trigger a dependency check for `input`.
    ///
    /// - Parameters:
    ///   - input:  Current values of the settings fields that affect checks.
    ///   - force:  When `true`, re-runs even if `lastInput == input && snapshot != nil`.
    ///             Pass `true` from the Refresh Checks button and after testSeedboxConnection.
    func refresh(input: SettingsDependencyInput, force: Bool = false) async {
        if isRefreshing {
            // Don't launch a second check; remember the latest wanted input instead.
            pendingInput = input
            return
        }

        // Skip if nothing has changed and we already have a result.
        if !force, lastInput == input, snapshot != nil {
            return
        }

        isRefreshing = true
        lastInput = input

        let next = await checker.snapshot(for: input)
        snapshot = next
        isRefreshing = false

        // If a newer input arrived while we were checking, run it now.
        if let pending = pendingInput, pending != input {
            pendingInput = nil
            await refresh(input: pending, force: true)
        } else {
            pendingInput = nil
        }
    }
}
