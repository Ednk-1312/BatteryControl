import XCTest
@testable import BatteryCore

/// Tests for backend selection and verification logic.
final class BackendSelectionTests: XCTestCase {

    private func caps(verifiedControl: Bool, smc: Bool = true) -> BatteryCapabilities {
        BatteryCapabilities(
            supportsUpperLimit: verifiedControl,
            supportsLowerLimit: verifiedControl,
            supportsFixedLimit: verifiedControl,
            supportsForceDischarge: smc && verifiedControl,
            supportsForceCharge: verifiedControl,
            supportsCalibration: verifiedControl,
            supportsSMC: smc,
            supportsVerifiedChargingControl: verifiedControl
        )
    }

    func testPrefersFirmwareLimitWhenVerified() {
        let selected = BackendSelector.select(capabilities: [
            .firmwareLimit: caps(verifiedControl: true),
            .pmAssertion: caps(verifiedControl: true, smc: false),
            .smcInhibit: caps(verifiedControl: true),
        ])
        XCTAssertEqual(selected, .firmwareLimit)
    }

    func testPrefersPMAssertionWhenFirmwareLimitMissing() {
        let selected = BackendSelector.select(capabilities: [
            .pmAssertion: caps(verifiedControl: true, smc: false),
            .smcInhibit: caps(verifiedControl: true),
        ])
        XCTAssertEqual(selected, .pmAssertion)
    }

    func testFallsBackToSMCInhibitWhenPMAssertionUnverified() {
        let selected = BackendSelector.select(capabilities: [
            .pmAssertion: caps(verifiedControl: false, smc: false),
            .smcInhibit: caps(verifiedControl: true),
        ])
        XCTAssertEqual(selected, .smcInhibit)
    }

    func testFallsBackToCHWAWhenInhibitUnverified() {
        let selected = BackendSelector.select(capabilities: [
            .pmAssertion: caps(verifiedControl: false, smc: false),
            .smcInhibit: caps(verifiedControl: false),
            .smcCHWA: caps(verifiedControl: true),
        ])
        XCTAssertEqual(selected, .smcCHWA)
    }

    private func attemptCaps(smc: Bool = false) -> BatteryCapabilities {
        // Present-but-unverified control, as the PM-assertion probe reports.
        BatteryCapabilities(
            supportsUpperLimit: true,
            supportsLowerLimit: true,
            supportsFixedLimit: true,
            supportsForceDischarge: smc,
            supportsForceCharge: true,
            supportsCalibration: true,
            supportsSMC: smc,
            supportsVerifiedChargingControl: false
        )
    }

    func testFallsBackToBestEffortWhenNothingIsVerified() {
        // With no verified mechanism, prefer a backend that can still ATTEMPT
        // actions (honestly verified per-action) over pure observation.
        let selected = BackendSelector.select(capabilities: [
            .pmAssertion: attemptCaps(),
            .bclmLegacy: caps(verifiedControl: false, smc: false),
        ])
        XCTAssertEqual(selected, .pmAssertion)
    }

    func testFallsBackToObservationWhenNothingCanAct() {
        let selected = BackendSelector.select(capabilities: [:])
        XCTAssertEqual(selected, .fallback)
    }

    func testSelectionWithEmptyCapabilitiesIsObservationOnly() {
        XCTAssertEqual(BackendSelector.select(capabilities: [:]), .fallback)
    }

    func testBackendOrderPrefersFirmwareLimitFirst() {
        XCTAssertEqual(BackendSelector.preferredOrder.first, .firmwareLimit)
        XCTAssertEqual(BackendSelector.preferredOrder.last, .fallback)
    }
}

/// Tests for the firmware-limit value validation (pure logic).
final class FirmwareLimitValidationTests: XCTestCase {

    func testAcceptsSaneBand() {
        XCTAssertNil(FirmwareLimitValidation.problem(upper: 80, lower: 70))
        XCTAssertNil(FirmwareLimitValidation.problem(upper: 100, lower: 99))
    }

    func testRejectsInvertedOrEqualBand() {
        XCTAssertNotNil(FirmwareLimitValidation.problem(upper: 70, lower: 80))
        XCTAssertNotNil(FirmwareLimitValidation.problem(upper: 80, lower: 80))
    }

    func testRejectsOutOfRangeValues() {
        XCTAssertNotNil(FirmwareLimitValidation.problem(upper: 0, lower: 5))
        XCTAssertNotNil(FirmwareLimitValidation.problem(upper: 101, lower: 50))
        XCTAssertNotNil(FirmwareLimitValidation.problem(upper: 80, lower: 4))
    }

