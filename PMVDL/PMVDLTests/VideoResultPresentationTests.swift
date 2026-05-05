import XCTest
@testable import VidDL

final class VideoResultPresentationTests: XCTestCase {
    func testMP4SourceProducesMP4Choice() {
        let source = VideoSource(mp4: "https://cdn.example.test/video.mp4", hls: [], title: "Example")
        let presentation = VideoResultPresentation(result: ExtractResult(url: "https://example.test/watch", source: source, error: nil))

        XCTAssertEqual(presentation.title, "Example")
        XCTAssertEqual(presentation.qualities.count, 1)
        XCTAssertEqual(presentation.qualities.first?.label, "MP4")
        XCTAssertEqual(presentation.recommendedQualityID, "https://cdn.example.test/video.mp4")
    }

    func testHLSLabelsArePreserved() {
        let source = VideoSource(
            mp4: nil,
            hls: [
                VideoSource.Quality(label: "2160p", url: "https://cdn.example.test/2160.m3u8"),
                VideoSource.Quality(label: "1080p", url: "https://cdn.example.test/1080.m3u8")
            ],
            title: "Example",
            thumbnail: "https://cdn.example.test/thumb.jpg"
        )
        let presentation = VideoResultPresentation(result: ExtractResult(url: "https://example.test/watch", source: source, error: nil))

        XCTAssertEqual(presentation.thumbnailURL, "https://cdn.example.test/thumb.jpg")
        XCTAssertEqual(presentation.qualities.map(\.label), ["2160p", "1080p"])
    }

    func testUntitledSourceFallsBack() {
        let source = VideoSource(mp4: nil, hls: [], title: " ")
        let presentation = VideoResultPresentation(result: ExtractResult(url: "https://example.test/watch", source: source, error: nil))

        XCTAssertEqual(presentation.title, "Untitled Video")
        XCTAssertTrue(presentation.qualities.isEmpty)
    }

    func testErrorResultHasNoQualities() {
        let presentation = VideoResultPresentation(result: ExtractResult(url: "https://example.test/watch", source: nil, error: "failed"))

        XCTAssertEqual(presentation.title, "Untitled Video")
        XCTAssertTrue(presentation.qualities.isEmpty)
    }
}
