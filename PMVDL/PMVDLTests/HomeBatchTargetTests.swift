import XCTest
@testable import VidDL

final class HomeBatchTargetTests: XCTestCase {
    func testBatchButtonTitlesMatchTargets() {
        XCTAssertEqual(CloudTarget.local.homeBatchButtonTitle, "Download All to Local")
        XCTAssertEqual(CloudTarget.mega.homeBatchButtonTitle, "Send All to Mega")
        XCTAssertEqual(CloudTarget.gdrive.homeBatchButtonTitle, "Destination Unavailable")
        XCTAssertEqual(CloudTarget.seedbox.homeBatchButtonTitle, "Destination Unavailable")
    }

    func testSingleResultActionTitlesMatchTargets() {
        XCTAssertEqual(CloudTarget.local.homeActionTitle, "Download")
        XCTAssertEqual(CloudTarget.mega.homeActionTitle, "Send to Mega")
        XCTAssertEqual(CloudTarget.gdrive.homeActionTitle, "Destination Unavailable")
        XCTAssertEqual(CloudTarget.seedbox.homeActionTitle, "Destination Unavailable")
    }

    func testOnlyLocalAndMegaAreOffered() {
        XCTAssertEqual(DestinationAvailabilityPolicy.newJobTargets, [.local, .mega])
        XCTAssertTrue(DestinationAvailabilityPolicy.canCreateNewJob(for: .local))
        XCTAssertFalse(DestinationAvailabilityPolicy.canCreateNewJob(for: .gdrive))
        XCTAssertFalse(DestinationAvailabilityPolicy.canCreateNewJob(for: .mega))
        XCTAssertFalse(DestinationAvailabilityPolicy.canCreateNewJob(for: .seedbox))
    }
}
