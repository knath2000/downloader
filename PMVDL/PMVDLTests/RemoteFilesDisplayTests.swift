import XCTest
@testable import VidDL

final class RemoteFilesDisplayTests: XCTestCase {
    func testFilteredAndSortedKeepsFoldersFirst() {
        let items = [
            item(name: "video.mp4", kind: .file, size: 10),
            item(name: "Archive", kind: .folder),
            item(name: "notes.txt", kind: .file, size: 5)
        ]

        let result = RemoteFilesDisplay.filteredAndSorted(
            items: items,
            query: "",
            sortMode: .name
        )

        XCTAssertEqual(result.map(\.name), ["Archive", "notes.txt", "video.mp4"])
    }

    func testSearchMatchesNamePathAndContentType() {
        let items = [
            item(
                name: "movie.mp4",
                path: "/data/movie.mp4",
                kind: .file,
                contentType: "video/mp4"
            ),
            item(
                name: "readme.md",
                path: "/docs/readme.md",
                kind: .file,
                contentType: "text/markdown"
            )
        ]

        XCTAssertEqual(
            RemoteFilesDisplay.filteredAndSorted(items: items, query: "docs", sortMode: .name).map(\.name),
            ["readme.md"]
        )

        XCTAssertEqual(
            RemoteFilesDisplay.filteredAndSorted(items: items, query: "video", sortMode: .name).map(\.name),
            ["movie.mp4"]
        )
    }

    func testSummaryCountsFoldersFilesAndBytes() {
        let summary = RemoteFilesDisplay.summary(for: [
            item(name: "a", kind: .folder),
            item(name: "b.mp4", kind: .file, size: 100),
            item(name: "c.mp4", kind: .file, size: 200)
        ])

        XCTAssertEqual(summary.folders, 1)
        XCTAssertEqual(summary.files, 2)
        XCTAssertEqual(summary.totalFileBytes, 300)
    }

    func testBreadcrumbParts() {
        XCTAssertEqual(RemoteFilesDisplay.breadcrumbParts(for: "/"), [])
        XCTAssertEqual(RemoteFilesDisplay.breadcrumbParts(for: "/data/Cloud"), ["data", "Cloud"])
        XCTAssertEqual(RemoteFilesDisplay.path(upTo: 0, in: ["data", "Cloud"]), "/data")
        XCTAssertEqual(RemoteFilesDisplay.path(upTo: 1, in: ["data", "Cloud"]), "/data/Cloud")
    }

    private func item(
        name: String,
        path: String? = nil,
        kind: RemoteFileKind,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        contentType: String? = nil
    ) -> RemoteFileItem {
        RemoteFileItem(
            name: name,
            path: path ?? "/\(name)",
            kind: kind,
            size: size,
            modifiedAt: modifiedAt,
            contentType: contentType
        )
    }
}
