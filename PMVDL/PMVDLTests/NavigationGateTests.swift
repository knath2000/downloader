import XCTest
@testable import VidDL

final class NavigationGateTests: XCTestCase {
    func testFeedFavoritesAndProfileRequirePro() {
        XCTAssertTrue(NavDestination.feed.requiresPro)
        XCTAssertTrue(NavDestination.favorites.requiresPro)
        XCTAssertTrue(NavDestination.profile.requiresPro)
    }

    func testCoreDestinationsRemainFree() {
        XCTAssertFalse(NavDestination.home.requiresPro)
        XCTAssertFalse(NavDestination.library.requiresPro)
        XCTAssertFalse(NavDestination.files.requiresPro)
        XCTAssertFalse(NavDestination.settings.requiresPro)
    }
}