    func testPolicyMapsToLimit() {
        let policy = ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 70)
        let limit = FirmwareLimitValidation.requestedLimit(policy: policy, override: .none)
        XCTAssertEqual(limit?.upper, 80)
        XCTAssertEqual(limit?.lower, 70)
    }

    func testPassthroughDeactivatesLimit() {
        let policy = ChargingPolicy.passthrough()
        XCTAssertNil(FirmwareLimitValidation.requestedLimit(policy: policy, override: .none))
    }

    func testForceChargeAboveCeilingDeactivatesLimit() {
        let policy = ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 70)
        XCTAssertNil(
            FirmwareLimitValidation.requestedLimit(policy: policy, override: .forceCharge(targetPercent: 100)),
            "A force-charge to 100% must clear the firmware limit"
        )
        XCTAssertNil(
            FirmwareLimitValidation.requestedLimit(policy: policy, override: .forceCharge(targetPercent: 85)),
            "A force-charge target above the user's limit (80) must clear the limit, not stall at the band"
        )
        XCTAssertNotNil(
            FirmwareLimitValidation.requestedLimit(policy: policy, override: .forceCharge(targetPercent: 75)),
            "A force-charge at/below the user's limit tops up to the existing band"
        )
    }

    func testForceChargeAtExactLimitKeepsBand() {
        let policy = ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 70)
        XCTAssertNotNil(
            FirmwareLimitValidation.requestedLimit(policy: policy, override: .forceCharge(targetPercent: 80)),
            "A force-charge target equal to the upper limit stays within the band"
        )
        // Custom low policy: the boundary must follow the policy, not a
        // hard-coded 80/100.
        let lowPolicy = ChargingPolicy(mode: .hysteresis, upperLimit: 60, lowerLimit: 50)
        XCTAssertNil(
            FirmwareLimitValidation.requestedLimit(policy: lowPolicy, override: .forceCharge(targetPercent: 75)),
            "Force-charge 75 over a 60-limit policy must clear the band"
        )
        XCTAssertNotNil(
            FirmwareLimitValidation.requestedLimit(policy: lowPolicy, override: .forceCharge(targetPercent: 60))
        )
    }

    func testFixedTargetUsesBandAsLower() {
        let policy = ChargingPolicy(mode: .fixedTarget, upperLimit: 80, lowerLimit: 0)
        let limit = FirmwareLimitValidation.requestedLimit(policy: policy, override: .none)
        XCTAssertEqual(limit?.upper, 80)
        XCTAssertEqual(limit?.lower, 80 - ChargingPolicy.fixedTargetBand)
    }
}

/// Tests for the verification decision matrix.
final class VerificationTests: XCTestCase {

    private func readings(
        percent: Int,
        charging: Bool,
        external: Bool,
        amperage: Int = 0
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
            amperageMA: amperage,
            temperatureC: nil
        )
    }

    private var policy: ChargingPolicy {
        ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 70)
    }

    func testInhibitVerifiedWhenChargingStopsOnAC() {
        let verdict = VerificationLogic.verify(
            action: .inhibitCharging,
            readings: readings(percent: 81, charging: false, external: true),
            policy: policy
        )
        XCTAssertEqual(verdict, .verified)
    }

    func testInhibitNotVerifiedWhileStillCharging() {
        let verdict = VerificationLogic.verify(
            action: .inhibitCharging,
            readings: readings(percent: 81, charging: true, external: true),
            policy: policy
        )
        XCTAssertEqual(verdict, .pending, "A write that changed nothing must not be reported as applied")
    }

    func testInhibitNotClaimedAtFullCharge() {
        // macOS stops charging by itself at 100% — that is not proof.
        let verdict = VerificationLogic.verify(
            action: .inhibitCharging,
            readings: readings(percent: 100, charging: false, external: true),
            policy: policy
        )
        XCTAssertEqual(verdict, .pending)
    }

    func testInhibitFailsWhenBelowLimitAndNotChargingOnAC() {
        let verdict = VerificationLogic.verify(
            action: .normal,
            readings: readings(percent: 50, charging: false, external: true),
            policy: policy
        )
        if case .failed = verdict {
            // expected
        } else {
            XCTFail("Re-enabled charging with no charge happening on AC should fail verification")
        }
    }

    func testForceDischargeVerifiedByNegativeAmperage() {
        let verdict = VerificationLogic.verify(
            action: .forceDischarge,
            readings: readings(percent: 70, charging: false, external: true, amperage: -300),
            policy: policy
        )
        XCTAssertEqual(verdict, .verified)
    }

    func testForceDischargePendingWhenNothingMoves() {
        let verdict = VerificationLogic.verify(
            action: .forceDischarge,
            readings: readings(percent: 70, charging: false, external: true, amperage: 0),
            policy: policy
        )
        XCTAssertEqual(verdict, .pending)
    }

    func testRetryIsBounded() {
        // Bounded (no endless loops) AND long enough to observe a real
        // firmware taper when pausing an active charge (~2 min measured on
        // the verified M3 profile). Both properties are pinned: shrinking
        // the window reintroduces false "NOT verified" alarms, growing it
        // unboundedly would mask real failures.
        XCTAssertLessThanOrEqual(VerificationLogic.maxAttempts, 12, "No endless retry loops")
        XCTAssertGreaterThanOrEqual(
            TimeInterval(VerificationLogic.maxAttempts) * VerificationLogic.attemptDelaySeconds,
            VerificationLogic.minimumObservationWindowSeconds,
            "Verification window must cover measured firmware latency"
        )
        let now = Date()
        XCTAssertFalse(
            VerificationLogic.shouldRetry(attemptNumber: VerificationLogic.maxAttempts, verdict: .pending, now: now, lastAttemptTime: nil),
            "Retries must stop at the cap"
        )
        XCTAssertTrue(
            VerificationLogic.shouldRetry(attemptNumber: 1, verdict: .pending, now: now, lastAttemptTime: nil),
            "Early pending verdicts should be retried"
        )
        XCTAssertFalse(
            VerificationLogic.shouldRetry(attemptNumber: 1, verdict: .verified, now: now, lastAttemptTime: nil)
        )
    }
}
