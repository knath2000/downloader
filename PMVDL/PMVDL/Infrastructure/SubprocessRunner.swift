import Foundation
import Darwin

struct SubprocessResult: Equatable {
    let exitStatus: Int32
    let stdout: String
    let stderr: String
}

enum SubprocessRunnerError: LocalizedError, Equatable {
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let timeout):
            return "Command timed out after \(Int(timeout)) seconds."
        }
    }
}

private final class SubprocessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ newData: Data) {
        lock.lock()
        data.append(newData)
        if data.count > limit {
            data.removeFirst(data.count - limit)
        }
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

final class RunningSubprocess: @unchecked Sendable {
    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let stdoutBuffer: SubprocessOutputBuffer
    private let stderrBuffer: SubprocessOutputBuffer
    private let stdoutHandler: ((String) -> Void)?
    private let stderrHandler: ((String) -> Void)?

    fileprivate init(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        stdoutBuffer: SubprocessOutputBuffer,
        stderrBuffer: SubprocessOutputBuffer,
        stdoutHandler: ((String) -> Void)?,
        stderrHandler: ((String) -> Void)?
    ) {
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.stdoutBuffer = stdoutBuffer
        self.stderrBuffer = stderrBuffer
        self.stdoutHandler = stdoutHandler
        self.stderrHandler = stderrHandler
    }

    var isRunning: Bool {
        process.isRunning
    }

    var terminationStatus: Int32 {
        process.terminationStatus
    }

    func wait(timeout: TimeInterval? = nil) async throws -> SubprocessResult {
        let started = Date()
        while process.isRunning {
            if Task.isCancelled {
                terminate(forceAfter: 1)
                throw CancellationError()
            }
            if let timeout, Date().timeIntervalSince(started) > timeout {
                terminate(forceAfter: 1)
                throw SubprocessRunnerError.timedOut(timeout)
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        drainAndClosePipes()
        return SubprocessResult(
            exitStatus: process.terminationStatus,
            stdout: stdoutBuffer.string(),
            stderr: stderrBuffer.string()
        )
    }

    func waitBlocking(timeout: TimeInterval? = nil) throws -> SubprocessResult {
        let started = Date()
        while process.isRunning {
            if let timeout, Date().timeIntervalSince(started) > timeout {
                terminate(forceAfter: 1)
                throw SubprocessRunnerError.timedOut(timeout)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        drainAndClosePipes()
        return SubprocessResult(
            exitStatus: process.terminationStatus,
            stdout: stdoutBuffer.string(),
            stderr: stderrBuffer.string()
        )
    }

    func terminate(forceAfter seconds: TimeInterval = 1) {
        guard process.isRunning else {
            drainAndClosePipes()
            return
        }

        process.terminate()
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }

        drainAndClosePipes()
    }

    private func drainAndClosePipes() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStdout.isEmpty {
            stdoutBuffer.append(remainingStdout)
        }

        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            stderrBuffer.append(remainingStderr)
        }
    }
}

enum SubprocessRunner {
    static let outputLimit = 1_048_576

    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval? = nil,
        stdin: Data? = nil,
        environment: [String: String]? = nil,
        stdoutHandler: ((String) -> Void)? = nil,
        stderrHandler: ((String) -> Void)? = nil
    ) async throws -> SubprocessResult {
        let running = try start(
            executable: executable,
            arguments: arguments,
            stdin: stdin,
            environment: environment,
            stdoutHandler: stdoutHandler,
            stderrHandler: stderrHandler
        )
        return try await running.wait(timeout: timeout)
    }

    @discardableResult
    static func runBlocking(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval? = nil,
        stdin: Data? = nil,
        environment: [String: String]? = nil,
        stdoutHandler: ((String) -> Void)? = nil,
        stderrHandler: ((String) -> Void)? = nil
    ) throws -> SubprocessResult {
        let running = try start(
            executable: executable,
            arguments: arguments,
            stdin: stdin,
            environment: environment,
            stdoutHandler: stdoutHandler,
            stderrHandler: stderrHandler
        )
        return try running.waitBlocking(timeout: timeout)
    }

    @discardableResult
    static func start(
        executable: URL,
        arguments: [String],
        stdin: Data? = nil,
        environment: [String: String]? = nil,
        stdoutHandler: ((String) -> Void)? = nil,
        stderrHandler: ((String) -> Void)? = nil
    ) throws -> RunningSubprocess {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBuffer = SubprocessOutputBuffer(limit: outputLimit)
        let stderrBuffer = SubprocessOutputBuffer(limit: outputLimit)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stdoutBuffer.append(data)
            if let chunk = String(data: data, encoding: .utf8) {
                stdoutHandler?(chunk)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.append(data)
            if let chunk = String(data: data, encoding: .utf8) {
                stderrHandler?(chunk)
            }
        }

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }
        try process.run()
        if let stdin, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(stdin)
            stdinPipe.fileHandleForWriting.closeFile()
        }

        return RunningSubprocess(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            stdoutBuffer: stdoutBuffer,
            stderrBuffer: stderrBuffer,
            stdoutHandler: stdoutHandler,
            stderrHandler: stderrHandler
        )
    }
}
