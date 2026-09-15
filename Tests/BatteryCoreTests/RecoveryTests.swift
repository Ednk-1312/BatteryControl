import XCTest
@testable import BatteryCore

/// Tests for recovery heuristics and policy persistence round-trips.
final class RecoveryTests: XCTestCase {

    func testReapplyAfterWakeWhenPolicyActive() {
        let policy = ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 70)
        XCTAssertTrue(RecoveryDecisions.shouldReapplyAfterWake(
            readings: BatteryReadings.placeholder,
            policy: policy,
            override: .none
        ))
    }

    func testNoReapplyNeededInPassthrough() {
        XCTAssertFalse(RecoveryDecisions.shouldReapplyAfterWake(
            readings: BatteryReadings.placeholder,
            policy: .passthrough(),
            override: .none
        ))
    }

    func testReapplyWhenDischargeActiveEvenInPassthrough() {
        XCTAssertTrue(RecoveryDecisions.shouldReapplyAfterWake(
            readings: BatteryReadings.placeholder,
            policy: .passthrough(),
            override: .forceDischarge(targetPercent: 60, floorPercent: 20, belowFloorConsent: false)
        ))
    }

    func testTickIntervalIsFast() {
        XCTAssertEqual(RecoveryDecisions.tickIntervalSeconds, 20)
        XCTAssertLessThanOrEqual(RecoveryDecisions.reassertIntervalSeconds, 600)
    }
}

/// The helper persists the policy as JSON on disk; these tests pin the
/// Codable round-trip so on-disk files stay compatible.
final class PolicyCodableTests: XCTestCase {

    func testPolicyRoundTrip() throws {
        let policy = ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 70)
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(ChargingPolicy.self, from: data)
        XCTAssertEqual(decoded, policy)
    }

    func testOverrideRoundTrip() throws {
        let override = PolicyOverride.forceDischarge(targetPercent: 60, floorPercent: 20, belowFloorConsent: false)
        let data = try JSONEncoder().encode(override)
        let decoded = try JSONDecoder().decode(PolicyOverride.self, from: data)
        XCTAssertEqual(decoded, override)
    }

    func testSnapshotRoundTrip() throws {
        var readings = BatteryReadings.placeholder
        readings.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = BatteryStatusSnapshot(
            readings: readings,
            activePolicy: .passthrough(),
            controlIsVerified: false,
            activeBackendID: BackendID.smcInhibit.rawValue,
            capabilities: .unsupported,
            helperStatus: .running
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(BatteryStatusSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testCalibrationSessionRoundTrip() throws {
        var session = CalibrationSession(lowPercent: 20, limitPercent: 80)
        session.advance(to: .holdAtFull)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(CalibrationSession.self, from: data)
        XCTAssertEqual(decoded, session)
    }

    func testDiagnosticsEntryRoundTrip() throws {
        let entry = DiagnosticEntry(
            severity: .error,
            operation: "applyPolicy",
            backendID: BackendID.smcInhibit.rawValue,
            message: "Write accepted but state unchanged"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(DiagnosticEntry.self, from: data)
        XCTAssertEqual(decoded, entry)
    }
}
