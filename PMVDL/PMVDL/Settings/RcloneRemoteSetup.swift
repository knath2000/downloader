import Combine
import Foundation

enum RcloneRemoteSetupPhase: Equatable {
    case idle
    case missingRclone
    case ready
    case existingRemote
    case authorizing
    case verifying
    case configured
    case failed(String)
}

enum RcloneSFTPAuthMode: String, CaseIterable, Identifiable {
    case key
    case password

    var id: String { rawValue }
}

struct RcloneSFTPSetupInput: Equatable {
    var remoteName: String
    var host: String
    var port: String
    var username: String
    var authMode: RcloneSFTPAuthMode
    var keyFile: String
    var password: String
    var rootPath: String

    var resolvedRemoteName: String {
        let trimmed = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "server" : trimmed
    }

    var resolvedPort: String {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "22" : trimmed
    }

    var resolvedRootPath: String {
        RemotePath.normalizeDirectory(rootPath)
    }
}

struct RcloneRemoteSetupCommandBuilder {
    static func googleDriveCreateArguments(remoteName: String) -> [String] {
        ["config", "create", remoteName, "drive", "scope", "drive"]
    }

    static func googleDriveReconnectArguments(remoteName: String) -> [String] {
        ["config", "reconnect", "\(remoteName):"]
    }

    static func showArguments(remoteName: String) -> [String] {
        ["config", "show", remoteName]
    }

    static func sftpCreateArguments(input: RcloneSFTPSetupInput, obscuredPassword: String? = nil) -> [String] {
        var arguments = [
            "config", "create", input.resolvedRemoteName, "sftp",
            "host", input.host.trimmingCharacters(in: .whitespacesAndNewlines),
            "user", input.username.trimmingCharacters(in: .whitespacesAndNewlines),
            "port", input.resolvedPort
        ]

        switch input.authMode {
        case .key:
            arguments += ["key_file", input.keyFile.trimmingCharacters(in: .whitespacesAndNewlines)]
        case .password:
            if let obscuredPassword {
                arguments += ["pass", obscuredPassword]
            } else {
                arguments += ["pass", input.password, "--obscure"]
            }
        }

        return arguments
    }

    static func sftpVerifyArguments(remoteName: String, path: String = "/") -> [String] {
        ["lsjson", RemotePath.rcloneAbsolutePath(remoteName: remoteName, directory: path), "--max-depth", "1"]
    }
}

enum RcloneRemoteSetupOutputParser {
    static func progressMessage(from chunk: String) -> String? {
        let lower = chunk.lowercased()
        if lower.contains("http://127.0.0.1") || lower.contains("browser") || lower.contains("log in and authorize") {
            return "Browser sign-in is open. Finish Google authorization to continue."
        }
        if lower.contains("waiting for code") {
            return "Waiting for Google authorization..."
        }
        if lower.contains("got code") {
            return "Authorization received. Finishing rclone setup..."
        }
        if lower.contains("configuration complete") || lower.contains("keep this") {
            return "Google Drive remote configured. Verifying..."
        }
        if lower.contains("connection refused") {
            return "The server refused the SFTP connection."
        }
        if lower.contains("permission denied") || lower.contains("unable to authenticate") {
            return "SFTP authentication failed. Check the username and credential."
        }
        return nil
    }

    static func cleanedError(stdout: String, stderr: String) -> String {
        let combined = [stderr, stdout]
            .joined(separator: "\n")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(6)
            .joined(separator: "\n")
        return combined.isEmpty ? "rclone setup failed." : combined
    }
}

protocol RcloneRemoteSetupRunning {
    func isRcloneAvailable() -> Bool
    func remoteExists(named remoteName: String) async -> Bool
    func createGoogleDriveRemote(named remoteName: String, output: @escaping (String) -> Void) async throws -> SubprocessResult
    func reconnectGoogleDriveRemote(named remoteName: String, output: @escaping (String) -> Void) async throws -> SubprocessResult
    func createSFTPRemote(input: RcloneSFTPSetupInput, output: @escaping (String) -> Void) async throws -> SubprocessResult
    func verifyRemote(named remoteName: String) async -> Bool
    func verifySFTPRemote(named remoteName: String, path: String) async -> Bool
}

