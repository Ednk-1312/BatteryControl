import XCTest
@testable import BatteryCore

/// Regression tests for GUI helper-status derivation.
///
/// The bug: after an in-place app upgrade with the GUI left open, the
/// current daemon answered status fine (dashboard showed "Active &
/// verified"), but the version mismatch in the same response flipped the
/// helper status to `.outdated`, rendering a "Privileged helper required —
/// Repair Helper" banner above the verified tiles. Both states were shown
/// at once, and the offered repair could never fix the real problem (the
/// running process was the outdated component).
final class HelperStatusDerivationTests: XCTestCase {

    private let expected = "1.3.3"

    // MARK: Stale process — the upgrade-while-running case

    func testStaleProcessReadsRunningRegardlessOfVersion() {
        // The helper is current and healthy; the mismatch is in the GUI
        // process. Status must NOT claim the helper is the problem.
        XCTAssertEqual(
            HelperStatusDerivation.helperStatus(
                isStaleProcess: true,
                daemonVersion: "1.2.0",
                expectedVersion: expected
            ),
            .running
        )
        XCTAssertEqual(
            HelperStatusDerivation.helperStatus(
                isStaleProcess: true,
                daemonVersion: expected,
                expectedVersion: expected
            ),
            .running
        )
    }

    // MARK: Version mismatch without staleness

    func testOlderDaemonVersionIsOutdated() {
        XCTAssertEqual(
            HelperStatusDerivation.helperStatus(
                isStaleProcess: false,
                daemonVersion: "1.2.0",
                expectedVersion: expected
            ),
            .outdated
        )
    }

    func testMatchingVersionIsRunning() {
        XCTAssertEqual(
            HelperStatusDerivation.helperStatus(
                isStaleProcess: false,
                daemonVersion: expected,
                expectedVersion: expected
            ),
            .running
        )
    }

    func testNilVersionDerivesRunningRatherThanGuessing() {
        // No version information: never fabricate an "outdated" claim.
        XCTAssertEqual(
            HelperStatusDerivation.helperStatus(
                isStaleProcess: false,
                daemonVersion: nil,
                expectedVersion: expected
            ),
            .running
        )
    }

    // MARK: Setup banner suppression

    func testSetupBannerSuppressedForStaleProcess() {
        // The contradictory dashboard: stale process + setup banner with a
        // live "Active & verified" dashboard beneath it. The stale banner
        // owns the messaging; the setup banner must yield.
        XCTAssertFalse(
            HelperStatusDerivation.shouldShowSetupBanner(
                needsSetup: true,
                isSupported: true,
                isStaleProcess: true
            )
        )
    }

    func testSetupBannerShownForGenuineSetupNeed() {
        XCTAssertTrue(
            HelperStatusDerivation.shouldShowSetupBanner(
                needsSetup: true,
                isSupported: true,
                isStaleProcess: false
            )
        )
    }

    func testSetupBannerSuppressedWhenUnsupportedOrNotNeeded() {
        XCTAssertFalse(
            HelperStatusDerivation.shouldShowSetupBanner(
                needsSetup: true,
                isSupported: false,
                isStaleProcess: false
            )
        )
        XCTAssertFalse(
            HelperStatusDerivation.shouldShowSetupBanner(
                needsSetup: false,
                isSupported: true,
                isStaleProcess: false
            )
        )
    }
}
