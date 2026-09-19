import XCTest
@testable import BatteryCore

/// Tests for the M1–M4 + macOS 14/15/26/27 platform gate, and the
/// OS/firmware capability model (OSGeneration, native-charge-limit
/// ownership). The gate is admission, not capability: a supported OS
/// version never grants control by itself — that remains the SMC probe's
/// job, which these pure tests cannot and must not assert.
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

    // MARK: Platform gate

    func testAllSupportedChipsOnMacOS15AreSupported() {
        for chip in [ChipGeneration.m1, .m2, .m3, .m4] {
            let id = identity(chip: chip)
            XCTAssertTrue(id.isSupportedPlatform, "\(chip.rawValue) on macOS 15 should be supported")
            XCTAssertNil(id.unsupportedReason)
        }
    }

    func testAllSupportedChipsOnMacOS14AreAdmitted() {
        for chip in [ChipGeneration.m1, .m2, .m3, .m4] {
            let id = identity(chip: chip, osMajor: 14, osMinor: 7)
            XCTAssertTrue(id.isSupportedPlatform, "\(chip.rawValue) on macOS 14 should be admitted")
            XCTAssertNil(id.unsupportedReason)
        }
    }

    func testAllSupportedChipsOnMacOS26AreAdmitted() {
        for chip in [ChipGeneration.m1, .m2, .m3, .m4] {
            let id = identity(chip: chip, osMajor: 26, osMinor: 4)
            XCTAssertTrue(id.isSupportedPlatform, "\(chip.rawValue) on macOS 26 should be admitted")
            XCTAssertNil(id.unsupportedReason)
        }
    }

    func testAllSupportedChipsOnMacOS27AreAdmitted() {
        for chip in [ChipGeneration.m1, .m2, .m3, .m4] {
            let id = identity(chip: chip, osMajor: 27, osMinor: 0)
            XCTAssertTrue(id.isSupportedPlatform, "\(chip.rawValue) on macOS 27 should be admitted")
            XCTAssertNil(id.unsupportedReason)
        }
    }

    func testIntelIsUnsupported() {
        let id = identity(chip: nil, silicon: false, osMajor: 15)
        XCTAssertFalse(id.isSupportedPlatform)
        let reason = id.unsupportedReason ?? ""
        XCTAssertTrue(reason.contains("Intel"), "Reason should mention Intel: \(reason)")
    }

    func testMacOS13IsOutOfRange() {
        let id = identity(chip: .m2, osMajor: 13, osMinor: 6)
        XCTAssertFalse(id.isSupportedPlatform)
        let reason = id.unsupportedReason ?? ""
        XCTAssertTrue(reason.contains("outside the supported OS range"), reason)
        XCTAssertTrue(reason.contains("macOS 13.6"), reason)
    }

    func testMacOS14IsAdmitted() {
        let id = identity(chip: .m2, osMajor: 14, osMinor: 7)
        XCTAssertTrue(id.isSupportedPlatform)
        XCTAssertNil(id.unsupportedReason)
    }

    func testTahoeIsAdmitted() {
        let id = identity(chip: .m2, osMajor: 26, osMinor: 1)
        XCTAssertTrue(id.isSupportedPlatform)
        XCTAssertNil(id.unsupportedReason)
    }

    func testMacOS27IsAdmitted() {
        let id = identity(chip: .m2, osMajor: 27, osMinor: 0)
        XCTAssertTrue(id.isSupportedPlatform)
        XCTAssertNil(id.unsupportedReason)
    }

    func testMacOS28AndBeyondAreOutOfRange() {
        let id = identity(chip: .m2, osMajor: 28)
        XCTAssertFalse(id.isSupportedPlatform)
        XCTAssertTrue((id.unsupportedReason ?? "").contains("outside the supported OS range"))
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
            "BatteryControl supports Apple Silicon Macs from M1 through M4 running macOS 14 Sonoma, macOS 15 Sequoia, macOS 26 Tahoe, or macOS 27."
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

    // MARK: OSGeneration model

    func testOSGenerationMapping() {
        XCTAssertEqual(OSGeneration.from(major: 14), .sonoma)
        XCTAssertEqual(OSGeneration.from(major: 15), .sequoia)
        XCTAssertEqual(OSGeneration.from(major: 26), .tahoe)
        XCTAssertEqual(OSGeneration.from(major: 27), .macos27)
        XCTAssertNil(OSGeneration.from(major: 13))
        XCTAssertNil(OSGeneration.from(major: 16))
        XCTAssertNil(OSGeneration.from(major: 25))
        XCTAssertNil(OSGeneration.from(major: 28))
    }

    func testOSGenerationDisplayNames() {
        XCTAssertEqual(OSGeneration.sonoma.displayName, "macOS 14 Sonoma")
        XCTAssertEqual(OSGeneration.sequoia.displayName, "macOS 15 Sequoia")
        XCTAssertEqual(OSGeneration.tahoe.displayName, "macOS 26 Tahoe")
        XCTAssertEqual(OSGeneration.macos27.displayName, "macOS 27")
    }

    func testNativeChargeLimitFeaturePresence() {
        // Before 26.4: no native feature.
        XCTAssertFalse(OSGeneration.hasNativeChargeLimit(major: 14, minor: 7))
        XCTAssertFalse(OSGeneration.hasNativeChargeLimit(major: 15, minor: 8))
        XCTAssertFalse(OSGeneration.hasNativeChargeLimit(major: 26, minor: 3))
        // 26.4+: the feature exists.
        XCTAssertTrue(OSGeneration.hasNativeChargeLimit(major: 26, minor: 4))
        XCTAssertTrue(OSGeneration.hasNativeChargeLimit(major: 26, minor: 5))
        // macOS 27: probably present (static assumption; the daemon probes
        // live state and never relies on this flag for control decisions).
        XCTAssertTrue(OSGeneration.hasNativeChargeLimit(major: 27, minor: 0))
    }

    // MARK: Native-charge-limit ownership

    func testNativeStateBeforeFeatureExistsIsNotEngaged() {
        let state = OwnershipDecisions.nativeState(fromSmartBattery: [:], osMajor: 15, osMinor: 8)
        XCTAssertFalse(state.featureExistsOnThisOS)
        XCTAssertNil(state.nativeLimitEngaged)
    }

    func testNativeStateExtractionFromRegistryCandidates() {
        let smart: [String: Any] = ["ChargingControlMode": 1]
        let state = OwnershipDecisions.nativeState(fromSmartBattery: smart, osMajor: 26, osMinor: 4)
        XCTAssertTrue(state.featureExistsOnThisOS)
        XCTAssertEqual(state.nativeLimitEngaged, true)

        let off = OwnershipDecisions.nativeState(fromSmartBattery: ["ChargeLimitMode": 0], osMajor: 26, osMinor: 4)
        XCTAssertEqual(off.nativeLimitEngaged, false)

        let unknown = OwnershipDecisions.nativeState(fromSmartBattery: [:], osMajor: 26, osMinor: 4)
        XCTAssertEqual(unknown.nativeLimitEngaged, nil)
    }

    func testOwnershipBatteryControlPolicyWins() {
        for mode in [ControlMode.hysteresis, .fixedTarget] {
            let owner = OwnershipDecisions.owner(
                policyMode: mode,
                native: NativeChargeLimitState(featureExistsOnThisOS: true, nativeLimitEngaged: true)
            )
            XCTAssertEqual(owner, .batteryControl, "An active BatteryControl policy owns control (\(mode))")
        }
    }

    func testOwnershipNativeWhenPassthroughAndNativeEngaged() {
        let owner = OwnershipDecisions.owner(
            policyMode: .passthrough,
            native: NativeChargeLimitState(featureExistsOnThisOS: true, nativeLimitEngaged: true)
        )
        XCTAssertEqual(owner, .nativeAppleLimit)
    }

    func testOwnershipUndeterminedWhenPassthroughWithoutNative() {
        // No native feature (macOS 15).
        let on15 = OwnershipDecisions.owner(
            policyMode: .passthrough,
            native: NativeChargeLimitState(featureExistsOnThisOS: false, nativeLimitEngaged: nil)
        )
        XCTAssertEqual(on15, .undetermined)
        // Native feature exists but state unreadable — never guessed.
        let unknown = OwnershipDecisions.owner(
            policyMode: .passthrough,
            native: NativeChargeLimitState(featureExistsOnThisOS: true, nativeLimitEngaged: nil)
        )
        XCTAssertEqual(unknown, .undetermined)
        // Feature exists, observed not engaged.
        let off = OwnershipDecisions.owner(
            policyMode: .passthrough,
            native: NativeChargeLimitState(featureExistsOnThisOS: true, nativeLimitEngaged: false)
        )
        XCTAssertEqual(off, .undetermined)
    }

    func testOwnershipExplanations() {
        let bc = OwnershipDecisions.explanation(
            owner: .batteryControl,
            native: .unknown,
            policyMode: .hysteresis
        )
        XCTAssertTrue(bc.contains("BatteryControl"), bc)
        let native = OwnershipDecisions.explanation(
            owner: .nativeAppleLimit,
            native: NativeChargeLimitState(featureExistsOnThisOS: true, nativeLimitEngaged: true),
            policyMode: .passthrough
        )
        XCTAssertTrue(native.contains("80"), native)
    }
}
