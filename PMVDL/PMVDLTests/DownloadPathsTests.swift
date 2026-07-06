import XCTest
@testable import VidDL

final class DownloadPathsTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DownloadPaths.customDownloadDirectoryKey)
        super.tearDown()
    }

    func testDownloadDirDefaultsToVidDLDownloadsFolder() {
        UserDefaults.standard.removeObject(forKey: DownloadPaths.customDownloadDirectoryKey)

        XCTAssertEqual(DownloadPaths.downloadDir, DownloadPaths.defaultDownloadDir)
        XCTAssertFalse(DownloadPaths.hasCustomDownloadDir)
    }

    func testDownloadDirUsesCustomFolder() {
        let custom = URL(fileURLWithPath: "/tmp/viddl-custom-downloads", isDirectory: true)

        DownloadPaths.setCustomDownloadDir(custom)

        XCTAssertEqual(DownloadPaths.downloadDir.path, custom.path)
        XCTAssertTrue(DownloadPaths.hasCustomDownloadDir)
    }
}
