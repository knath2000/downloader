import XCTest
@testable import VidDL

final class ProgressParserTests: XCTestCase {
    func testFfmpegProgressParserUsesDuration() {
        let event = DownloadProgressParsers.ffmpegProgressEvent(
            from: "frame=1 fps=0 time=00:01:00.00 bitrate=1",
            totalDuration: 120
        )

        XCTAssertEqual(event?.phase, .downloading)
        XCTAssertEqual(event?.percent ?? 0, 50, accuracy: 0.1)
    }

    func testYtDlpProgressParser() {
        let message = DownloadProgressParsers.ytDlpProgressMessage(
            from: "[download]  25.0% of 10.00MiB at 1.00MiB/s ETA 00:08"
        )

        XCTAssertTrue(message?.contains("25.0%") == true)
    }

}
