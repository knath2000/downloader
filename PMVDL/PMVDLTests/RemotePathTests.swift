import XCTest
@testable import VidDL

final class RemotePathTests: XCTestCase {
    func testNormalizeDirectory() {
        XCTAssertEqual(RemotePath.normalizeDirectory(""), "/")
        XCTAssertEqual(RemotePath.normalizeDirectory("/"), "/")
        XCTAssertEqual(RemotePath.normalizeDirectory("downloads"), "/downloads")
        XCTAssertEqual(RemotePath.normalizeDirectory("/downloads/"), "/downloads")
        XCTAssertEqual(RemotePath.normalizeDirectory(" /a//b/ "), "/a/b")
    }

    func testJoiningSanitizesSlashInName() {
        XCTAssertEqual(RemotePath.joining(directory: "/", name: "movie.mp4"), "/movie.mp4")
        XCTAssertEqual(RemotePath.joining(directory: "/a/b", name: "new.txt"), "/a/b/new.txt")
        XCTAssertEqual(RemotePath.joining(directory: "/a", name: "bad/name.txt"), "/a/badname.txt")
    }

    func testParent() {
        XCTAssertEqual(RemotePath.parent(of: "/"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/a"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/a/b"), "/a")
    }

    func testRclonePathFormatting() {
        XCTAssertEqual(RemotePath.rclonePath(remoteName: "seedbox", directory: "/"), "seedbox:")
        XCTAssertEqual(RemotePath.rclonePath(remoteName: "seedbox", directory: "/downloads"), "seedbox:downloads/")
        XCTAssertEqual(RemotePath.rcloneFile(remoteName: "seedbox", path: "/downloads/a.mp4"), "seedbox:downloads/a.mp4")
    }
}
