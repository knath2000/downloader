import XCTest
@testable import VidDL

final class NavigationGateTests: XCTestCase {
    func testRemainingDestinationsAreHomeFeedLibraryAndSettings() {
        XCTAssertEqual(NavDestination.allCases, [.home, .feed, .library, .settings])
    }

    func testOnlyFeedRequiresPro() {
        XCTAssertTrue(NavDestination.feed.requiresPro)
        XCTAssertFalse(NavDestination.home.requiresPro)
        XCTAssertFalse(NavDestination.library.requiresPro)
        XCTAssertFalse(NavDestination.settings.requiresPro)
    }

    func testPersonalLicenseCodeHashIsStable() {
        XCTAssertEqual(
            PersonalLicenseCode.hash("VIDDL-LOCAL-test"),
            PersonalLicenseCode.hash(" VIDDL-LOCAL-test ")
        )
    }

    func testPersonalLicenseCodeGenerationUsesLocalPrefix() {
        XCTAssertTrue(PersonalLicenseCode.generate().hasPrefix("VIDDL-LOCAL-"))
    }
}
