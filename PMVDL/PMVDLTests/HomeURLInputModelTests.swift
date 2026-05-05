import XCTest
@testable import VidDL

final class HomeURLInputModelTests: XCTestCase {
    func testBlankInputHasNoURLs() {
        let model = HomeURLInputModel(rawText: " \n ")
        XCTAssertTrue(model.lines.isEmpty)
        XCTAssertTrue(model.validURLs.isEmpty)
        XCTAssertEqual(model.helperText, "Paste one video URL per line, or drag URLs here.")
    }

    func testTrimsAndCountsValidURLs() {
        let model = HomeURLInputModel(rawText: " https://pmvhaven.com/video/example \n\nhttps://youtu.be/abc ")
        XCTAssertEqual(model.validURLs, ["https://pmvhaven.com/video/example", "https://youtu.be/abc"])
        XCTAssertEqual(model.readyCount, 2)
        XCTAssertTrue(model.invalidLines.isEmpty)
    }

    func testInvalidLinesAreFlagged() {
        let model = HomeURLInputModel(rawText: "not a url\nhttps://pmvhaven.com/video/example")
        XCTAssertEqual(model.validURLs, ["https://pmvhaven.com/video/example"])
        XCTAssertEqual(model.invalidLines, ["not a url"])
        XCTAssertEqual(model.helperText, "1 line need attention.")
    }

    func testOnlyHttpAndHttpsURLsAreAccepted() {
        XCTAssertTrue(HomeURLInputModel.isLikelyURL("https://pmvhaven.com/video/example"))
        XCTAssertTrue(HomeURLInputModel.isLikelyURL("http://example.com/video"))
        XCTAssertFalse(HomeURLInputModel.isLikelyURL("file:///tmp/video.mp4"))
        XCTAssertFalse(HomeURLInputModel.isLikelyURL("example.com/video"))
    }
}
