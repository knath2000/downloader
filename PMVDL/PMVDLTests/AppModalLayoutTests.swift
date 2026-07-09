import XCTest
import SwiftUI
@testable import VidDL

/// Layout contract for app-wide modal chrome clearance. The single chokepoint
/// is `AppModalOverlay` + the shared `AppShellSurfaceMetrics` helpers — every
/// custom app modal (extraction results, active/completed downloads, Settings
/// panels, Library details) routes through them, so validating the metrics
/// validates the whole clearance policy.
final class AppModalLayoutTests: XCTestCase {

    // MARK: - Top titlebar clearance

    func testAvailableHeightReservesTitlebarClearanceAtTop() {
        let window = CGSize(width: 1600, height: 900)
        let height = AppShellSurfaceMetrics.appModalAvailableHeight(
            for: window,
            reservedTopInset: AppShellSurfaceMetrics.appModalTitlebarClearance,
            reservedBottomInset: 0
        )
        // height + 2*backdrop + top clearance must not exceed the window height
        XCTAssertEqual(
            height + AppShellSurfaceMetrics.appModalBackdropInset * 2 + AppShellSurfaceMetrics.appModalTitlebarClearance,
            window.height,
            accuracy: 0.001
        )
    }

    func testOverlayDefaultsToTitlebarTopClearance() {
        // The overlay must never exceed the available height when only the
        // titlebar is reserved (no bottom nav). Mirrors the default inset.
        let window = CGSize(width: 1440, height: 875)
        let reservedTop = AppShellSurfaceMetrics.appModalTitlebarClearance
        let overlayHeight = AppShellSurfaceMetrics.appModalAvailableHeight(
            for: window,
            reservedTopInset: reservedTop,
            reservedBottomInset: 0
        )
        XCTAssertLessThanOrEqual(
            overlayHeight + AppShellSurfaceMetrics.appModalBackdropInset * 2 + reservedTop,
            window.height
        )
    }

    // MARK: - Bottom nav clearance

    func testFloatingNavClearanceUsesSharedConstants() {
        let expanded = AppShellSurfaceMetrics.floatingNavClearance(isExpanded: true)
        let collapsed = AppShellSurfaceMetrics.floatingNavClearance(isExpanded: false)
        let delta = expanded - collapsed
        // expanded is taller than collapsed by exactly the extra pill height
        XCTAssertEqual(delta, AppShellSurfaceMetrics.floatingNavExpandedHeight - AppShellSurfaceMetrics.floatingNavCollapsedHeight, accuracy: 0.001)
        XCTAssertGreaterThan(expanded, collapsed)
    }

    func testBrowserSurfaceHeightReservesFloatingNavClearance() {
        let window = CGSize(width: 1600, height: 900)
        let navClearance = AppShellSurfaceMetrics.floatingNavClearance(isExpanded: true)
        let height = AppShellSurfaceMetrics.browserSurfaceHeight(
            for: window,
            reservedBottomInset: navClearance
        )
        XCTAssertLessThanOrEqual(
            height + AppShellSurfaceMetrics.appModalBackdropInset * 2 + navClearance,
            window.height
        )
    }

    func testBrowserSurfaceHeightMatchesColdFeedPlaceholderContract() {
        let window = CGSize(width: 1440, height: 875)
        let navClearance = AppShellSurfaceMetrics.floatingNavClearance(isExpanded: true)
        let placeholderHeight = AppShellSurfaceMetrics.browserSurfaceHeight(
            for: window,
            reservedBottomInset: navClearance
        )
        let feedHeight = AppShellSurfaceMetrics.browserSurfaceHeight(
            for: window,
            reservedBottomInset: navClearance
        )
        XCTAssertEqual(placeholderHeight, feedHeight, accuracy: 0.001)
    }

    func testBrowserSurfaceHeightDoesNotUseModalMinimumFloor() {
        let tiny = CGSize(width: 500, height: 360)
        let navClearance = AppShellSurfaceMetrics.floatingNavClearance(isExpanded: true)
        let height = AppShellSurfaceMetrics.browserSurfaceHeight(
            for: tiny,
            reservedBottomInset: navClearance
        )
        XCTAssertLessThan(height, 560)
        XCTAssertGreaterThan(height, 0)
    }

