import XCTest
@testable import BatteryCore

/// Regression tests for the steady-state firmware-limit maintenance gate:
/// unchanged context + verified hardware must skip redundant per-tick SMC
/// maintenance, while any context change, unverified state, or elapsed
/// confirm interval reconfigures. Safety semantics: nothing that would
/// previously WRITE is skipped — only redundant read-confirmed maintenance
/// is spaced out; configure() still read-verifies before every write.
final class FirmwareMaintenanceGateTests: XCTestCase {

    private let policy = ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 78)
    private let context = FirmwareMaintContext(policy: ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 78), override: .none, calibrationActive: false)
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func should(
        lastContext: FirmwareMaintContext?,
        confirmed: Bool,
        lastConfirmedAt: Date?,
        confirmInterval: TimeInterval = 300,
        forceReconfigure: Bool = false
    ) -> Bool {
        RecoveryDecisions.shouldReconfigureFirmwareLimit(
            policy: policy,
            override: .none,
            calibrationActive: false,
            lastContext: lastContext,
            lastConfirmedAt: lastConfirmedAt,
            confirmed: confirmed,
            now: now,
            confirmInterval: confirmInterval,
            forceReconfigure: forceReconfigure
        )
    }

    // MARK: Skip path (the optimization)

    func testUnchangedVerifiedContextInsideIntervalSkips() {
        let confirmedAt = now.addingTimeInterval(-60)
        XCTAssertFalse(should(lastContext: context, confirmed: true, lastConfirmedAt: confirmedAt))
    }

    func testUnchangedVerifiedContextJustConfirmedSkips() {
        XCTAssertFalse(should(lastContext: context, confirmed: true, lastConfirmedAt: now.addingTimeInterval(-1)))
    }

    // MARK: Reconfigure paths (safety preserved)

    func testNoPriorContextReconfigures() {
        XCTAssertTrue(should(lastContext: nil, confirmed: true, lastConfirmedAt: now.addingTimeInterval(-1)))
    }

    func testUnverifiedStateAlwaysReconfigures() {
        XCTAssertTrue(should(lastContext: context, confirmed: false, lastConfirmedAt: now.addingTimeInterval(-1)))
    }

    func testMissingConfirmTimestampReconfigures() {
        XCTAssertTrue(should(lastContext: context, confirmed: true, lastConfirmedAt: nil))
    }

    func testElapsedConfirmIntervalReconfigures() {
        let confirmedAt = now.addingTimeInterval(-301)
        XCTAssertTrue(should(lastContext: context, confirmed: true, lastConfirmedAt: confirmedAt))
    }

    func testBoundaryIsInclusive() {
        let confirmedAt = now.addingTimeInterval(-300)
        XCTAssertTrue(should(lastContext: context, confirmed: true, lastConfirmedAt: confirmedAt))
    }

    // MARK: Context changes force reconfiguration

    func testPolicyChangeReconfigures() {
        let changed = FirmwareMaintContext(
            policy: ChargingPolicy(mode: .hysteresis, upperLimit: 70, lowerLimit: 65),
            override: .none,
            calibrationActive: false
        )
        XCTAssertTrue(should(lastContext: changed, confirmed: true, lastConfirmedAt: now.addingTimeInterval(-1)))
    }

    func testOverrideChangeReconfigures() {
        let changed = FirmwareMaintContext(
            policy: policy,
            override: .forceDischarge(targetPercent: 60, floorPercent: 30, belowFloorConsent: false),
            calibrationActive: false
        )
        XCTAssertTrue(should(lastContext: changed, confirmed: true, lastConfirmedAt: now.addingTimeInterval(-1)))
    }

    func testCalibrationTransitionReconfigures() {
        let changed = FirmwareMaintContext(policy: policy, override: .none, calibrationActive: true)
        XCTAssertTrue(should(lastContext: changed, confirmed: true, lastConfirmedAt: now.addingTimeInterval(-1)))
    }

    // MARK: Force path (user commands / recovery events)

    func testForceAlwaysReconfiguresEvenWhenFreshAndVerified() {
        XCTAssertTrue(should(
            lastContext: context,
            confirmed: true,
            lastConfirmedAt: now,
            forceReconfigure: true
        ))
    }

    func testTickPathIsNotForced() {
        XCTAssertFalse(should(
            lastContext: context,
            confirmed: true,
            lastConfirmedAt: now.addingTimeInterval(-60),
            forceReconfigure: false
        ))
    }

    // MARK: Context type sanity

    func testContextEqualityIgnoresNothing() {
        let same = FirmwareMaintContext(policy: policy, override: .none, calibrationActive: false)
        XCTAssertEqual(context, same)
        let other = FirmwareMaintContext(policy: ChargingPolicy(mode: .passthrough, upperLimit: 100, lowerLimit: 90), override: .none, calibrationActive: false)
        XCTAssertNotEqual(context, other)
    }
}
