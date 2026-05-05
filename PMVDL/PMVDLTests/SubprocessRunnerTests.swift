import XCTest
@testable import VidDL

final class LockedText {
    private let lock = NSLock()
    private var value = ""

    func append(_ text: String) {
        lock.lock()
        value.append(text)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = value
        lock.unlock()
        return snapshot
    }
}

final class SubprocessRunnerTests: XCTestCase {
    func testRunCapturesStdoutAndStderr() async throws {
        let result = try await SubprocessRunner.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "echo stdout; echo stderr 1>&2"]
        )

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertTrue(result.stdout.contains("stdout"))
        XCTAssertTrue(result.stderr.contains("stderr"))
    }

    func testTimeoutTerminatesProcess() async throws {
        do {
            _ = try await SubprocessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: 0.1
            )
            XCTFail("Expected timeout")
        } catch SubprocessRunnerError.timedOut {
            XCTAssertTrue(true)
        }
    }

    func testStreamingHandlerReceivesOutput() async throws {
        let streamed = LockedText()
        let result = try await SubprocessRunner.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", "echo streamed"],
            stdoutHandler: { streamed.append($0) }
        )

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertTrue(streamed.string().contains("streamed"))
    }
}