struct LiveRcloneRemoteSetupRunner: RcloneRemoteSetupRunning {
    func isRcloneAvailable() -> Bool {
        ToolLocator.find("rclone") != nil
    }

    func remoteExists(named remoteName: String) async -> Bool {
        await runShow(remoteName: remoteName)?.exitStatus == 0
    }

    func createGoogleDriveRemote(named remoteName: String, output: @escaping (String) -> Void) async throws -> SubprocessResult {
        guard let rclone = ToolLocator.find("rclone") else {
            return SubprocessResult(exitStatus: 127, stdout: "", stderr: "rclone is not installed.")
        }
        return try await SubprocessRunner.run(
            executable: rclone,
            arguments: RcloneRemoteSetupCommandBuilder.googleDriveCreateArguments(remoteName: remoteName),
            timeout: 600,
            stdoutHandler: output,
            stderrHandler: output
        )
    }

    func reconnectGoogleDriveRemote(named remoteName: String, output: @escaping (String) -> Void) async throws -> SubprocessResult {
        guard let rclone = ToolLocator.find("rclone") else {
            return SubprocessResult(exitStatus: 127, stdout: "", stderr: "rclone is not installed.")
        }
        return try await SubprocessRunner.run(
            executable: rclone,
            arguments: RcloneRemoteSetupCommandBuilder.googleDriveReconnectArguments(remoteName: remoteName),
            timeout: 600,
            stdoutHandler: output,
            stderrHandler: output
        )
    }

    func createSFTPRemote(input: RcloneSFTPSetupInput, output: @escaping (String) -> Void) async throws -> SubprocessResult {
        guard let rclone = ToolLocator.find("rclone") else {
            return SubprocessResult(exitStatus: 127, stdout: "", stderr: "rclone is not installed.")
        }

        var obscuredPassword: String?
        if input.authMode == .password {
            let obscured = try await SubprocessRunner.run(
                executable: rclone,
                arguments: ["obscure", "-"],
                timeout: 30,
                stdin: Data((input.password + "\n").utf8)
            )
            guard obscured.exitStatus == 0 else {
                return SubprocessResult(exitStatus: obscured.exitStatus, stdout: "", stderr: "Could not secure the SFTP password.")
            }
            obscuredPassword = obscured.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return try await SubprocessRunner.run(
            executable: rclone,
            arguments: RcloneRemoteSetupCommandBuilder.sftpCreateArguments(input: input, obscuredPassword: obscuredPassword),
            timeout: 60,
            stdoutHandler: output,
            stderrHandler: output
        )
    }

    func verifyRemote(named remoteName: String) async -> Bool {
        await runShow(remoteName: remoteName)?.exitStatus == 0
    }

    func verifySFTPRemote(named remoteName: String, path: String) async -> Bool {
        guard let rclone = ToolLocator.find("rclone") else { return false }
        let result = try? await SubprocessRunner.run(
            executable: rclone,
            arguments: RcloneRemoteSetupCommandBuilder.sftpVerifyArguments(remoteName: remoteName, path: path),
            timeout: 20
        )
        return result?.exitStatus == 0
    }

    private func runShow(remoteName: String) async -> SubprocessResult? {
        guard let rclone = ToolLocator.find("rclone") else { return nil }
        return try? await SubprocessRunner.run(
            executable: rclone,
            arguments: RcloneRemoteSetupCommandBuilder.showArguments(remoteName: remoteName),
            timeout: 8
        )
    }
}

@MainActor
final class RcloneRemoteSetupViewModel: ObservableObject {
    @Published private(set) var phase: RcloneRemoteSetupPhase = .idle
    @Published private(set) var progressMessage = "Ready to set up Google Drive."
    @Published private(set) var isRunning = false

    private let runner: RcloneRemoteSetupRunning
    private var setupTask: Task<Void, Never>?

    init(runner: RcloneRemoteSetupRunning = LiveRcloneRemoteSetupRunner()) {
        self.runner = runner
    }

    deinit {
        setupTask?.cancel()
    }

