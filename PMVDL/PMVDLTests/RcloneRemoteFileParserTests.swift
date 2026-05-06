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
}
