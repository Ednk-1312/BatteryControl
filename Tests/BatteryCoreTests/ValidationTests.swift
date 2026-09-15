import XCTest
@testable import BatteryCore

/// Tests for value validation at the trust boundary.
final class ValidationTests: XCTestCase {

    func testAcceptsValidHysteresisPolicy() {
        let policy = ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 70)
        XCTAssertNil(ControlModeHelpers.validate(policy))
    }

    func testRejectsUpperLimitAbove100() {
        let policy = ChargingPolicy(mode: .hysteresis, upperLimit: 101, lowerLimit: 70)
        XCTAssertNotNil(ControlModeHelpers.validate(policy))
    }

    func testRejectsUpperLimitBelow1() {
        let policy = ChargingPolicy(mode: .hysteresis, upperLimit: 0, lowerLimit: 0)
        XCTAssertNotNil(ControlModeHelpers.validate(policy))
    }

    func testRejectsLowerAtOrAboveUpper() {
        let policy = ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 80)
        XCTAssertNotNil(ControlModeHelpers.validate(policy))
    }

    func testPassthroughIsAlwaysValid() {
        let policy = ChargingPolicy(mode: .passthrough, upperLimit: 100, lowerLimit: 0)
        XCTAssertNil(ControlModeHelpers.validate(policy))
    }

    func testFixedTargetNeedsNoLowerBound() {
        let policy = ChargingPolicy(mode: .fixedTarget, upperLimit: 80, lowerLimit: 0)
        XCTAssertNil(ControlModeHelpers.validate(policy))
    }

    func testSanitizedPolicyFixesInvertedBands() {
        let sanitized = ChargingPolicy.sanitized(upper: 70, lower: 90)
        XCTAssertEqual(sanitized.upperLimit, 70)
        XCTAssertEqual(sanitized.lowerLimit, 69)
    }

    func testSanitizedPolicyClampsExtremes() {
        let sanitized = ChargingPolicy.sanitized(upper: 250, lower: -5)
        XCTAssertEqual(sanitized.upperLimit, 100)
        XCTAssertLessThan(sanitized.lowerLimit, sanitized.upperLimit)
    }

    func testPercentClamp() {
        XCTAssertEqual(ChargingPolicyEngine.clampPercent(150), 100)
        XCTAssertEqual(ChargingPolicyEngine.clampPercent(0), 1)
        XCTAssertEqual(ChargingPolicyEngine.clampPercent(80), 80)
    }

    func testEffectiveLowerLimitForModes() {
        let hysteresis = ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 70)
        XCTAssertEqual(hysteresis.effectiveLowerLimit, 70)

        let fixed = ChargingPolicy(mode: .fixedTarget, upperLimit: 80, lowerLimit: 0)
        XCTAssertEqual(fixed.effectiveLowerLimit, 77, "Fixed target uses a 3% internal band")

        let passthrough = ChargingPolicy.passthrough()
        XCTAssertEqual(passthrough.effectiveLowerLimit, 0)
    }

    func testEveryPrivilegedOperationRequiresValidation() {
        // getStatus is a pure read; everything else touches control state and
        // must go through validation.
        XCTAssertFalse(PrivilegedOperation.getStatus.requiresValidatedValues)
        for op in PrivilegedOperation.allCases where op != .getStatus {
            XCTAssertTrue(op.requiresValidatedValues, "\(op.rawValue) must require validated values")
        }
    }
}
