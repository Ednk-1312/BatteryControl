import XCTest
@testable import BatteryCore

/// Regression tests for the dashboard semantics (the "Lower Limit: 78%"
/// bug): the primary dashboard limit must always be the USER'S charge
/// limit (the policy upper limit), the lower hysteresis threshold may only
/// appear as "resumes at" behavior, and the control status must stay
/// honest in every state-matrix row.
final class DashboardSummaryTests: XCTestCase {

    private func policy(upper: Int, lower: Int) -> ChargingPolicy {
        ChargingPolicy(mode: .hysteresis, upperLimit: upper, lowerLimit: lower)
    }

    // MARK: Primary limit = the user's setting, never the lower threshold

    func testPrimaryLimitIs80For80And78() {
        XCTAssertEqual(DashboardSummary.primaryLimitText(policy: policy(upper: 80, lower: 78)), "80%")
    }

    func testPrimaryLimitIs60For60And50() {
        XCTAssertEqual(DashboardSummary.primaryLimitText(policy: policy(upper: 60, lower: 50)), "60%")
    }

    func testPrimaryLimitForCustomValues() {
        XCTAssertEqual(DashboardSummary.primaryLimitText(policy: policy(upper: 87, lower: 71)), "87%")
    }

    func testPrimaryLimitNeverReportsTheLowerThreshold() {
        // The original bug: a 78–80 band made 78 look like the limit.
        let p = policy(upper: 80, lower: 78)
        let text = DashboardSummary.primaryLimitText(policy: p)
        XCTAssertFalse(text.contains("78"), "the lower threshold must never be the primary limit display")
    }

    func testPrimaryLimitNoneForPassthrough() {
        XCTAssertEqual(DashboardSummary.primaryLimitText(policy: .passthrough()), "None")
    }

    func testPrimaryLimitNoneWithoutPolicy() {
        XCTAssertEqual(DashboardSummary.primaryLimitText(policy: nil), "None")
    }

    // MARK: Resume behavior describes hysteresis without a second "limit"

    func testResumeBehaviorFor80And78() {
        let text = DashboardSummary.resumeBehaviorText(policy: policy(upper: 80, lower: 78))
        XCTAssertTrue(text.contains("80%"), "must state where charging stops")
        XCTAssertTrue(text.contains("78%"), "must state where charging resumes")
        XCTAssertTrue(text.contains("resumes"), "must frame the lower threshold as resume behavior")
    }

    func testResumeBehaviorFor60And50() {
        let text = DashboardSummary.resumeBehaviorText(policy: policy(upper: 60, lower: 50))
        XCTAssertTrue(text.contains("60%"))
        XCTAssertTrue(text.contains("50%"))
    }

    // MARK: Control status matrix (never fabricates)

    private func snapshot(
        mode: ControlMode = .hysteresis,
        verified: Bool = true,
        override: PolicyOverride = .none
    ) -> BatteryStatusSnapshot {
        BatteryStatusSnapshot(
            readings: .placeholder,
            activePolicy: ChargingPolicy(mode: mode, upperLimit: 80, lowerLimit: 78),
            activeOverride: override,
            controlIsVerified: verified,
            activeBackendID: "firmware-limit",
            capabilities: .unsupported,
            helperStatus: .running
        )
    }

    func testControlStatusVerifiedLimit() {
        XCTAssertEqual(
            DashboardSummary.controlStatus(snapshot: snapshot(), isSupportedPlatform: true),
            "Active & verified"
        )
    }

    func testControlStatusUnverifiedNeverReadsVerified() {
        XCTAssertEqual(
            DashboardSummary.controlStatus(snapshot: snapshot(verified: false), isSupportedPlatform: true),
            "Active, not verified"
        )
    }

    func testControlStatusMacOSManaged() {
        XCTAssertEqual(
            DashboardSummary.controlStatus(snapshot: snapshot(mode: .passthrough), isSupportedPlatform: true),
            "macOS managed"
        )
    }

    func testControlStatusDaemonUnavailableNeverClaimsVerified() {
        // nil snapshot = daemon unreachable: no claims, period.
        XCTAssertEqual(
            DashboardSummary.controlStatus(snapshot: nil, isSupportedPlatform: true),
            "Unavailable"
        )
        // Even with a verified=true snapshot "remembered", nil is nil.
        XCTAssertNotEqual(
            DashboardSummary.controlStatus(snapshot: nil, isSupportedPlatform: true),
            "Active & verified"
        )
    }

    func testControlStatusUnsupportedPlatform() {
        XCTAssertEqual(
            DashboardSummary.controlStatus(snapshot: snapshot(), isSupportedPlatform: false),
            "Unsupported"
        )
    }

    func testControlStatusForceDischarge() {
        let override = PolicyOverride.forceDischarge(targetPercent: 75, floorPercent: 20, belowFloorConsent: false)
        XCTAssertEqual(
            DashboardSummary.controlStatus(snapshot: snapshot(override: override), isSupportedPlatform: true),
            "Discharge active"
        )
        XCTAssertEqual(
            DashboardSummary.controlStatus(snapshot: snapshot(verified: false, override: override), isSupportedPlatform: true),
            "Discharge (unverified)"
        )
    }

    func testControlStatusForceCharge() {
        let override = PolicyOverride.forceCharge(targetPercent: 100)
        XCTAssertEqual(
            DashboardSummary.controlStatus(snapshot: snapshot(override: override), isSupportedPlatform: true),
            "Charge active"
        )
    }

    // MARK: Compatibility tier wording (no overclaiming)

    func testCompatibilityLinePerTier() {
        XCTAssertTrue(DashboardSummary.compatibilityLine(tier: .verified).contains("physically tested"))
        XCTAssertTrue(DashboardSummary.compatibilityLine(tier: .compatibleByCapability).contains("not been physically tested"))
        XCTAssertTrue(DashboardSummary.compatibilityLine(tier: .untested).contains("read-only"))
        XCTAssertTrue(DashboardSummary.compatibilityLine(tier: .unsupported).contains("outside"))
        XCTAssertTrue(DashboardSummary.compatibilityLine(tier: nil).contains("outside"))
    }
}
