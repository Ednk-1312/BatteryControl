import XCTest
@testable import BatteryCore

/// Tests for the pure policy engine: hysteresis, fixed target, force
/// discharge, force charge, and safety-floor handling.
final class PolicyEngineTests: XCTestCase {

    private func readings(
        percent: Int,
        charging: Bool = false,
        external: Bool = true,
        amperage: Int = 0
    ) -> BatteryReadings {
        BatteryReadings(
            percentage: percent,
            isCharging: charging,
            isExternalConnected: external,
            condition: .normal,
            cycleCount: 100,
            currentCapacitymAh: 3000,
            maxCapacitymAh: 4000,
            designCapacitymAh: 5000,
            voltagemV: 11500,
            amperageMA: amperage,
            temperatureC: 30
        )
    }

    private var hysteresisPolicy: ChargingPolicy {
        ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 70)
    }

    // MARK: - Hysteresis band

    func testHysteresisChargesBelowLowerLimit() {
        let action = ChargingPolicyEngine.decide(
            readings: readings(percent: 65, charging: false),
            policy: hysteresisPolicy,
            override: .none
        )
        XCTAssertEqual(action, .normal)
    }

    func testHysteresisInhibitsAtOrAboveUpperLimit() {
        let action = ChargingPolicyEngine.decide(
            readings: readings(percent: 80, charging: true),
            policy: hysteresisPolicy,
            override: .none
        )
        XCTAssertEqual(action, .inhibitCharging)
    }

    func testHysteresisChargesTowardLimitInsideBand() {
        // Inside the band, charging runs so the battery rests AT the limit
        // instead of coasting in the middle of the band. This is stable, not
        // flapping: the backend stops the charge at the upper limit.
        let action = ChargingPolicyEngine.decide(
            readings: readings(percent: 75),
            policy: hysteresisPolicy,
            override: .none
        )
        XCTAssertEqual(action, .normal, "Inside the band the engine must charge toward the limit")
    }

    // MARK: - Fixed target

    func testFixedTargetChargesOnlyBelowBand() {
        let policy = ChargingPolicy(mode: .fixedTarget, upperLimit: 80, lowerLimit: 70)
        XCTAssertEqual(
            ChargingPolicyEngine.decide(readings: readings(percent: 74, charging: false), policy: policy, override: .none),
            .normal
        )
        XCTAssertEqual(
            ChargingPolicyEngine.decide(readings: readings(percent: 85, charging: true), policy: policy, override: .none),
            .inhibitCharging
        )
        XCTAssertEqual(
            ChargingPolicyEngine.decide(readings: readings(percent: 78), policy: policy, override: .none),
            .hold
        )
    }

    // MARK: - Force discharge

    func testForceDischargeContinuesAboveTarget() {
        let action = ChargingPolicyEngine.decide(
            readings: readings(percent: 78, charging: true),
            policy: hysteresisPolicy,
            override: .forceDischarge(targetPercent: 60, floorPercent: 20, belowFloorConsent: false)
        )
        XCTAssertEqual(action, .forceDischarge)
    }

    func testForceDischargeStopsAtTarget() {
        let action = ChargingPolicyEngine.decide(
            readings: readings(percent: 60),
            policy: hysteresisPolicy,
            override: .forceDischarge(targetPercent: 60, floorPercent: 20, belowFloorConsent: false)
        )
        XCTAssertEqual(action, .normal, "Discharge must stop at the target")
    }

    func testForceDischargeWithoutConsentClampsToSafetyFloor() {
        // A below-floor request without consent must be clamped back to the
        // safety floor: at 18% (below 20), discharge stops.
        let action = ChargingPolicyEngine.decide(
            readings: readings(percent: 18),
            policy: hysteresisPolicy,
            override: .forceDischarge(targetPercent: 5, floorPercent: 5, belowFloorConsent: false)
        )
        XCTAssertEqual(action, .normal, "Without consent the safety floor must stop discharge at 20%")
    }

    func testConsentedBelowFloorDischargeContinuesBelowTwenty() {
        // With recorded consent (threaded through the engine the same way the
        // daemon does, from the persisted override), discharge may continue
        // below the safety floor down to the (validated) floor.
        let action = ChargingPolicyEngine.decide(
            readings: readings(percent: 18, charging: true),
            policy: hysteresisPolicy,
            override: .forceDischarge(targetPercent: 5, floorPercent: 5, belowFloorConsent: true),
            belowFloorConsent: true
        )
        XCTAssertEqual(action, .forceDischarge, "Consent permits discharge below the safety floor")
    }

    func testConsentedDischargeStopsAtFloor() {
        let action = ChargingPolicyEngine.decide(
            readings: readings(percent: 1, charging: true),
            policy: hysteresisPolicy,
            override: .forceDischarge(targetPercent: 1, floorPercent: 1, belowFloorConsent: true),
            belowFloorConsent: true
        )
        XCTAssertEqual(action, .normal, "Even consented discharge stops at the absolute floor")
    }

    func testAbsoluteFloorNeverBelowOne() {
        XCTAssertEqual(ChargingPolicyEngine.effectiveDischargeFloor(requested: 0), 1)
        XCTAssertEqual(ChargingPolicyEngine.effectiveDischargeFloor(requested: -5), 1)
    }

    func testForceDischargeStopsWhenUnplugged() {
        let action = ChargingPolicyEngine.decide(
            readings: readings(percent: 90, external: false),
            policy: hysteresisPolicy,
            override: .forceDischarge(targetPercent: 60, floorPercent: 20, belowFloorConsent: false)
        )
        XCTAssertEqual(action, .normal, "No adapter to cut when on battery power")
    }

    func testEffectiveFloorPreservesBelowFloorRequestForConsentCheck() {
        // The resolver preserves sub-20 values so the consent check can see
        // them; enforcement happens via requiresBelowFloorConsent.
        XCTAssertEqual(ChargingPolicyEngine.effectiveDischargeFloor(requested: 5), 5)
        XCTAssertEqual(ChargingPolicyEngine.effectiveDischargeFloor(requested: 40), 40)
        XCTAssertTrue(ChargingPolicyEngine.requiresBelowFloorConsent(floor: 5))
        XCTAssertFalse(ChargingPolicyEngine.requiresBelowFloorConsent(floor: 20))
    }

    // MARK: - Force charge override

    func testForceChargeChargesBelowTarget() {
        let action = ChargingPolicyEngine.decide(
            readings: readings(percent: 60, charging: false),
            policy: hysteresisPolicy,
            override: .forceCharge(targetPercent: 100)
        )
        XCTAssertEqual(action, .normal, "Force charge bypasses the upper limit")
    }

    func testForceChargeFinishesAtTarget() {
        let action = ChargingPolicyEngine.decide(
            readings: readings(percent: 100, charging: true),
            policy: hysteresisPolicy,
            override: .forceCharge(targetPercent: 100)
        )
        XCTAssertEqual(action, .normal)
    }

    // MARK: - Invalid policy fails safe

    func testInvalidPolicyFailsTowardNormalCharging() {
        var policy = hysteresisPolicy
        policy.upperLimit = 500 // nonsense
        let action = ChargingPolicyEngine.decide(
            readings: readings(percent: 90, charging: true),
            policy: policy,
            override: .none
        )
        XCTAssertEqual(action, .normal)
    }

    // MARK: - Calibration precedence

    func testCalibrationDischargeOverridesPolicy() {
        var session = CalibrationSession(lowPercent: 20, limitPercent: 80)
        session.advance(to: .dischargeToLimit)
        let action = ChargingPolicyEngine.decideForCalibration(
            readings: readings(percent: 95, charging: true),
            session: session
        )
        XCTAssertEqual(action, .forceDischarge)
    }

    func testCalibrationChargeStageReenablesCharging() {
        var session = CalibrationSession(lowPercent: 20, limitPercent: 80)
        session.advance(to: .chargeToFull)
        let action = ChargingPolicyEngine.decideForCalibration(
            readings: readings(percent: 55, charging: false),
            session: session
        )
        XCTAssertEqual(action, .normal)
    }
}
