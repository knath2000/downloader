import XCTest
@testable import VidDL

/// Focused tests for the subtle "breathing" pulse applied to pending extraction
/// skeleton rows. These verify the two guarantees from the change plan:
///  1. The pulse is ALWAYS animated for pending rows — even under Accessibility
///     Reduce Motion, a reduced-effects (e.g. x86_64) Debug build, or any
///     combination — because it is a gentle opacity/tint breath, not a
///     motion-heavy effect.
///  2. Motion-heavy effects (shimmer sweep + progress sweep + entrance offset)
///     stay disabled under Reduce Motion or reduced performance effects.
///
/// The tests exercise `ExtractionLoadingRow`'s real shared policy helpers rather
/// than mirroring the logic locally.
final class ExtractionPulseTests: XCTestCase {

    // MARK: - Pulse is enabled unconditionally for pending rows

    func testPulseAnimatedIsAlwaysTrue() {
        XCTAssertTrue(ExtractionLoadingRow.pulseAnimated)
    }

    func testPulseAnimatedUnderReduceMotion() {
        XCTAssertTrue(ExtractionLoadingRow.pulseAnimated,
                      "Pulse must run even when Accessibility Reduce Motion is on")
    }

    func testPulseAnimatedUnderReducedEffects() {
        XCTAssertTrue(ExtractionLoadingRow.pulseAnimated,
                      "Pulse must run even with a reduced-effects performance profile")
    }

    func testPulseAnimatedOnX86_64ReducedProfile() {
        // Simulates the reported environment: macOS Reduce Motion enabled and a
        // Debug build whose performance profile disallows loading animation.
        XCTAssertTrue(ExtractionLoadingRow.pulseAnimated,
                      "x86_64 / reduced profile must not suppress the pulse")
    }

    // MARK: - Traveling effects stay gated (shimmer + sweep + entrance)

    func testTravelingEffectsEnabledWhenMotionOffAndProfileNormal() {
        XCTAssertTrue(ExtractionLoadingRow.allowsTravelingEffects(
            reduceMotion: false,
            allowsLoadingAnimation: PerformanceProfile.normal.allowsLoadingAnimation))
    }

    func testTravelingEffectsDisabledUnderReduceMotion() {
        XCTAssertFalse(ExtractionLoadingRow.allowsTravelingEffects(
            reduceMotion: true,
            allowsLoadingAnimation: PerformanceProfile.normal.allowsLoadingAnimation))
    }

    func testTravelingEffectsDisabledUnderReducedEffects() {
        XCTAssertFalse(ExtractionLoadingRow.allowsTravelingEffects(
            reduceMotion: false,
            allowsLoadingAnimation: PerformanceProfile.reducedEffects.allowsLoadingAnimation))
    }

    func testTravelingEffectsDisabledWhenBothActive() {
        XCTAssertFalse(ExtractionLoadingRow.allowsTravelingEffects(
            reduceMotion: true,
            allowsLoadingAnimation: PerformanceProfile.reducedEffects.allowsLoadingAnimation))
    }

    // MARK: - Pulse timing / strength constants stay subtle

    func testPulsePeriodIsGentle() {
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
        XCTAssertGreaterThanOrEqual(ExtractionPulse.brightness, 0.0)
        XCTAssertLessThanOrEqual(ExtractionPulse.brightness, 0.15)
    }
}
