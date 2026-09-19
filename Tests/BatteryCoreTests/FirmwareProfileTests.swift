import XCTest
@testable import BatteryCore

/// Integration tests for the firmware compatibility profile architecture:
/// classification tiers, profile-library integrity, backend selection under
/// tiers, and the policy → firmware-limit translation used for recovery.
final class FirmwareProfileTests: XCTestCase {

    // MARK: Identity helpers

    /// The exact hardware configuration verified on 2026-09-13.
    private var verifiedIdentity: PlatformIdentity {
        PlatformIdentity(
            chipGeneration: .m3,
            isAppleSilicon: true,
            macModelIdentifier: "Mac15,13",
            marketingModelName: "MacBook Air 13\" (M3, 2024)",
            osMajor: 15,
            osMinor: 8,
            osPatch: 0,
            osBuild: "24H23",
            systemFirmwareBuild: "20457.1.29"
        )
    }

    private func identity(
        model: String = "Mac15,13",
        firmware: String? = "20457.1.29",
        osMajor: Int = 15
    ) -> PlatformIdentity {
        PlatformIdentity(
            chipGeneration: .m3,
            isAppleSilicon: true,
            macModelIdentifier: model,
            marketingModelName: model,
            osMajor: osMajor,
            osMinor: 8,
            osPatch: 0,
            osBuild: "24H23",
            systemFirmwareBuild: firmware
        )
    }

    // MARK: Classification tiers

    func testVerifiedMachineClassifiesAsVerified() {
        let tier = FirmwareProfileLibrary.classify(
            identity: verifiedIdentity,
            detectedFamily: .firmwareLimit,
            systemFirmwareBuild: verifiedIdentity.systemFirmwareBuild
        )
        XCTAssertEqual(tier, .verified)
    }

    func testSameFamilyDifferentBuildIsCompatibleByCapability() {
        let tier = FirmwareProfileLibrary.classify(
            identity: identity(firmware: "99999.0.0"),
            detectedFamily: .firmwareLimit,
            systemFirmwareBuild: "99999.0.0"
        )
        XCTAssertEqual(tier, .compatibleByCapability)
    }

    func testMissingFirmwareBuildDegradesToCompatibleByCapability() {
        let tier = FirmwareProfileLibrary.classify(
            identity: identity(firmware: nil),
            detectedFamily: .firmwareLimit,
            systemFirmwareBuild: nil
        )
        XCTAssertEqual(tier, .compatibleByCapability)
    }

    func testDifferentModelSameFirmwareIsCompatibleByCapability() {
        // Same firmware build but a different machine: the evidence does not
        // transfer to the exact-model check.
        let tier = FirmwareProfileLibrary.classify(
            identity: identity(model: "Mac15,6", firmware: "20457.1.29"),
            detectedFamily: .firmwareLimit,
            systemFirmwareBuild: "20457.1.29"
        )
        XCTAssertEqual(tier, .compatibleByCapability)
    }

    func testNoDetectedFamilyIsUntested() {
        let tier = FirmwareProfileLibrary.classify(
            identity: verifiedIdentity,
            detectedFamily: .none,
            systemFirmwareBuild: verifiedIdentity.systemFirmwareBuild
        )
        XCTAssertEqual(tier, .untested)
    }

    func testUnsupportedPlatformClassifiesAsUnsupported() {
        // macOS 28 is outside the (now four-generation) gate.
        var unsupported = verifiedIdentity
        unsupported.osMajor = 28
        let tier = FirmwareProfileLibrary.classify(
            identity: unsupported,
            detectedFamily: .firmwareLimit,
            systemFirmwareBuild: unsupported.systemFirmwareBuild
        )
        XCTAssertEqual(tier, .unsupported)
    }

    func testMacOS14ClassifiesLikeAnyOtherOS() {
        // OS version is admission, never classification: a macOS 14 machine
        // with the exact verified hardware/firmware identity classifies as
        // verified; a macOS 14 machine with an unknown signature stays
        // untested (read-only). The SMC probe — not the OS — decides.
        var sonoma = verifiedIdentity
        sonoma.osMajor = 14
        sonoma.osMinor = 7
        sonoma.osBuild = "23H124"
        let exact = FirmwareProfileLibrary.classify(
            identity: sonoma,
            detectedFamily: .firmwareLimit,
            systemFirmwareBuild: sonoma.systemFirmwareBuild
        )
        XCTAssertEqual(exact, .verified)

        var unknownSonoma = sonoma
        unknownSonoma.macModelIdentifier = "Mac99,9"
        let untested = FirmwareProfileLibrary.classify(
            identity: unknownSonoma,
            detectedFamily: .firmwareLimit,
            systemFirmwareBuild: unknownSonoma.systemFirmwareBuild
        )
        XCTAssertEqual(untested, .compatibleByCapability)
    }

