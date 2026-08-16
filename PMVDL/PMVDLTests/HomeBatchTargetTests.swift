import XCTest
@testable import VidDL

final class HomeBatchTargetTests: XCTestCase {
    func testBatchButtonTitlesMatchTargets() {
        XCTAssertEqual(CloudTarget.local.homeBatchButtonTitle, "Download All to Local")
        XCTAssertEqual(CloudTarget.mega.homeBatchButtonTitle, "Send All to Mega")
        XCTAssertEqual(CloudTarget.gdrive.homeBatchButtonTitle, "Send All to GDrive")
        XCTAssertEqual(CloudTarget.seedbox.homeBatchButtonTitle, "Send All to Seedbox")
    }

    func testSingleResultActionTitlesMatchTargets() {
        XCTAssertEqual(CloudTarget.local.homeActionTitle, "Download")
        XCTAssertEqual(CloudTarget.mega.homeActionTitle, "Send to Mega")
        XCTAssertEqual(CloudTarget.gdrive.homeActionTitle, "Send to GDrive")
        XCTAssertEqual(CloudTarget.seedbox.homeActionTitle, "Send to Seedbox")
    }

    func testOnlyLocalAndGoogleDriveAcceptNewJobs() {
        XCTAssertEqual(DestinationAvailabilityPolicy.newJobTargets, [.local, .gdrive])
        XCTAssertTrue(DestinationAvailabilityPolicy.canCreateNewJob(for: .local))
        XCTAssertTrue(DestinationAvailabilityPolicy.canCreateNewJob(for: .gdrive))
        XCTAssertFalse(DestinationAvailabilityPolicy.canCreateNewJob(for: .mega))
        XCTAssertFalse(DestinationAvailabilityPolicy.canCreateNewJob(for: .seedbox))
    }
}