    func refresh(remoteName: String) {
        guard !isRunning else { return }
        setupTask?.cancel()
        let name = resolvedRemoteName(remoteName)
        guard runner.isRcloneAvailable() else {
            phase = .missingRclone
            progressMessage = "Install rclone before connecting Google Drive."
            return
        }

        phase = .ready
        progressMessage = "Ready to connect \(name)."
        setupTask = Task { [weak self] in
            guard let self else { return }
            let exists = await self.runner.remoteExists(named: name)
            guard !Task.isCancelled else { return }
            self.phase = exists ? .existingRemote : .ready
            self.progressMessage = exists ? "A remote named \(name) already exists." : "Ready to connect \(name)."
        }
    }

    func startGoogleDriveSetup(remoteName: String, onConfigured: @escaping (String) -> Void) {
        beginSetup(remoteName: remoteName, reconnect: false, onConfigured: onConfigured)
    }

    func startSFTPSetup(input: RcloneSFTPSetupInput, onConfigured: @escaping (String, String) -> Void) {
        let name = input.resolvedRemoteName
        setupTask?.cancel()

        guard runner.isRcloneAvailable() else {
            phase = .missingRclone
            progressMessage = "Install rclone before connecting a remote server."
            return
        }

        guard validateSFTPInput(input) else { return }

        isRunning = true
        phase = .authorizing
        progressMessage = "Connecting \(name) over SFTP..."

        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output: (String) -> Void = { [weak self] chunk in
                    guard let message = RcloneRemoteSetupOutputParser.progressMessage(from: chunk) else { return }
                    Task { @MainActor in
                        self?.progressMessage = message
                    }
                }

                let result = try await self.runner.createSFTPRemote(input: input, output: output)
                guard !Task.isCancelled else { return }
                guard result.exitStatus == 0 else {
                    self.isRunning = false
                    self.phase = .failed(RcloneRemoteSetupOutputParser.cleanedError(stdout: result.stdout, stderr: result.stderr))
                    self.progressMessage = "Remote server setup failed."
                    return
                }

                self.phase = .verifying
                self.progressMessage = "Verifying \(name)..."
                let verified = await self.runner.verifySFTPRemote(named: name, path: "/")
                guard !Task.isCancelled else { return }
                self.isRunning = false

                if verified {
                    self.phase = .configured
                    self.progressMessage = "Remote server \(name) is ready. Choose an upload folder."
                    onConfigured(name, "/")
                } else {
                    self.phase = .failed("rclone saved \(name), but VidDL could not list the server root. Check the user permissions or choose a user with SFTP directory access.")
                    self.progressMessage = "Verification failed."
                }
            } catch is CancellationError {
                self.isRunning = false
                self.phase = .ready
                self.progressMessage = "Setup cancelled."
            } catch {
                self.isRunning = false
                self.phase = .failed(error.localizedDescription)
                self.progressMessage = "Remote server setup failed."
            }
        }
    }

    func reconnectGoogleDrive(remoteName: String, onConfigured: @escaping (String) -> Void) {
        beginSetup(remoteName: remoteName, reconnect: true, onConfigured: onConfigured)
    }

    func useExisting(remoteName: String, onConfigured: @escaping (String) -> Void) {
        let name = resolvedRemoteName(remoteName)
        setupTask?.cancel()
        isRunning = true
        phase = .verifying
        progressMessage = "Verifying \(name)..."
        setupTask = Task { [weak self] in
            guard let self else { return }
            let verified = await self.runner.verifyRemote(named: name)
            guard !Task.isCancelled else { return }
            self.isRunning = false
            if verified {
                self.phase = .configured
                self.progressMessage = "Google Drive remote \(name) is ready."
                onConfigured(name)
            } else {
                self.phase = .failed("Could not verify \(name). Reconnect it or choose another remote name.")
                self.progressMessage = "Verification failed."
            }
        }
    }

    func useExistingSFTP(remoteName: String, path: String, onConfigured: @escaping (String, String) -> Void) {
        let name = resolvedRemoteName(remoteName, fallback: "server")
        let remotePath = RemotePath.normalizeDirectory(path)
        setupTask?.cancel()
        isRunning = true
        phase = .verifying
        progressMessage = "Verifying \(name)..."
        setupTask = Task { [weak self] in
            guard let self else { return }
            let verified = await self.runner.verifySFTPRemote(named: name, path: remotePath)
            guard !Task.isCancelled else { return }
            self.isRunning = false
            if verified {
                self.phase = .configured
                self.progressMessage = "Remote server \(name) is ready."
                onConfigured(name, remotePath)
            } else {
                self.phase = .failed("Could not list \(remotePath) on \(name). Check the remote and path.")
                self.progressMessage = "Verification failed."
            }
        }
    }

    func cancel() {
        setupTask?.cancel()
        setupTask = nil
        isRunning = false
        phase = .ready
        progressMessage = "Setup cancelled."
    }

    func reset() {
        guard !isRunning else { return }
        phase = .idle
        progressMessage = "Ready to set up Google Drive."
    }

    private func beginSetup(remoteName: String, reconnect: Bool, onConfigured: @escaping (String) -> Void) {
        let name = resolvedRemoteName(remoteName)
        setupTask?.cancel()

        guard runner.isRcloneAvailable() else {
            phase = .missingRclone
            progressMessage = "Install rclone before connecting Google Drive."
            return
        }

        isRunning = true
        phase = .authorizing
        progressMessage = reconnect ? "Reconnecting \(name)..." : "Starting Google Drive sign-in..."

        setupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result: SubprocessResult
                let output: (String) -> Void = { [weak self] chunk in
                    guard let message = RcloneRemoteSetupOutputParser.progressMessage(from: chunk) else { return }
                    Task { @MainActor in
                        self?.progressMessage = message
                    }
                }

                if reconnect {
                    result = try await self.runner.reconnectGoogleDriveRemote(named: name, output: output)
                } else {
                    result = try await self.runner.createGoogleDriveRemote(named: name, output: output)
                }

                guard !Task.isCancelled else { return }
                guard result.exitStatus == 0 else {
                    self.isRunning = false
                    self.phase = .failed(RcloneRemoteSetupOutputParser.cleanedError(stdout: result.stdout, stderr: result.stderr))
                    self.progressMessage = "Google Drive setup failed."
                    return
                }

                self.phase = .verifying
                self.progressMessage = "Verifying \(name)..."
                let verified = await self.runner.verifyRemote(named: name)
                guard !Task.isCancelled else { return }
                self.isRunning = false

                if verified {
                    self.phase = .configured
                    self.progressMessage = "Google Drive remote \(name) is ready."
                    onConfigured(name)
                } else {
                    self.phase = .failed("rclone finished setup, but VidDL could not verify \(name).")
                    self.progressMessage = "Verification failed."
                }
            } catch is CancellationError {
                self.isRunning = false
                self.phase = .ready
                self.progressMessage = "Setup cancelled."
            } catch {
                self.isRunning = false
                self.phase = .failed(error.localizedDescription)
                self.progressMessage = "Google Drive setup failed."
            }
        }
    }

    private func resolvedRemoteName(_ remoteName: String) -> String {
        resolvedRemoteName(remoteName, fallback: "gdrive")
    }

    private func resolvedRemoteName(_ remoteName: String, fallback: String) -> String {
        let trimmed = remoteName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func validateSFTPInput(_ input: RcloneSFTPSetupInput) -> Bool {
        guard !input.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .failed("Enter the server host or IP address.")
            progressMessage = "Remote server setup failed."
            return false
        }
        guard !input.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .failed("Enter the SFTP username.")
            progressMessage = "Remote server setup failed."
            return false
        }
        guard Int(input.resolvedPort) != nil else {
            phase = .failed("Enter a numeric SFTP port.")
            progressMessage = "Remote server setup failed."
            return false
        }
        switch input.authMode {
        case .key:
            guard !input.keyFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                phase = .failed("Choose an SSH private key file.")
                progressMessage = "Remote server setup failed."
                return false
            }
        case .password:
            guard !input.password.isEmpty else {
                phase = .failed("Enter the SFTP password.")
                progressMessage = "Remote server setup failed."
                return false
            }
        }
        return true
    }
}
