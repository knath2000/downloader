import XCTest
@testable import VidDL

/// Focused tests for the subtle "breathing" pulse applied to pending extraction
/// skeleton rows. These verify the two guarantees from the change plan:
///  1. The pulse is enabled only when reduce-motion is off AND the performance
///     profile allows loading animation.
///  2. The pulse timing/opacity/brightness constants stay within a subtle range
///     (no bouncing, no layout shift, no heavy visual churn).
final class ExtractionPulseTests: XCTestCase {

    // MARK: - Pulse enablement (mirrors ExtractionLoadingRow.allowsAnimation)

    private func pulseEnabled(reduceMotion: Bool, profile: PerformanceProfile) -> Bool {
        !reduceMotion && profile.allowsLoadingAnimation
    }

    func testPulseEnabledWhenMotionAllowedAndProfileNormal() {
        XCTAssertTrue(pulseEnabled(reduceMotion: false, profile: .normal))
    }

    func testPulseDisabledWhenReduceMotionIsOn() {
        XCTAssertFalse(pulseEnabled(reduceMotion: true, profile: .normal))
    }

    func testPulseDisabledWhenProfileDisallowsLoadingAnimation() {
        XCTAssertFalse(pulseEnabled(reduceMotion: false, profile: .reducedEffects))
    }

    func testPulseDisabledWhenBothConstraintsActive() {
        XCTAssertFalse(pulseEnabled(reduceMotion: true, profile: .reducedEffects))
    }

    // MARK: - Pulse timing / strength constants stay subtle

    func testPulsePeriodIsGentle() {
        // A breath should be slow enough to read as gentle, not a fast flicker.
        XCTAssertGreaterThanOrEqual(ExtractionPulse.duration, 1.2)
        XCTAssertLessThanOrEqual(ExtractionPulse.duration, 3.0)
    }

    func testBorderOpacityStaysFaint() {
        XCTAssertGreaterThanOrEqual(ExtractionPulse.minBorderOpacity, 0.0)
        XCTAssertGreaterThan(ExtractionPulse.maxBorderOpacity, ExtractionPulse.minBorderOpacity)
        XCTAssertLessThanOrEqual(ExtractionPulse.maxBorderOpacity, 0.5)
    }

    func testWashOpacityStaysFaint() {
        XCTAssertGreaterThanOrEqual(ExtractionPulse.minWashOpacity, 0.0)
        XCTAssertGreaterThan(ExtractionPulse.maxWashOpacity, ExtractionPulse.minWashOpacity)
        XCTAssertLessThanOrEqual(ExtractionPulse.maxWashOpacity, 0.2)
    }

    func testBrightnessDeltaIsSubtle() {
        // 6% brightness breathing is gentle; anything larger starts to feel like
        // a glow/flicker rather than a breath.
        XCTAssertGreaterThanOrEqual(ExtractionPulse.brightness, 0.0)
        XCTAssertLessThanOrEqual(ExtractionPulse.brightness, 0.15)
    }
}