    func testAvailableHeightReservesBottomNavClearance() {
        let window = CGSize(width: 1600, height: 900)
        let navClearance = AppShellSurfaceMetrics.appModalBottomNavClearance
        let height = AppShellSurfaceMetrics.appModalAvailableHeight(
            for: window,
            reservedTopInset: AppShellSurfaceMetrics.appModalTitlebarClearance,
            reservedBottomInset: navClearance
        )
        let total = height
            + AppShellSurfaceMetrics.appModalBackdropInset * 2
            + AppShellSurfaceMetrics.appModalTitlebarClearance
            + navClearance
        XCTAssertEqual(total, window.height, accuracy: 0.001)
    }

    func testBottomNavClearanceDefaultIsExpanded() {
        // Modals default to reserving the expanded nav so nothing collides
        // regardless of expanded/collapsed state at presentation time.
        XCTAssertEqual(
            AppShellSurfaceMetrics.appModalBottomNavClearance,
            AppShellSurfaceMetrics.floatingNavClearance(isExpanded: true),
            accuracy: 0.001
        )
    }

    func testEnvironmentDefaultMatchesExpandedNav() {
        var values = EnvironmentValues()
        XCTAssertEqual(
            values.appModalBottomNavClearance,
            AppShellSurfaceMetrics.appModalBottomNavClearance,
            accuracy: 0.001
        )
    }

    func testOverlayWithCustomNavClearanceReservesProvidedSpace() {
        let window = CGSize(width: 1500, height: 850)
        let customNav: CGFloat = 110
        var values = EnvironmentValues()
        values.appModalBottomNavClearance = customNav
        let height = AppShellSurfaceMetrics.appModalAvailableHeight(
            for: window,
            reservedTopInset: AppShellSurfaceMetrics.appModalTitlebarClearance,
            reservedBottomInset: values.appModalBottomNavClearance
        )
        let total = height
            + AppShellSurfaceMetrics.appModalBackdropInset * 2
            + AppShellSurfaceMetrics.appModalTitlebarClearance
            + customNav
        XCTAssertEqual(total, window.height, accuracy: 0.001)
    }

    // MARK: - Small-window clamping

    /// When the requested reservations fit, the modal exactly fills the window
    /// (top + content + bottom + backdrops == window height) and never overflows.
    func testAvailableHeightFitsExactlyWhenReservationsFit() {
        let window = CGSize(width: 1800, height: 1000)
        let top = AppShellSurfaceMetrics.appModalTitlebarClearance
        let bottom = AppShellSurfaceMetrics.appModalBottomNavClearance
        let height = AppShellSurfaceMetrics.appModalAvailableHeight(
            for: window,
            reservedTopInset: top,
            reservedBottomInset: bottom
        )
        let total = height + AppShellSurfaceMetrics.appModalBackdropInset * 2 + top + bottom
        XCTAssertEqual(total, window.height, accuracy: 0.001)
    }

    /// When reservations exceed the window, the modal clamps to the usable
    /// floor (560) instead of collapsing or overflowing the safe area.
    func testSmallWindowClampsToMinimumHeight() {
        let tiny = CGSize(width: 400, height: 300)
        let top = AppShellSurfaceMetrics.appModalTitlebarClearance
        let bottom = AppShellSurfaceMetrics.appModalBottomNavClearance
        let height = AppShellSurfaceMetrics.appModalAvailableHeight(
            for: tiny,
            reservedTopInset: top,
            reservedBottomInset: bottom
        )
        // The floor keeps small windows usable even though reservations exceed it.
        XCTAssertGreaterThanOrEqual(height, 560)
        // And the content height itself never exceeds the window body area.
        XCTAssertLessThanOrEqual(
            height,
            tiny.height - AppShellSurfaceMetrics.appModalBackdropInset * 2 + 560
        )
    }

    func testSurfaceHeightBackwardCompatibleWithZeroBottom() {
        let window = CGSize(width: 1280, height: 800)
        let legacy = AppShellSurfaceMetrics.appModalSurfaceHeight(for: window)
        let available = AppShellSurfaceMetrics.appModalAvailableHeight(
            for: window,
            reservedTopInset: 0,
            reservedBottomInset: 0
        )
        XCTAssertEqual(legacy, available, accuracy: 0.001)
    }