    func testMacOS26And27ClassifyLikeAnyOtherOS() {
        // Tahoe and 27 are admitted OS generations. Classification keys on
        // machine + boot firmware build — the things SMC behavior actually
        // depends on — so an OS upgrade on the SAME machine/firmware keeps
        // the verified evidence valid, while a different firmware build is
        // never auto-promoted.
        var tahoe = verifiedIdentity
        tahoe.osMajor = 26
        tahoe.osMinor = 4
        tahoe.osBuild = "25G74"
        XCTAssertEqual(
            FirmwareProfileLibrary.classify(
                identity: tahoe,
                detectedFamily: .firmwareLimit,
                systemFirmwareBuild: tahoe.systemFirmwareBuild
            ),
            .verified,
            "Same machine + same boot firmware after an OS upgrade → evidence still holds"
        )

        var macos27 = verifiedIdentity
        macos27.osMajor = 27
        macos27.osMinor = 0
        macos27.osBuild = "26A100"
        XCTAssertEqual(
            FirmwareProfileLibrary.classify(
                identity: macos27,
                detectedFamily: .none,
                systemFirmwareBuild: macos27.systemFirmwareBuild
            ),
            .untested,
            "No detected mechanism on macOS 27 → read-only, exactly like any other OS"
        )
    }

    func testLegacyFamilyNeverClaimsFirmwareLimitVerification() {
        let tier = FirmwareProfileLibrary.classify(
            identity: verifiedIdentity,
            detectedFamily: .legacy,
            systemFirmwareBuild: verifiedIdentity.systemFirmwareBuild
        )
        XCTAssertNotEqual(tier, .verified, "The legacy family has no hardware-verified profile in BatteryControl's own evidence set")
        XCTAssertEqual(tier, .compatibleByCapability)
    }

    // MARK: Profile library integrity

    func testFirstProfileIsTheVerifiedM3Configuration() {
        let first = FirmwareProfileLibrary.all.first
        XCTAssertEqual(first?.id, "apple-silicon-20xxx-firmware-limit")
        XCTAssertEqual(first?.evidence?.modelIdentifier, "Mac15,13")
        XCTAssertEqual(first?.evidence?.systemFirmwareBuild, "20457.1.29")
        XCTAssertEqual(first?.evidence?.osBuild, "24H23")
    }

    func testVerifiedProfileDocumentsExactSemantics() {
        let profile = FirmwareProfileLibrary.appleSilicon20xxxFirmwareLimit
        // Activation bytes.
        XCTAssertEqual(profile.keyProfile.firmwareLimitActivationOff, 0x00)
        XCTAssertEqual(profile.keyProfile.firmwareLimitActivationActive, 0x02)
        // Keys.
        XCTAssertEqual(profile.keyProfile.firmwareLimitKeys, ["bfF0", "bfD0", "bfE0"])
        XCTAssertEqual(profile.keyProfile.adapterKeys.contains("CHIE"), true)
        // CHIE cuts with 0x08 — never 0x01.
        XCTAssertEqual(profile.keyProfile.adapterCutValue, 0x08)
        // Little-endian percentages + required write order.
        XCTAssertEqual(profile.keyProfile.limitPercentEncodingIsLittleEndian, true)
        XCTAssertEqual(profile.keyProfile.requiresDeactivateBeforeWrite, true)
    }

    func testProvenBehaviorDocumentsRequiredFacts() {
        let proven = FirmwareProfileLibrary.appleSilicon20xxxFirmwareLimit.evidence!.provenBehavior.joined(separator: "\n")
        XCTAssertTrue(proven.contains("0x00 inactive / 0x02 active"))
        XCTAssertTrue(proven.contains("little-endian"))
        XCTAssertTrue(proven.contains("deactivate"))
        XCTAssertTrue(proven.contains("read-back verified"))
        XCTAssertTrue(proven.contains("automatically deactivates"))
    }

    func testEveryProfileHasUniqueIdAndConsistentEvidence() {
        var seen = Set<String>()
        for profile in FirmwareProfileLibrary.all {
            XCTAssertTrue(seen.insert(profile.id).inserted, "duplicate profile id \(profile.id)")
            if profile.evidence == nil {
                // Profiles without evidence must not be treated as verified.
                XCTAssertTrue(profile.notes.count > 0, "\(profile.id) needs notes explaining its evidence status")
            }
        }
    }

