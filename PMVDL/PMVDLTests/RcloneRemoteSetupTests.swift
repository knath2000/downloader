import XCTest
@testable import VidDL

private struct FakeRcloneSetupRunner: RcloneRemoteSetupRunning {
    var available = true
    var existing = false
    var verify = true
    var verifySFTP = true
    var createResult = SubprocessResult(exitStatus: 0, stdout: "Configuration complete.", stderr: "")
    var reconnectResult = SubprocessResult(exitStatus: 0, stdout: "Got code", stderr: "")
    var sftpCreateResult = SubprocessResult(exitStatus: 0, stdout: "SFTP configured", stderr: "")

    func isRcloneAvailable() -> Bool {
        available
    }

    func remoteExists(named remoteName: String) async -> Bool {
        existing
    }

    func createGoogleDriveRemote(named remoteName: String, output: @escaping (String) -> Void) async throws -> SubprocessResult {
        output(createResult.stdout)
        return createResult
    }

    func reconnectGoogleDriveRemote(named remoteName: String, output: @escaping (String) -> Void) async throws -> SubprocessResult {
        output(reconnectResult.stdout)
        return reconnectResult
    }

    func createSFTPRemote(input: RcloneSFTPSetupInput, output: @escaping (String) -> Void) async throws -> SubprocessResult {
        output(sftpCreateResult.stdout)
        return sftpCreateResult
    }

    func verifyRemote(named remoteName: String) async -> Bool {
        verify
    }

    func verifySFTPRemote(named remoteName: String, path: String) async -> Bool {
        verifySFTP
    }
}

final class RcloneRemoteSetupTests: XCTestCase {
    func testGoogleDriveCreateCommand() {
        XCTAssertEqual(
            RcloneRemoteSetupCommandBuilder.googleDriveCreateArguments(remoteName: "gdrive"),
            ["config", "create", "gdrive", "drive", "scope", "drive"]
        )
    }

    func testGoogleDriveReconnectCommand() {
        XCTAssertEqual(
            RcloneRemoteSetupCommandBuilder.googleDriveReconnectArguments(remoteName: "gdrive"),
            ["config", "reconnect", "gdrive:"]
        )
    }

    func testSFTPKeyCreateCommand() {
        let input = RcloneSFTPSetupInput(
            remoteName: "server",
            host: "1.2.3.4",
            port: "22",
            username: "root",
            authMode: .key,
            keyFile: "/Users/me/.ssh/id_ed25519",
            password: "",
            rootPath: "/downloads"
        )

        XCTAssertEqual(
            RcloneRemoteSetupCommandBuilder.sftpCreateArguments(input: input),
            ["config", "create", "server", "sftp", "host", "1.2.3.4", "user", "root", "port", "22", "key_file", "/Users/me/.ssh/id_ed25519"]
        )
    }

    func testSFTPPasswordCreateCommandObscuresPassword() {
        let input = RcloneSFTPSetupInput(
            remoteName: "server",
            host: "box.example.com",
            port: "",
            username: "user",
            authMode: .password,
            keyFile: "",
            password: "secret",
            rootPath: "/"
        )

        XCTAssertEqual(
            RcloneRemoteSetupCommandBuilder.sftpCreateArguments(input: input),
            ["config", "create", "server", "sftp", "host", "box.example.com", "user", "user", "port", "22", "pass", "secret", "--obscure"]
        )
    }

    func testSFTPVerifyCommandUsesAbsoluteRemoteRoot() {
        XCTAssertEqual(
            RcloneRemoteSetupCommandBuilder.sftpVerifyArguments(remoteName: "server", path: "/"),
            ["lsjson", "server:/", "--max-depth", "1"]
        )
    }

    func testOutputParserRecognizesOAuthWaiting() {
        XCTAssertEqual(
            RcloneRemoteSetupOutputParser.progressMessage(from: "Waiting for code..."),
            "Waiting for Google authorization..."
        )
    }

    func testOutputParserRecognizesBrowserAuth() {
        XCTAssertEqual(
            RcloneRemoteSetupOutputParser.progressMessage(from: "If your browser doesn't open automatically go to http://127.0.0.1:53682/auth"),
            "Browser sign-in is open. Finish Google authorization to continue."
        )
    }

    @MainActor
    func testMissingRcloneMovesToMissingState() {
        let model = RcloneRemoteSetupViewModel(runner: FakeRcloneSetupRunner(available: false))
        model.refresh(remoteName: "gdrive")
        XCTAssertEqual(model.phase, .missingRclone)
    }

    @MainActor
    func testUseExistingRemoteConfiguresWhenVerified() async {
        let model = RcloneRemoteSetupViewModel(runner: FakeRcloneSetupRunner(existing: true, verify: true))
        var configuredName: String?

        model.useExisting(remoteName: "gdrive") { configuredName = $0 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.phase, .configured)
        XCTAssertEqual(configuredName, "gdrive")
    }

    @MainActor
    func testCreateFailureDoesNotConfigure() async {
        let model = RcloneRemoteSetupViewModel(runner: FakeRcloneSetupRunner(
            createResult: SubprocessResult(exitStatus: 1, stdout: "", stderr: "bad auth")
        ))
        var configuredName: String?

        model.startGoogleDriveSetup(remoteName: "gdrive") { configuredName = $0 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        if case .failed(let message) = model.phase {
            XCTAssertTrue(message.contains("bad auth"))
        } else {
            XCTFail("Expected failed phase")
        }
        XCTAssertNil(configuredName)
    }

    @MainActor
    func testCreateSFTPSuccessConfiguresRemoteAtRootBeforeFolderSelection() async {
        let model = RcloneRemoteSetupViewModel(runner: FakeRcloneSetupRunner())
        let input = RcloneSFTPSetupInput(
            remoteName: "server",
            host: "1.2.3.4",
            port: "22",
            username: "root",
            authMode: .key,
            keyFile: "/Users/me/.ssh/id_ed25519",
            password: "",
            rootPath: "/media/uploads"
        )
        var configured: (name: String, path: String)?

        model.startSFTPSetup(input: input) { name, path in configured = (name, path) }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.phase, .configured)
        XCTAssertEqual(configured?.name, "server")
        XCTAssertEqual(configured?.path, "/")
    }

    @MainActor
    func testCreateSFTPRootVerifyFailureDoesNotConfigure() async {
        let model = RcloneRemoteSetupViewModel(runner: FakeRcloneSetupRunner(verifySFTP: false))
        let input = RcloneSFTPSetupInput(
            remoteName: "server",
            host: "1.2.3.4",
            port: "22",
            username: "root",
            authMode: .password,
            keyFile: "",
            password: "secret",
            rootPath: "/missing"
        )
        var configured: (name: String, path: String)?

        model.startSFTPSetup(input: input) { name, path in configured = (name, path) }
        try? await Task.sleep(nanoseconds: 50_000_000)

        if case .failed(let message) = model.phase {
            XCTAssertTrue(message.contains("could not list the server root"))
        } else {
            XCTFail("Expected failed phase")
        }
        XCTAssertNil(configured)
    }
}