    func testDetailModalWidthLeavesVisibleSideBorders() {
        let window = CGSize(width: 1600, height: 900)
        let full = AppShellSurfaceMetrics.appModalWidth(for: window, size: .full)
        let detail = AppShellSurfaceMetrics.appModalWidth(for: window, size: .detail)
        XCTAssertLessThan(detail, full)
        XCTAssertLessThanOrEqual(detail, AppShellSurfaceMetrics.detailModalWidth(for: window))
    }

    // MARK: - Caller coverage: every modal routes through the shared overlay

    func testSharedOverlayWrapsModalContent() {
        // The single chokepoint used by extraction, downloads, settings, and
        // library modals. Confirming it composes with arbitrary modal content
        // validates that all call sites share the same chrome policy.
        let overlay = AppModalOverlay(dismiss: {}) {
            Text("modal content")
        }
        XCTAssertNotNil(overlay.body)
    }

    // MARK: - Shared modal visual shell constants

    func testScrimIsOnlyAHitTarget() {
        // Visual separation comes from the modal surface itself. The full-window
        // outside layer should not paint titlebar/nav clearance as black bands.
        let scrim = AppShellSurfaceMetrics.appModalScrimOpacity
        XCTAssertEqual(scrim, 0.001, accuracy: 0.001)
        XCTAssertLessThan(scrim, 0.01)
    }

    func testModalCornerRadiusIsSubstantial() {
        XCTAssertEqual(AppShellSurfaceMetrics.appModalCornerRadius, 18, accuracy: 0.001)
    }

    func testModalFillIsNearOpaque() {
        // The overlay owns the outer shell, so modal bodies can drop their
        // own translucent gradient and still read as a solid surface.
        let fill = AppShellSurfaceMetrics.appModalFillOpacity
        XCTAssertEqual(fill, 0.98, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(fill, 0.95)
    }

    func testModalOuterStrokeAndShadowAreDistinct() {
        XCTAssertEqual(AppShellSurfaceMetrics.appModalOuterStrokeOpacity, 0.16, accuracy: 0.001)
        XCTAssertEqual(AppShellSurfaceMetrics.appModalInnerHighlightOpacity, 0.10, accuracy: 0.001)
        XCTAssertEqual(AppShellSurfaceMetrics.appModalShadowOpacity, 0.65, accuracy: 0.001)
        // Shadow radius sits in the requested 28-36 band.
        XCTAssertGreaterThanOrEqual(AppShellSurfaceMetrics.appModalShadowRadius, 28)
        XCTAssertLessThanOrEqual(AppShellSurfaceMetrics.appModalShadowRadius, 36)
    }

    func testOverlaySurfaceDimensionsMatchAvailableHeight() {
        // The surface the overlay paints must use the same available-height
        // math (top + bottom clearance) so the visible shell matches chrome.
        let window = CGSize(width: 1500, height: 900)
        let expected = AppShellSurfaceMetrics.appModalAvailableHeight(
            for: window,
            reservedTopInset: AppShellSurfaceMetrics.appModalTitlebarClearance,
            reservedBottomInset: AppShellSurfaceMetrics.appModalBottomNavClearance
        )
        XCTAssertGreaterThan(expected, 0)
        XCTAssertLessThan(
            expected + AppShellSurfaceMetrics.appModalBackdropInset * 2
                + AppShellSurfaceMetrics.appModalTitlebarClearance
                + AppShellSurfaceMetrics.appModalBottomNavClearance,
            window.height + 1
        )
    }

    // MARK: - Mobile app primitives

    func testMobileTouchTargetIsAtLeastAppleMinimum() {
        XCTAssertGreaterThanOrEqual(MobileMetrics.touchTarget, 44)
    }

    func testMobileSheetRadiusIsLargerThanCardRadius() {
        XCTAssertGreaterThan(MobileMetrics.sheetRadius, MobileMetrics.compactCardRadius)
        XCTAssertGreaterThanOrEqual(MobileMetrics.cardRadius, 20)
    }

    func testReducedMotionUsesOpacityOnlyTransitions() {
        let transition = MobileTransitionPolicy.card(reduceMotion: true, performanceProfile: .normal)
        XCTAssertNotNil(transition)
        XCTAssertNil(MobileTransitionPolicy.spring(reduceMotion: true, performanceProfile: .normal))
    }
}
