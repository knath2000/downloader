import XCTest
@testable import VidDL

// MARK: - Fake checker

private struct FakeDependencyChecker: SettingsDependencyChecking {
    let snapshots: [SettingsDependencyInput: SettingsDependencySnapshot]

    func snapshot(for input: SettingsDependencyInput) async -> SettingsDependencySnapshot {
        snapshots[input] ?? SettingsDependencySnapshot(
            megaAvailable: false,
            megaLoggedIn: false,
            gdriveAvailable: false,
            gdriveConfigured: false,
            seedboxRcloneAvailable: false,
            seedboxRcloneConfigured: false,
            ytDlpAvailable: false,
            ffmpegAvailable: false
        )
    }
}

// MARK: - Tests

final class SettingsDependencyStateTests: XCTestCase {

    // MARK: Presenter — nil snapshot → Checking

    func testNilSnapshotPresentsCheckingInsteadOfMissing() {
        let input = SettingsDependencyInput(
            gdriveRemoteName: "gdrive",
            seedboxTransferMode: "rclone",
            seedboxRemoteName: "seedbox",
            seedboxWebdavURL: ""
        )

        let model = SettingsDependencyPresenter.model(snapshot: nil, input: input)

        XCTAssertEqual(model.mega.status,    "Checking")
        XCTAssertEqual(model.gdrive.status,  "Checking")
        XCTAssertEqual(model.seedbox.status, "Checking")
        XCTAssertEqual(model.ytDlp.status,   "Checking")
        XCTAssertEqual(model.ffmpeg.status,  "Checking")

        // No actionable install commands in checking state
        XCTAssertNil(model.mega.command)
        XCTAssertNil(model.gdrive.command)
        XCTAssertNil(model.seedbox.command)
        XCTAssertNil(model.ytDlp.command)
        XCTAssertNil(model.ffmpeg.command)

        // All marked as checking
        XCTAssertTrue(model.mega.isChecking)
        XCTAssertTrue(model.gdrive.isChecking)
        XCTAssertTrue(model.seedbox.isChecking)
        XCTAssertTrue(model.ytDlp.isChecking)
        XCTAssertTrue(model.ffmpeg.isChecking)

        // None marked ready
        XCTAssertFalse(model.mega.isReady)
        XCTAssertFalse(model.gdrive.isReady)
        XCTAssertFalse(model.seedbox.isReady)
        XCTAssertFalse(model.ytDlp.isReady)
        XCTAssertFalse(model.ffmpeg.isReady)
    }

    // MARK: Presenter — ready snapshot

    func testReadySnapshotPresentsReadyStates() {
        let input = SettingsDependencyInput(
            gdriveRemoteName: "gdrive",
            seedboxTransferMode: "rclone",
            seedboxRemoteName: "seedbox",
            seedboxWebdavURL: ""
        )
        let snapshot = SettingsDependencySnapshot(
            megaAvailable: true,
            megaLoggedIn: true,
            gdriveAvailable: true,
            gdriveConfigured: true,
            seedboxRcloneAvailable: true,
            seedboxRcloneConfigured: true,
            ytDlpAvailable: true,
            ffmpegAvailable: true
        )

        let model = SettingsDependencyPresenter.model(snapshot: snapshot, input: input)

        XCTAssertEqual(model.mega.status,    "Ready")
        XCTAssertEqual(model.gdrive.status,  "Configured")
        XCTAssertEqual(model.seedbox.status, "Configured")
        XCTAssertEqual(model.ytDlp.status,   "Ready")
        XCTAssertEqual(model.ffmpeg.status,  "Ready")
        XCTAssertEqual(model.seedbox.title, "Remote server is ready")

        XCTAssertTrue(model.mega.isReady)
        XCTAssertTrue(model.gdrive.isReady)
        XCTAssertTrue(model.seedbox.isReady)
        XCTAssertTrue(model.ytDlp.isReady)
        XCTAssertTrue(model.ffmpeg.isReady)

        XCTAssertFalse(model.mega.isChecking)
        XCTAssertFalse(model.gdrive.isChecking)
        XCTAssertFalse(model.seedbox.isChecking)

        // No install commands when ready
        XCTAssertNil(model.mega.command)
        XCTAssertNil(model.gdrive.command)
        XCTAssertNil(model.seedbox.command)
        XCTAssertNil(model.ytDlp.command)
        XCTAssertNil(model.ffmpeg.command)
    }

