import XCTest
@testable import VidDL

final class RemoteFileTextPolicyTests: XCTestCase {
    func testAllowsSmallKnownTextExtensions() {
        let item = RemoteFileItem(
            name: "notes.md",
            path: "/notes.md",
            kind: .file,
            size: 100
        )

        XCTAssertTrue(RemoteFileTextPolicy.isLikelyTextEditable(item))
    }

    func testRejectsFolders() {
        let item = RemoteFileItem(
            name: "folder",
            path: "/folder",
            kind: .folder
        )

        XCTAssertFalse(RemoteFileTextPolicy.isLikelyTextEditable(item))
    }

    func testRejectsLargeFiles() {
        let item = RemoteFileItem(
            name: "huge.txt",
            path: "/huge.txt",
            kind: .file,
            size: RemoteFileTextPolicy.maxEditableBytes + 1
        )

        XCTAssertFalse(RemoteFileTextPolicy.isLikelyTextEditable(item))
    }

    func testRejectsKnownVideoExtension() {
        let item = RemoteFileItem(
            name: "video.mp4",
            path: "/video.mp4",
            kind: .file,
            size: 100
        )

        XCTAssertFalse(RemoteFileTextPolicy.isLikelyTextEditable(item))
    }
}
