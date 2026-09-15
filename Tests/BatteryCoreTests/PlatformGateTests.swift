import XCTest
@testable import BatteryCore

/// Tests for the M1–M4 + macOS 15 platform gate.
final class PlatformGateTests: XCTestCase {

    private func identity(
        chip: ChipGeneration?,
        silicon: Bool = true,
        osMajor: Int = 15,
        osMinor: Int = 8
    ) -> PlatformIdentity {
        PlatformIdentity(
            chipGeneration: chip,
            isAppleSilicon: silicon,
            macModelIdentifier: "Mac14,2",
            marketingModelName: "MacBook Air (M2, 2022)",
            osMajor: osMajor,
            osMinor: osMinor,
            osPatch: 0,
            osBuild: "24H23"
        )
    }

    func testAllSupportedChipsOnMacOS15AreSupported() {
        for chip in [ChipGeneration.m1, .m2, .m3, .m4] {
            let id = identity(chip: chip)
            XCTAssertTrue(id.isSupportedPlatform, "\(chip.rawValue) on macOS 15 should be supported")
            XCTAssertNil(id.unsupportedReason)
        }
    }

    func testIntelIsUnsupported() {
        let id = identity(chip: nil, silicon: false, osMajor: 15)
        XCTAssertFalse(id.isSupportedPlatform)
        let reason = id.unsupportedReason ?? ""
        XCTAssertTrue(reason.contains("Intel"), "Reason should mention Intel: \(reason)")
    }

    func testMacOS14IsUnsupported() {
        let id = identity(chip: .m2, osMajor: 14)
        XCTAssertFalse(id.isSupportedPlatform)
        XCTAssertTrue((id.unsupportedReason ?? "").contains("macOS 14"))
    }

    func testTahoeIsUnsupported() {
        let id = identity(chip: .m2, osMajor: 26)
        XCTAssertFalse(id.isSupportedPlatform)
        XCTAssertTrue((id.unsupportedReason ?? "").contains("Tahoe"))
    }

    func testM5OnMacOS15IsOutOfRange() {
        // There is no real M5+macOS15 machine, but the gate must still reject
        // anything outside M1...M4 defensively.
        var id = identity(chip: nil, silicon: true)
        id.chipGeneration = nil
        XCTAssertFalse(id.isSupportedPlatform)
    }

    func testUnsupportedMessageMatchesSpec() {
        XCTAssertEqual(
            PlatformIdentity.unsupportedMessage,
            "BatteryControl supports Apple Silicon Macs from M1 through M4 running macOS 15 Sequoia."
        )
    }

    func testChipParsingFromBrandStrings() {
        XCTAssertEqual(ChipGeneration.parse(fromRawString: "Apple M2 Pro"), .m2)
        XCTAssertEqual(ChipGeneration.parse(fromRawString: "Apple M3 Max"), .m3)
        XCTAssertEqual(ChipGeneration.parse(fromRawString: "Apple M1"), .m1)
        XCTAssertEqual(ChipGeneration.parse(fromRawString: "Apple M4"), .m4)
        XCTAssertNil(ChipGeneration.parse(fromRawString: "Intel Core i9"))
        XCTAssertNil(ChipGeneration.parse(fromRawString: ""))
    }

    func testSummaryLine() {
        let id = identity(chip: .m2)
        XCTAssertTrue(id.summaryLine.contains("Apple M2"))
        XCTAssertTrue(id.summaryLine.contains("15.8"))
    }
}