    // MARK: Presenter — all-missing snapshot after real check

    func testMissingSnapshotPresentsActionableCommandsOnlyAfterRealCheck() {
        let input = SettingsDependencyInput(
            gdriveRemoteName: "gdrive",
            seedboxTransferMode: "rclone",
            seedboxRemoteName: "seedbox",
            seedboxWebdavURL: ""
        )
        let snapshot = SettingsDependencySnapshot(
            megaAvailable: false,
            megaLoggedIn: false,
            gdriveAvailable: false,
            gdriveConfigured: false,
            seedboxRcloneAvailable: false,
            seedboxRcloneConfigured: false,
            ytDlpAvailable: false,
            ffmpegAvailable: false
        )

        let model = SettingsDependencyPresenter.model(snapshot: snapshot, input: input)

        XCTAssertEqual(model.mega.status,    "Missing")
        XCTAssertEqual(model.gdrive.status,  "Missing")
        XCTAssertEqual(model.seedbox.status, "Missing")
        XCTAssertEqual(model.ytDlp.status,   "Missing")
        XCTAssertEqual(model.ffmpeg.status,  "Missing")

        XCTAssertEqual(model.gdrive.command, "brew install rclone")
        XCTAssertEqual(model.seedbox.command, "brew install rclone")
        XCTAssertTrue(model.seedbox.detail.contains("Remote server transfers"))
        XCTAssertEqual(model.ytDlp.command,  "brew install yt-dlp")
        XCTAssertEqual(model.ffmpeg.command, "brew install ffmpeg")

        XCTAssertFalse(model.mega.isReady)
        XCTAssertFalse(model.gdrive.isReady)
        XCTAssertFalse(model.ytDlp.isReady)
        XCTAssertFalse(model.ffmpeg.isReady)
    }

    // MARK: Presenter — tones

    func testNilSnapshotHasCheckingTone() {
        let input = SettingsDependencyInput(
            gdriveRemoteName: "gdrive",
            seedboxTransferMode: "rclone",
            seedboxRemoteName: "seedbox",
            seedboxWebdavURL: ""
        )

        let model = SettingsDependencyPresenter.model(snapshot: nil, input: input)

        XCTAssertEqual(model.mega.tone,    .checking)
        XCTAssertEqual(model.gdrive.tone,  .checking)
        XCTAssertEqual(model.seedbox.tone, .checking)
        XCTAssertEqual(model.ytDlp.tone,   .checking)
        XCTAssertEqual(model.ffmpeg.tone,  .checking)
    }

    // MARK: Presenter — WebDAV seedbox

    func testWebdavSeedboxWithURLShowsConfigured() {
        let input = SettingsDependencyInput(
            gdriveRemoteName: "gdrive",
            seedboxTransferMode: "webdav",
            seedboxRemoteName: "seedbox",
            seedboxWebdavURL: "https://box.example.com"
        )

        let model = SettingsDependencyPresenter.model(
            snapshot: SettingsDependencySnapshot(
                megaAvailable: false, megaLoggedIn: false,
                gdriveAvailable: false, gdriveConfigured: false,
                seedboxRcloneAvailable: false, seedboxRcloneConfigured: false,
                ytDlpAvailable: false, ffmpegAvailable: false
            ),
            input: input
        )

        XCTAssertEqual(model.seedbox.status, "Configured")
        XCTAssertTrue(model.seedbox.isReady)
    }

    func testWebdavSeedboxWithoutURLShowsMissingURL() {
        let input = SettingsDependencyInput(
            gdriveRemoteName: "gdrive",
            seedboxTransferMode: "webdav",
            seedboxRemoteName: "seedbox",
            seedboxWebdavURL: ""
        )

        let model = SettingsDependencyPresenter.model(
            snapshot: SettingsDependencySnapshot(
                megaAvailable: false, megaLoggedIn: false,
                gdriveAvailable: false, gdriveConfigured: false,
                seedboxRcloneAvailable: false, seedboxRcloneConfigured: false,
                ytDlpAvailable: false, ffmpegAvailable: false
            ),
            input: input
        )

        XCTAssertEqual(model.seedbox.status, "Missing URL")
        XCTAssertFalse(model.seedbox.isReady)
        XCTAssertNil(model.seedbox.command)
    }

