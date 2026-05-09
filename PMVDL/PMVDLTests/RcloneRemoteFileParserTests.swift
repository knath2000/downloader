import XCTest
@testable import VidDL

final class RcloneRemoteFileParserTests: XCTestCase {
    func testParseListJSONSortsFoldersBeforeFiles() throws {
        let json = """
        [
          {
            "Path": "video.mp4",
            "Name": "video.mp4",
            "Size": 1234,
            "MimeType": "video/mp4",
            "ModTime": "2026-05-05T12:00:00Z",
            "IsDir": false
          },
          {
            "Path": "Movies",
            "Name": "Movies",
            "Size": -1,
            "ModTime": "2026-05-05T11:00:00Z",
            "IsDir": true
          }
        ]
        """.data(using: .utf8)!

        let listing = try RcloneRemoteFileParser.parseListJSON(
            json,
            directory: "/downloads",
            provider: .seedbox
        )

        XCTAssertEqual(listing.path, "/downloads")
        XCTAssertEqual(listing.items.map(\.name), ["Movies", "video.mp4"])
        XCTAssertEqual(listing.items[0].kind, .folder)
        XCTAssertEqual(listing.items[1].kind, .file)
        XCTAssertEqual(listing.items[1].path, "/downloads/video.mp4")
        XCTAssertEqual(listing.items[1].size, 1234)
    }

    func testMoveBuildsMovetoCommand() async throws {
        let recorder = try makeRcloneRecorder()
        defer { unsetenv("VIDDL_RCLONE_ARGS") }

        let client = RcloneRemoteFileClient(
            provider: .seedbox,
            remoteName: "seedbox",
            rootPath: "/downloads",
            rclone: recorder.executable
        )

        try await client.move(
            itemAt: "/Inbox/video.mp4",
            kind: .file,
            toDirectory: "/Archive",
            newName: "video.mp4"
        )

        XCTAssertEqual(
            try recorder.arguments(),
            ["moveto", "seedbox:downloads/Inbox/video.mp4", "seedbox:downloads/Archive/video.mp4"]
        )
    }

    func testCopyFileBuildsCopytoCommand() async throws {
        let recorder = try makeRcloneRecorder()
        defer { unsetenv("VIDDL_RCLONE_ARGS") }

        let client = RcloneRemoteFileClient(
            provider: .seedbox,
            remoteName: "seedbox",
            rootPath: "/downloads",
            rclone: recorder.executable
        )

        try await client.copy(
            itemAt: "/Inbox/video.mp4",
            kind: .file,
            toDirectory: "/Archive",
            newName: "video copy.mp4"
        )

        XCTAssertEqual(
            try recorder.arguments(),
            ["copyto", "seedbox:downloads/Inbox/video.mp4", "seedbox:downloads/Archive/video copy.mp4"]
        )
    }

    func testCopyFolderPreservesEmptyDirectories() async throws {
        let recorder = try makeRcloneRecorder()
        defer { unsetenv("VIDDL_RCLONE_ARGS") }

        let client = RcloneRemoteFileClient(
            provider: .seedbox,
            remoteName: "seedbox",
            rootPath: "/downloads",
            rclone: recorder.executable
        )

        try await client.copy(
            itemAt: "/Inbox",
            kind: .folder,
            toDirectory: "/Archive",
            newName: "Inbox copy"
        )

        XCTAssertEqual(
            try recorder.arguments(),
            ["copy", "seedbox:downloads/Inbox", "seedbox:downloads/Archive/Inbox copy", "--create-empty-src-dirs"]
        )
    }

    private func makeRcloneRecorder() throws -> RcloneRecorder {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("viddl_rclone_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let executable = folder.appendingPathComponent("rclone")
        let output = folder.appendingPathComponent("args.txt")
        let script = """
        #!/bin/sh
        : > "$VIDDL_RCLONE_ARGS"
        for arg in "$@"; do
          printf '%s\\n' "$arg" >> "$VIDDL_RCLONE_ARGS"
        done
        exit 0
        """

        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        setenv("VIDDL_RCLONE_ARGS", output.path, 1)

        return RcloneRecorder(executable: executable, output: output)
    }
}

private struct RcloneRecorder {
    let executable: URL
    let output: URL

    func arguments() throws -> [String] {
        try String(contentsOf: output, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }
}
