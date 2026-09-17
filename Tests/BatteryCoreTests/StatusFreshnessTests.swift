import XCTest
@testable import BatteryCore

/// Regression tests for the GUI command/monitor race guard
/// (`XPCStatusResponse.isFresh(afterCommandAt:)`).
///
/// The bug class: a status response the daemon assembled BEFORE a user
/// command completed arrives after the command's ack and overwrites the
/// displayed state with pre-command data (e.g. old limit 70% after the
/// user set 80%). The guard lets clients detect such snapshots and request
/// fresh ones; these tests pin the decision logic.
final class StatusFreshnessTests: XCTestCase {

    private func response(
        snapshotTime: Date,
        verified: Bool = true,
        upperLimit: Int = 80
    ) -> XPCStatusResponse {
        let snapshot = BatteryStatusSnapshot(
            readings: .placeholder,
            activePolicy: ChargingPolicy(mode: .hysteresis, upperLimit: upperLimit, lowerLimit: upperLimit - 2),
            controlIsVerified: verified,
            activeBackendID: "firmwareLimit",
            capabilities: .unsupported,
            helperStatus: .running,
            timestamp: snapshotTime
        )
        return XPCStatusResponse(
            snapshot: snapshot,
            lastAttempt: nil,
            lastError: nil,
            daemonVersion: BatteryXPC.expectedHelperVersion
        )
    }

    // MARK: No command completed yet — everything applies

    func testNilCommandDateIsAlwaysFresh() {
        let r = response(snapshotTime: Date(timeIntervalSinceNow: -3_600))
        XCTAssertTrue(r.isFresh(afterCommandAt: nil))
    }

    // MARK: Response predates the command — stale

    func testSnapshotBeforeCommandIsStale() {
        let commandAt = Date()
        let before = commandAt.addingTimeInterval(-5)
        let r = response(snapshotTime: before)
        XCTAssertFalse(r.isFresh(afterCommandAt: commandAt))
    }

    func testSnapshotOneMillisecondBeforeCommandIsStale() {
        let commandAt = Date()
        let r = response(snapshotTime: commandAt.addingTimeInterval(-0.001))
        XCTAssertFalse(r.isFresh(afterCommandAt: commandAt))
    }

    // MARK: Response reflects the command — fresh

    func testSnapshotAfterCommandIsFresh() {
        let commandAt = Date()
        let r = response(snapshotTime: commandAt.addingTimeInterval(1))
        XCTAssertTrue(r.isFresh(afterCommandAt: commandAt))
    }

    /// Exact equality must count as fresh: the daemon stamps the snapshot
    /// as it builds the reply, so a timestamp equal to the command
    /// completion time is at-or-after and must not be discarded (would
    /// cause a pointless, bounded-but-wasteful re-request).
    func testSnapshotEqualToCommandTimeIsFresh() {
        let t = Date()
        let r = response(snapshotTime: t)
        XCTAssertTrue(r.isFresh(afterCommandAt: t))
    }

    // MARK: Transport pin — the DTO crossing XPC carries the guard inputs

    func testStatusResponseSurvivesEnvelopeRoundTrip() throws {
        let original = response(snapshotTime: Date(timeIntervalSince1970: 1_789_000_000), verified: false, upperLimit: 70)
        let envelope = try XCTUnwrap(XPCEnvelope.encode(original, kind: XPCEnvelope.kindStatus))
        let decoded = try XCTUnwrap(envelope.decode(XPCStatusResponse.self, expectingKind: XPCEnvelope.kindStatus))
        XCTAssertEqual(decoded, original)
        // The decision itself must match after decode (timestamp fidelity).
        let commandAt = original.snapshot.timestamp.addingTimeInterval(1)
        XCTAssertFalse(decoded.isFresh(afterCommandAt: commandAt))
    }
}