    // MARK: Store — persistence across tab switches

    @MainActor
    func testStorePersistsSnapshotAcrossConsumers() async {
        let input = SettingsDependencyInput(
            gdriveRemoteName: "gdrive",
            seedboxTransferMode: "rclone",
            seedboxRemoteName: "seedbox",
            seedboxWebdavURL: ""
        )
        let ready = SettingsDependencySnapshot(
            megaAvailable: true,
            megaLoggedIn: true,
            gdriveAvailable: true,
            gdriveConfigured: true,
            seedboxRcloneAvailable: true,
            seedboxRcloneConfigured: true,
            ytDlpAvailable: true,
            ffmpegAvailable: true
        )
        let store = SettingsDependencyStore(checker: FakeDependencyChecker(snapshots: [input: ready]))

        await store.refresh(input: input, force: true)

        XCTAssertEqual(store.snapshot, ready)
        XCTAssertEqual(store.lastInput, input)

        // Simulates switching away and back: a new SettingsView observes the same shared store
        // and receives this snapshot immediately, never showing false-default "Missing" cards.
        XCTAssertNotNil(store.snapshot)
        XCTAssertFalse(store.isRefreshing)
    }

    @MainActor
    func testStoreSkipsRedundantCheckWhenInputAndSnapshotUnchanged() async {
        let input = SettingsDependencyInput(
            gdriveRemoteName: "gdrive",
            seedboxTransferMode: "rclone",
            seedboxRemoteName: "seedbox",
            seedboxWebdavURL: ""
        )
        let snapshot = SettingsDependencySnapshot(
            megaAvailable: true,
            megaLoggedIn: true,
            gdriveAvailable: true,
            gdriveConfigured: true,
            seedboxRcloneAvailable: true,
            seedboxRcloneConfigured: true,
            ytDlpAvailable: true,
            ffmpegAvailable: true
        )

        var callCount = 0
        struct CountingChecker: SettingsDependencyChecking {
            let base: SettingsDependencySnapshot
            let counter: (SettingsDependencyInput) -> Void
            func snapshot(for input: SettingsDependencyInput) async -> SettingsDependencySnapshot {
                counter(input)
                return base
            }
        }

        let store = SettingsDependencyStore(
            checker: CountingChecker(base: snapshot) { _ in callCount += 1 }
        )

        await store.refresh(input: input, force: false)   // runs (no snapshot yet)
        let firstCount = callCount
        await store.refresh(input: input, force: false)   // skipped (same input, snapshot exists)
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(callCount, 1, "Second refresh with identical input+snapshot should be skipped")
    }

    @MainActor
    func testStoreForceOverridesCache() async {
        let input = SettingsDependencyInput(
            gdriveRemoteName: "gdrive",
            seedboxTransferMode: "rclone",
            seedboxRemoteName: "seedbox",
            seedboxWebdavURL: ""
        )
        let snapshot = SettingsDependencySnapshot(
            megaAvailable: false, megaLoggedIn: false,
            gdriveAvailable: false, gdriveConfigured: false,
            seedboxRcloneAvailable: false, seedboxRcloneConfigured: false,
            ytDlpAvailable: false, ffmpegAvailable: false
        )

        var callCount = 0
        struct CountingChecker: SettingsDependencyChecking {
            let base: SettingsDependencySnapshot
            let counter: (SettingsDependencyInput) -> Void
            func snapshot(for input: SettingsDependencyInput) async -> SettingsDependencySnapshot {
                counter(input)
                return base
            }
        }

        let store = SettingsDependencyStore(
            checker: CountingChecker(base: snapshot) { _ in callCount += 1 }
        )

        await store.refresh(input: input)
        await store.refresh(input: input, force: true)  // force: true bypasses cache
        XCTAssertEqual(callCount, 2, "force: true should bypass the same-input cache")
    }
}
