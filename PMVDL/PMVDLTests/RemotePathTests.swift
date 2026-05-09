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

    func testDescendantDetection() {
        XCTAssertTrue(RemotePath.isDescendant("/a/b/c", of: "/a/b"))
        XCTAssertFalse(RemotePath.isDescendant("/a/b", of: "/a/b"))
        XCTAssertFalse(RemotePath.isDescendant("/a/b", of: "/"))
        XCTAssertFalse(RemotePath.isDescendant("/a/b-other", of: "/a/b"))
    }

    func testDuplicateNameGeneration() {
        XCTAssertEqual(
            RemotePath.duplicateName(for: "video.mp4", existingNames: ["video.mp4"]),
            "video copy.mp4"
        )
        XCTAssertEqual(
            RemotePath.duplicateName(for: "video.mp4", existingNames: ["video.mp4", "video copy.mp4"]),
            "video copy 2.mp4"
        )
        XCTAssertEqual(
            RemotePath.duplicateName(for: "Folder", existingNames: ["Folder", "Folder copy"]),
            "Folder copy 2"
        )
    }

    func testRclonePathFormatting() {
        XCTAssertEqual(RemotePath.rclonePath(remoteName: "seedbox", directory: "/"), "seedbox:")
        XCTAssertEqual(RemotePath.rclonePath(remoteName: "seedbox", directory: "/downloads"), "seedbox:downloads/")
        XCTAssertEqual(RemotePath.rcloneFile(remoteName: "seedbox", path: "/downloads/a.mp4"), "seedbox:downloads/a.mp4")
    }

    func testMovePlannerRejectsFolderIntoDescendant() {
        let folder = item(name: "Movies", path: "/Movies", kind: .folder)

        XCTAssertThrowsError(
            try RemoteFileOperationPlanner.movePlans(
                items: [folder],
                targetDirectory: "/Movies/Archive",
                existingTargetNames: []
            )
        )
    }

    func testMovePlannerRejectsCollisions() {
        let file = item(name: "video.mp4", path: "/Inbox/video.mp4", kind: .file)

        XCTAssertThrowsError(
            try RemoteFileOperationPlanner.movePlans(
                items: [file],
                targetDirectory: "/Archive",
                existingTargetNames: ["video.mp4"]
            )
        )
    }

    func testCopyPlannerUsesDuplicateNamesForSameFolder() throws {
        let file = item(name: "video.mp4", path: "/Inbox/video.mp4", kind: .file)

        let plans = try RemoteFileOperationPlanner.copyPlans(
            items: [file],
            targetDirectory: "/Inbox",
            existingTargetNames: ["video.mp4"]
        )

        XCTAssertEqual(plans.map(\.newName), ["video copy.mp4"])
    }

    func testSelectionReducerToggleRangeAndSelectAll() {
        let orderedIDs = ["a", "b", "c", "d"]
        var state = RemoteFileSelectionReducer.select(
            itemID: "b",
            orderedIDs: orderedIDs,
            state: RemoteFileSelectionState(),
            mode: .replace
        )

        state = RemoteFileSelectionReducer.select(
            itemID: "d",
            orderedIDs: orderedIDs,
            state: state,
            mode: .range
        )

        XCTAssertEqual(state.selectedIDs, Set(["b", "c", "d"]))

        state = RemoteFileSelectionReducer.select(
            itemID: "c",
            orderedIDs: orderedIDs,
            state: state,
            mode: .toggle
        )

        XCTAssertEqual(state.selectedIDs, Set(["b", "d"]))
        XCTAssertEqual(RemoteFileSelectionReducer.selectAll(orderedIDs: orderedIDs).selectedIDs, Set(orderedIDs))
    }

    private func item(name: String, path: String, kind: RemoteFileKind) -> RemoteFileItem {
        RemoteFileItem(name: name, path: path, kind: kind)
    }
}
