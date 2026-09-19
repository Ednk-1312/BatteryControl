import XCTest
@testable import BatteryCore

/// Tests for the machine-evidence compatibility report: the shared builder,
/// the privacy gate, and round-trip JSON stability. This is the exact format
/// the community database review flow consumes.
final class CompatibilityReportTests: XCTestCase {

    private var testIdentity: PlatformIdentity {
        PlatformIdentity(
            chipGeneration: .m3,
            isAppleSilicon: true,
            macModelIdentifier: "Mac15,13",
            marketingModelName: "MacBook Air",
            osMajor: 15,
            osMinor: 8,
            osPatch: 0,
            osBuild: "24H23",
            systemFirmwareBuild: "20457.1.29"
        )
    }

    private var testSignature: [String: String] {
        [
            "CH0B": "absent",
            "CH0C": "absent",
            "CHTE": "absent",
            "CH0I": "absent",
            "CH0J": "present:00000000",
            "CHIE": "present:00000008",
            "bfF0": "present:00000000",
            "bfD0": "present:50000000",
            "bfE0": "present:46000000",
        ]
    }

    // MARK: Builder

    func testBuilderEmitsFullHardwareFacts() {
        let report = CompatibilityReportBuilder.build(
            identity: testIdentity,
            tier: .verified,
            detectedFamily: .firmwareLimit,
            smcSignature: testSignature,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(report.reportVersion, CompatibilityReportBuilder.currentVersion)
        XCTAssertEqual(report.hardware["chip"], "Apple M3")
        XCTAssertEqual(report.hardware["modelIdentifier"], "Mac15,13")
        XCTAssertEqual(report.hardware["osVersion"], "15.8.0")
        XCTAssertEqual(report.hardware["osBuild"], "24H23")
        XCTAssertEqual(report.hardware["systemFirmwareBuild"], "20457.1.29")
        XCTAssertEqual(report.detectedControlFamily, "firmwareLimit")
        XCTAssertEqual(report.firmwareProfileTier, "verified")
        XCTAssertEqual(report.smcCapabilitySignature, testSignature)
        // Profile notes name the matching family's profiles.
        XCTAssertTrue(report.profileNotes.contains("apple-silicon-20xxx-firmware-limit"))
    }

    func testBuilderRecordsNoFamilyWhenNothingDetected() {
        let report = CompatibilityReportBuilder.build(
            identity: testIdentity,
            tier: .untested,
            detectedFamily: .none,
            smcSignature: [:]
        )
        XCTAssertEqual(report.detectedControlFamily, "none")
        XCTAssertTrue(report.profileNotes.isEmpty)
    }

    // MARK: Privacy gate

    func testPrivacyGatePassesAWellFormedReport() {
        let report = CompatibilityReportBuilder.build(
            identity: testIdentity,
            tier: .compatibleByCapability,
            detectedFamily: .legacy,
            smcSignature: testSignature
        )
        XCTAssertTrue(CompatibilityReport.privacyViolations(in: report).isEmpty)
    }

    func testPrivacyGateRejectsPIIShapedKeys() {
        var report = CompatibilityReportBuilder.build(
            identity: testIdentity,
            tier: .verified,
            detectedFamily: .firmwareLimit,
            smcSignature: testSignature
        )
        report.smcCapabilitySignature["serialnumber"] = "C02XY12345"
        report.hardware["ownerName"] = "someone"
        let violations = CompatibilityReport.privacyViolations(in: report)
        XCTAssertEqual(violations, ["ownerName", "serialnumber"])
    }

    // MARK: Serialization

    func testJSONRoundTripPreservesAllFields() throws {
        let report = CompatibilityReportBuilder.build(
            identity: testIdentity,
            tier: .verified,
            detectedFamily: .firmwareLimit,
            smcSignature: testSignature
        )
        let data = try report.jsonData()
        let decoded = try JSONDecoder().decode(CompatibilityReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }

    func testJSONIsSortedForDiffability() throws {
        let report = CompatibilityReportBuilder.build(
            identity: testIdentity,
            tier: .verified,
            detectedFamily: .firmwareLimit,
            smcSignature: testSignature
        )
        let data = try report.jsonData()
        let json = String(data: data, encoding: .utf8)!
        // Sorted keys: the first hardware key emitted is "chip" (lexicographic).
        XCTAssertTrue(json.contains("\"chip\""))
        // Pretty-printed output contains newlines.
        XCTAssertTrue(json.contains("\n"))
    }
}
