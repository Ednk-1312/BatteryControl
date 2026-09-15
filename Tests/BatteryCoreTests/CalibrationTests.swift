import XCTest
@testable import BatteryCore

/// Tests for the full-cycle calibration state machine:
/// discharge to 20% → charge to 100% → hold 3 hours → drop to limit → finish.
final class CalibrationTests: XCTestCase {

    private func readings(
        percent: Int,
        charging: Bool = false,
        external: Bool = true
    ) -> BatteryReadings {
        BatteryReadings(
            percentage: percent,
            isCharging: charging,
            isExternalConnected: external,
            condition: .normal,
            cycleCount: 10,
            currentCapacitymAh: 1000,
            maxCapacitymAh: 4000,
            designCapacitymAh: 5000,
            voltagemV: 11500,
            amperageMA: 0,
            temperatureC: nil
        )
    }

    /// A session at the given stage with an 80% limit.
    private func session(_ stage: CalibrationStage, limit: Int = 80) -> CalibrationSession {
        var s = CalibrationSession(lowPercent: 20, limitPercent: limit)
        s.advance(to: stage)
        return s
    }

    // MARK: Full-cycle transitions

    func testFullHappyPath() {
        let limit = 80
        var s = session(.prepare, limit: limit)

        // Prepare → discharge begins regardless of level (starts from wherever we are).
        XCTAssertEqual(
            CalibrationDecisions.nextStage(current: .prepare, readings: readings(percent: 90), session: s),
            .dischargeToLow
        )

        s.advance(to: .dischargeToLow)
        XCTAssertNil(
            CalibrationDecisions.nextStage(current: .dischargeToLow, readings: readings(percent: 45), session: s),
            "Stays discharging above 20%"
        )
        XCTAssertEqual(
            CalibrationDecisions.nextStage(current: .dischargeToLow, readings: readings(percent: 20), session: s),
            .chargeToFull
        )

        s.advance(to: .chargeToFull)
        XCTAssertNil(
            CalibrationDecisions.nextStage(current: .chargeToFull, readings: readings(percent: 70, charging: true), session: s)
        )
        XCTAssertEqual(
            CalibrationDecisions.nextStage(current: .chargeToFull, readings: readings(percent: 100, charging: false), session: s),
            .holdAtFull
        )

        s.advance(to: .holdAtFull)
        XCTAssertNil(
            CalibrationDecisions.nextStage(
                current: .holdAtFull,
                readings: readings(percent: 100),
                session: s,
                now: s.stageEnteredAt!.addingTimeInterval(60) // 1 minute in
            ),
            "Hold must last the full 3 hours"
        )
        XCTAssertEqual(
            CalibrationDecisions.nextStage(
                current: .holdAtFull,
                readings: readings(percent: 100),
                session: s,
                now: s.stageEnteredAt!.addingTimeInterval(181 * 60) // 3h01m
            ),
            .dischargeToLimit
        )

        s.advance(to: .dischargeToLimit)
        XCTAssertNil(
            CalibrationDecisions.nextStage(current: .dischargeToLimit, readings: readings(percent: 90), session: s)
        )
        XCTAssertEqual(
            CalibrationDecisions.nextStage(current: .dischargeToLimit, readings: readings(percent: 80), session: s),
            .finish
        )
    }

    func testLowPointIs20Percent() {
        XCTAssertEqual(CalibrationDecisions.Limits.calibrationLowPercent, 20)
    }

    func testHoldDurationIs3Hours() {
        XCTAssertEqual(CalibrationDecisions.Limits.holdMinutesAtFull, 180)
    }

    // MARK: Required actions per stage

    func testRequiredActionPerStage() {
        XCTAssertEqual(
            CalibrationDecisions.requiredAction(stage: .dischargeToLow, readings: readings(percent: 60, external: true)),
            .forceDischarge
        )
        XCTAssertEqual(
            CalibrationDecisions.requiredAction(stage: .dischargeToLow, readings: readings(percent: 60, external: false)),
            .normal,
            "Already on battery: no adapter to cut"
        )
        XCTAssertEqual(
            CalibrationDecisions.requiredAction(stage: .chargeToFull, readings: readings(percent: 30)),
            .normal
        )
        XCTAssertEqual(
            CalibrationDecisions.requiredAction(stage: .holdAtFull, readings: readings(percent: 100)),
            .normal
        )
        XCTAssertEqual(
            CalibrationDecisions.requiredAction(stage: .dischargeToLimit, readings: readings(percent: 100, external: true)),
            .forceDischarge
        )
    }

    // MARK: Safety aborts

    func testServiceRecommendedAbortsCalibration() {
        let s = session(.dischargeToLow)
        var r = readings(percent: 50)
        r.condition = .serviceRecommended
        let reason = CalibrationDecisions.safetyAbortReason(readings: r, session: s)
        XCTAssertNotNil(reason, "Calibration must pause when battery reports a fault")
        XCTAssertTrue(reason?.contains("Service Recommended") ?? false)
    }

    func testDischargeBelowHardFloorAborts() {
        let s = session(.dischargeToLow)
        let reason = CalibrationDecisions.safetyAbortReason(readings: readings(percent: 14), session: s)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("safe floor") ?? false)
    }

    func testJustAboveLowPointDoesNotAbort() {
        let s = session(.dischargeToLow)
        XCTAssertNil(CalibrationDecisions.safetyAbortReason(readings: readings(percent: 21), session: s))
    }

    func testStuckDischargeAbortsAfter12Hours() {
        let s = session(.dischargeToLow)
        let reason = CalibrationDecisions.safetyAbortReason(
            readings: readings(percent: 45),
            session: s,
            now: s.stageEnteredAt!.addingTimeInterval(13 * 3600)
        )
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("no progress") ?? false)
    }

    func testHealthyDischargeDoesNotAbort() {
        let s = session(.dischargeToLow)
        XCTAssertNil(CalibrationDecisions.safetyAbortReason(readings: readings(percent: 55), session: s))
    }

    // MARK: Session lifecycle

    func testSessionIsActiveOnlyDuringRun() {
        XCTAssertFalse(session(.idle).isActive)
        XCTAssertFalse(session(.finish).isActive)
        XCTAssertTrue(session(.prepare).isActive)
        XCTAssertTrue(session(.holdAtFull).isActive)
    }

    func testFinishStageRestsAtLimitAndDoesNotClaimToRepairHealth() {
        // The finish-stage copy must describe resting at the limit on wall
        // power and be honest about what calibration does.
        XCTAssertTrue(CalibrationStage.finish.detailText.contains("rests at the limit"))
        XCTAssertTrue(CalibrationStage.finish.detailText.contains("does not repair"))
    }

    func testPolicyEngineRespectsCalibrationPrecedence() {
        var s = session(.dischargeToLow)
        s.advance(to: .dischargeToLimit)
        let action = ChargingPolicyEngine.decideForCalibration(
            readings: readings(percent: 95, charging: false, external: true),
            session: s
        )
        XCTAssertEqual(action, .forceDischarge, "Calibration discharge overrides the user policy")
    }

    func testProgressOrderMatchesSpec() {
        XCTAssertEqual(
            CalibrationStage.progressOrder,
            [.prepare, .dischargeToLow, .chargeToFull, .holdAtFull, .dischargeToLimit, .finish]
        )
    }
}
