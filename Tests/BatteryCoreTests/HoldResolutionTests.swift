import XCTest
@testable import BatteryCore

/// Regression tests for the hold-resolution rule: a `.hold` decided after
/// the engine resolves an override away must never re-apply the override's
/// action. The live failure was a force-discharge ending inside a
/// fixedTarget band: `.hold` resolved to `.forceDischarge` and re-latched
/// the adapter cut the engine had just released, every tick.
final class HoldResolutionTests: XCTestCase {

    private let hysteresis = ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 78)
    private let fixed = ChargingPolicy(mode: .fixedTarget, upperLimit: 80, lowerLimit: 77)
    private let passthrough = ChargingPolicy.passthrough()

    func testHoldNeverResolvesToForceDischarge() {
        // The core invariant: whatever was held before, a resolved hold is
        // never the override's own action.
        let resolved = RecoveryDecisions.resolvedHoldAction(
            lastHeld: .forceDischarge, policy: fixed, connected: true
        )
        XCTAssertNotEqual(resolved, .forceDischarge)
    }

    func testHoldAfterDischargeInsideFixedTargetBandChargesOnWallPower() {
        // Discharge stopped at target inside the band, charger attached:
        // the natural next step is charging toward the limit, not holding
        // the (now cancelled) discharge.
        XCTAssertEqual(
            RecoveryDecisions.resolvedHoldAction(lastHeld: .forceDischarge, policy: fixed, connected: true),
            .normal
        )
    }

    func testHoldAfterDischargeOnBatteryKeepsHolding() {
        // On battery there is nothing to charge; .hold stays a hold but
        // must still not re-apply the discharge.
        let resolved = RecoveryDecisions.resolvedHoldAction(
            lastHeld: .forceDischarge, policy: fixed, connected: false
        )
        XCTAssertNotEqual(resolved, .forceDischarge)
    }

    func testHoldAfterNormalApplyStaysHold() {
        // An already-applied normal/inhibit state is kept (no spurious
        // rewrites) when nothing resolved away.
        XCTAssertEqual(
            RecoveryDecisions.resolvedHoldAction(lastHeld: .normal, policy: fixed, connected: true),
            .hold
        )
        XCTAssertEqual(
            RecoveryDecisions.resolvedHoldAction(lastHeld: .inhibitCharging, policy: hysteresis, connected: true),
            .hold
        )
    }

    func testHoldWithNoHistoryFallsBackToPolicyNaturalAction() {
        XCTAssertEqual(
            RecoveryDecisions.resolvedHoldAction(lastHeld: nil, policy: passthrough, connected: true),
            .normal
        )
        XCTAssertEqual(
            RecoveryDecisions.resolvedHoldAction(lastHeld: nil, policy: hysteresis, connected: false),
            .normal
        )
        XCTAssertEqual(
            RecoveryDecisions.resolvedHoldAction(lastHeld: nil, policy: fixed, connected: true),
            .normal
        )
    }
}
