import XCTest
@testable import BatteryCore

/// Tests for XPC client-rejection classification. The daemon's *decision*
/// logic (signature/team checks) is unchanged by design; these tests pin the
/// *explanation* layer: why a client was refused, and the client-side
/// stale-process detection used by the GUI after an in-place upgrade.
final class XPCRejectionClassifierTests: XCTestCase {

    // MARK: Daemon-side classification

    func testClassifiesStaleBatteryControlClientAfterUpgrade() {
        XCTAssertEqual(
            XPCRejectionClassifier.classify(
                clientPath: "/Applications/BatteryControl.app/Contents/MacOS/BatteryControl",
                clientBundleID: "com.batterycontrol.app",
                expectedBundleID: "com.batterycontrol.app"
            ),
            .staleClientAfterUpgrade
        )
    }

    func testClassifiesForeignClient() {
        XCTAssertEqual(
            XPCRejectionClassifier.classify(
                clientPath: "/Applications/OtherApp.app/Contents/MacOS/OtherApp",
                clientBundleID: "com.example.other",
                expectedBundleID: "com.batterycontrol.app"
            ),
            .foreignClient
        )
    }

    func testClassifiesUninspectableClient() {
        XCTAssertEqual(
            XPCRejectionClassifier.classify(
                clientPath: nil,
                clientBundleID: nil,
                expectedBundleID: "com.batterycontrol.app"
            ),
            .uninspectable
        )
    }

    func testOnlyBatteryControlClientsGetTheStaleExplanation() {
        XCTAssertNotNil(XPCRejectionClassifier.userExplanation(for: .staleClientAfterUpgrade))
        XCTAssertNil(XPCRejectionClassifier.userExplanation(for: .foreignClient))
        XCTAssertNil(XPCRejectionClassifier.userExplanation(for: .uninspectable))
    }

    // MARK: Client-side stale-process detection

    func testProcessStartedBeforeBundleInstallIsStale() {
        // Installed at 12:00, process started at 11:00 → stale.
        XCTAssertTrue(
            XPCRejectionClassifier.isProcessStaleAfterUpgrade(
                runningProcessStart: date("11:00:00"),
                bundleInstallTime: date("12:00:00")
            )
        )
    }

    func testProcessStartedAfterBundleInstallIsFresh() {
        // Installed at 12:00, process started at 13:00 → fine.
        XCTAssertFalse(
            XPCRejectionClassifier.isProcessStaleAfterUpgrade(
                runningProcessStart: date("13:00:00"),
                bundleInstallTime: date("12:00:00")
            )
        )
    }

    func testSameVersionRebuildStillDetected() {
        // Same version string is irrelevant: the detection is time-based, so
        // a same-version rebuild that replaced the bundle is still caught.
        XCTAssertTrue(
            XPCRejectionClassifier.isProcessStaleAfterUpgrade(
                runningProcessStart: date("11:00:00"),
                bundleInstallTime: date("11:30:00")
            )
        )
    }

    func testMissingInstallTimeIsNeverStale() {
        // Unknown install time (e.g. running from a non-installed location):
        // never claim staleness — no false positives from missing data.
        XCTAssertFalse(
            XPCRejectionClassifier.isProcessStaleAfterUpgrade(
                runningProcessStart: date("11:00:00"),
                bundleInstallTime: nil
            )
        )
    }

    func testOneSecondToleranceAvoidsFalsePositiveForSimultaneousLaunch() {
        // Process started within 1s of the install timestamp (launch-at-
        // install race): not stale.
        let install = date("12:00:00")
        XCTAssertFalse(
            XPCRejectionClassifier.isProcessStaleAfterUpgrade(
                runningProcessStart: install.addingTimeInterval(0.5),
                bundleInstallTime: install
            )
        )
        // Just past the tolerance: stale.
        XCTAssertTrue(
            XPCRejectionClassifier.isProcessStaleAfterUpgrade(
                runningProcessStart: install.addingTimeInterval(-2),
                bundleInstallTime: install
            )
        )
    }

    // MARK: Helpers

    private func date(_ time: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: "2026-09-18 \(time)")!
    }
}
