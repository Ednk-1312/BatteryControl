import XCTest
@testable import BatteryCore

/// Tests for the user-facing "Fixed Charge Limit" mode: presets, default
/// resume thresholds, clamping, and the translation into a hysteresis
/// ChargingPolicy (the shape the verified firmware-limit profile programs).
final class FixedChargeLimitTests: XCTestCase {

    // MARK: Presets

    func testPresetListMatchesAdvertisedValues() {
        // Includes sub-80% presets: that is the point vs Apple's built-in
        // Charge Limit (80–100%). Every value must stay within the
        // firmware-limit validation bounds (both ≥ 5, gap ≥ 1).
        XCTAssertEqual(FixedChargeLimit.presetPercents, [50, 60, 70, 75, 80, 85, 90, 95, 100])
        for preset in FixedChargeLimit.presetPercents {
            XCTAssertNil(
                FirmwareLimitValidation.problem(upper: preset, lower: FixedChargeLimit.defaultResumeThreshold(forUpper: preset)),
                "Preset \(preset)% must produce a valid default policy"
            )
        }
    }

    func testIsPreset() {
        XCTAssertTrue(FixedChargeLimit.isPreset(80))
        XCTAssertTrue(FixedChargeLimit.isPreset(100))
        XCTAssertTrue(FixedChargeLimit.isPreset(75))
        XCTAssertTrue(FixedChargeLimit.isPreset(60))
        XCTAssertTrue(FixedChargeLimit.isPreset(50))
        XCTAssertFalse(FixedChargeLimit.isPreset(65))
        XCTAssertFalse(FixedChargeLimit.isPreset(0))
    }

    // MARK: Default resume thresholds

    func testDefaultResumeThresholdIsTwoPointsBelowLimit() {
        XCTAssertEqual(FixedChargeLimit.defaultResumeThreshold(forUpper: 80), 78)
        XCTAssertEqual(FixedChargeLimit.defaultResumeThreshold(forUpper: 90), 88)
        XCTAssertEqual(FixedChargeLimit.defaultResumeThreshold(forUpper: 60), 58)
        XCTAssertEqual(FixedChargeLimit.defaultResumeThreshold(forUpper: 100), 98)
    }

    func testDefaultResumeThresholdClampsForLowLimits() {
        // 45 → 43, which stays inside the allowed range (5…44).
        XCTAssertEqual(FixedChargeLimit.defaultResumeThreshold(forUpper: 45), 43)
        // The hardware-limit validation floor is 5%.
        XCTAssertEqual(FixedChargeLimit.defaultResumeThreshold(forUpper: 6), 5)
    }

    // MARK: Resume range

    func testAllowedResumeRangeStaysBelowUpper() {
        let range = FixedChargeLimit.allowedResumeRange(forUpper: 80)
        XCTAssertEqual(range, 5...79)
    }

    func testAllowedResumeRangeForDegenerateUpperNeverInverts() {
        let range = FixedChargeLimit.allowedResumeRange(forUpper: 1)
        XCTAssertFalse(range.isEmpty, "range must never be empty even for absurd uppers")
        XCTAssertTrue(range.lowerBound <= range.upperBound)
    }

    func testClampedResumeStaysInRange() {
        XCTAssertEqual(FixedChargeLimit.clampedResume(100, upper: 80), 79)
        XCTAssertEqual(FixedChargeLimit.clampedResume(1, upper: 80), 5)
        XCTAssertEqual(FixedChargeLimit.clampedResume(75, upper: 80), 75)
    }

    // MARK: Policy translation

    func testPolicyUsesDefaultResumeWhenOmitted() {
        let policy = FixedChargeLimit.policy(upper: 80)
        XCTAssertEqual(policy.mode, .hysteresis)
        XCTAssertEqual(policy.upperLimit, 80)
        XCTAssertEqual(policy.lowerLimit, 78)
    }

    func testPolicyUsesExplicitResume() {
        let policy = FixedChargeLimit.policy(upper: 80, resume: 65)
        XCTAssertEqual(policy.mode, .hysteresis)
        XCTAssertEqual(policy.upperLimit, 80)
        XCTAssertEqual(policy.lowerLimit, 65)
    }

    func testPolicyClampsInvalidInput() {
        // Resume above the limit is clamped below it, never inverted.
        let inverted = FixedChargeLimit.policy(upper: 80, resume: 95)
        XCTAssertEqual(inverted.upperLimit, 80)
        XCTAssertEqual(inverted.lowerLimit, 79)

        // Out-of-range upper is clamped into bounds.
        XCTAssertEqual(FixedChargeLimit.policy(upper: 150).upperLimit, 100)
        XCTAssertEqual(FixedChargeLimit.policy(upper: 0).upperLimit, 1)
    }

    func testPolicyFor100PercentIsFullChargeWithBand() {
        let policy = FixedChargeLimit.policy(upper: 100)
        XCTAssertEqual(policy.mode, .hysteresis)
        XCTAssertEqual(policy.upperLimit, 100)
        XCTAssertEqual(policy.lowerLimit, 98)
    }

    // MARK: The verified real-hardware configuration

    func testVerified80_70ConfigurationRoundTrips() {
        // The exact configuration verified on the M3 / mBoot-20457.1.29
        // hardware: 80% upper, 70% resume. It remains expressible; the
        // narrow default is a UX choice, not a hardware constraint.
        let policy = FixedChargeLimit.policy(upper: 80, resume: 70)
        // The summary names the USER'S limit and describes the lower
        // threshold as resume behavior — never as a range like "70–80%"
        // that reads like a second limit the user chose.
        XCTAssertEqual(policy.summary, "Charge limit 80% (resumes at 70%)")
    }

    // MARK: Explanation copy

    func testExplanationMentionsBothThresholds() {
        let text = FixedChargeLimit.explanation(upper: 80, resume: 70)
        XCTAssertTrue(text.contains("80%"))
        XCTAssertTrue(text.contains("70%"))
    }
}