    func testProfileRoundTripsThroughCodable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(FirmwareProfileLibrary.appleSilicon20xxxFirmwareLimit)
        let decoded = try JSONDecoder().decode(FirmwareProfile.self, from: data)
        XCTAssertEqual(decoded, FirmwareProfileLibrary.appleSilicon20xxxFirmwareLimit)
    }

    // MARK: Boot-build parsing

    func testParseBootBuildVariants() {
        XCTAssertEqual(FirmwareProfileLibrary.parseBootBuild(from: "mBoot-20457.1.29"), "20457.1.29")
        XCTAssertEqual(FirmwareProfileLibrary.parseBootBuild(from: "iBoot-12345.0.0"), "12345.0.0")
        XCTAssertEqual(FirmwareProfileLibrary.parseBootBuild(from: "20457.1.29"), "20457.1.29")
        XCTAssertNil(FirmwareProfileLibrary.parseBootBuild(from: "  "))
    }

    // MARK: Selection interacts with tiers honestly

    func testSelectionPicksFirmwareLimitFamilyWhenCapabilitiesReported() {
        // The runtime probe reports firmwareLimit capabilities on the M3 —
        // selection must pick it regardless of tier, because the engine
        // verifies every action anyway.
        let caps = BatteryCapabilities(
            supportsUpperLimit: true,
            supportsLowerLimit: true,
            supportsFixedLimit: true,
            supportsForceDischarge: true,
            supportsForceCharge: true,
            supportsCalibration: true,
            supportsSMC: true,
            supportsVerifiedChargingControl: true
        )
        let selected = BackendSelector.select(capabilities: [.firmwareLimit: caps])
        XCTAssertEqual(selected, .firmwareLimit)
    }

    func testUntestedTierStillAllowsCapabilityDrivenSelection() {
        // Classification is evidence bookkeeping; it must not block a
        // runtime-verified capability. A machine with a novel-but-working
        // signature is selected by capability, and every action is verified
        // at runtime.
        let tier = FirmwareProfileLibrary.classify(
            identity: identity(firmware: "99999.99.99"),
            detectedFamily: .firmwareLimit,
            systemFirmwareBuild: "99999.99.99"
        )
        XCTAssertEqual(tier, .compatibleByCapability)
        // And selection is purely capability-based:
        let caps = BatteryCapabilities(
            supportsUpperLimit: true, supportsLowerLimit: true, supportsFixedLimit: true,
            supportsForceDischarge: false, supportsForceCharge: true, supportsCalibration: true,
            supportsSMC: true, supportsVerifiedChargingControl: true
        )
        XCTAssertEqual(BackendSelector.select(capabilities: [.firmwareLimit: caps]), .firmwareLimit)
    }

    // MARK: Policy → firmware-limit translation (recovery path)

    func testPolicyTranslationRoundTripForRecovery() {
        // After a daemon restart, configure() re-programs from the persisted
        // policy; the translation must be stable for the tested band.
        let policy = ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 70)
        let first = FirmwareLimitValidation.requestedLimit(policy: policy, override: .none)
        let second = FirmwareLimitValidation.requestedLimit(policy: policy, override: .none)
        XCTAssertEqual(first?.upper, second?.upper)
        XCTAssertEqual(first?.lower, second?.lower)
        XCTAssertEqual(first?.upper, 80)
        XCTAssertEqual(first?.lower, 70)
    }

    func testForceChargeTargetAboveCeilingClearsLimit() {
        let policy = ChargingPolicy(mode: .hysteresis, upperLimit: 80, lowerLimit: 70)
        XCTAssertNil(FirmwareLimitValidation.requestedLimit(policy: policy, override: .forceCharge(targetPercent: 100)))
        XCTAssertNotNil(FirmwareLimitValidation.requestedLimit(policy: policy, override: .forceCharge(targetPercent: 75)))
    }

    // MARK: Validation boundaries (defense in depth for writes)

    func testValidationRejectsUnsafeLimits() {
        XCTAssertNotNil(FirmwareLimitValidation.problem(upper: 80, lower: 80))
        XCTAssertNotNil(FirmwareLimitValidation.problem(upper: 70, lower: 80))
        XCTAssertNotNil(FirmwareLimitValidation.problem(upper: 101, lower: 60))
        XCTAssertNotNil(FirmwareLimitValidation.problem(upper: 80, lower: 4))
        // Wide, low-but-safe bands are accepted.
        XCTAssertNil(FirmwareLimitValidation.problem(upper: 20, lower: 10))
        XCTAssertNil(FirmwareLimitValidation.problem(upper: 100, lower: 5))
    }

    // MARK: Summary text

    func testSummaryMentionsUncertaintyForCompatibleByCapability() {
        let summary = FirmwareProfileLibrary.summary(
            for: .compatibleByCapability,
            identity: verifiedIdentity,
            detectedFamily: .firmwareLimit
        )
        XCTAssertTrue(summary.contains("not been hardware-verified"))
    }

    func testSummaryForVerifiedNamesTheProfile() {
        let summary = FirmwareProfileLibrary.summary(
            for: .verified,
            identity: verifiedIdentity,
            detectedFamily: .firmwareLimit
        )
        XCTAssertTrue(summary.contains("VERIFIED"))
        XCTAssertTrue(summary.contains("apple-silicon-20xxx-firmware-limit"))
    }
}
