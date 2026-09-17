import XCTest
@testable import BatteryCore

/// Negative-path compatibility tests (Part 13 of the audit): for every way
/// a foreign Mac's firmware can differ from the verified one, the answer
/// must be a safe failure — never a false "verified", never a crash, never
/// a speculative write to a key whose shape does not match the control
/// path. The decisions under test are the exact pure functions the daemon
/// applies before and after any hardware write.
final class CompatibilityNegativePathTests: XCTestCase {

    // MARK: Key-shape acceptance (capability detection must match the control path)

    func testAcceptsVerifiedMachineShapes() {
        // The physically verified signature: ui8 activation, ui32 ui32.
        XCTAssertTrue(FirmwareLimitValidation.keyShapesAreAcceptable(["bfF0": 1, "bfD0": 4, "bfE0": 4]))
    }

    func testAcceptsUnpopulatedMetadata() {
        // Verified hardware reports size-0 metadata for live keys; usable
        // because every write is readback-verified.
        XCTAssertTrue(FirmwareLimitValidation.keyShapesAreAcceptable(["bfF0": 0, "bfD0": 0, "bfE0": 0]))
    }

    func testRejectsWrongActivationWidth() {
        XCTAssertFalse(FirmwareLimitValidation.keyShapesAreAcceptable(["bfF0": 4, "bfD0": 4, "bfE0": 4]),
                       "a ui32-wide activation key must not be treated as the ui8 mechanism")
    }

    func testRejectsWrongPercentageWidth() {
        XCTAssertFalse(FirmwareLimitValidation.keyShapesAreAcceptable(["bfF0": 1, "bfD0": 2, "bfE0": 4]),
                       "a 2-byte upper-percent key must not be programmed as ui32")
        XCTAssertFalse(FirmwareLimitValidation.keyShapesAreAcceptable(["bfF0": 1, "bfD0": 4, "bfE0": 8]),
                       "an 8-byte lower-percent key must not be programmed as ui32")
    }

    func testRejectsMissingKeyFromSignature() {
        XCTAssertFalse(FirmwareLimitValidation.keyShapesAreAcceptable(["bfF0": 1, "bfD0": 4]),
                       "bfE0 missing: the hysteresis mechanism requires all three keys")
        XCTAssertFalse(FirmwareLimitValidation.keyShapesAreAcceptable(["bfF0": 1]),
                       "partial signature must not enable control")
        XCTAssertFalse(FirmwareLimitValidation.keyShapesAreAcceptable([:]),
                       "no keys: no control")
    }

    // MARK: Readback confirmation (write succeeded ≠ control verified)

    private func confirm(
        act: UInt8,
        upper: UInt32,
        lower: UInt32,
        requestedUpper: Int = 80,
        requestedLower: Int = 78
    ) -> Bool {
        FirmwareLimitValidation.readbackConfirms(
            activationByte: act, upperPercent: upper, lowerPercent: lower,
            requestedUpper: requestedUpper, requestedLower: requestedLower
        )
    }

    func testReadbackConfirmsExactProgrammedState() {
        XCTAssertTrue(confirm(act: 0x02, upper: 80, lower: 78))
    }

    func testReadbackRejectsInactiveActivation() {
        XCTAssertFalse(confirm(act: 0x00, upper: 80, lower: 78),
                       "writes accepted but activation off: control is NOT verified")
    }

    func testReadbackRejectsUnexpectedActivationValue() {
        XCTAssertFalse(confirm(act: 0x01, upper: 80, lower: 78),
                       "only 0x02 is the verified-active state on the verified profile")
    }

    func testReadbackRejectsUpperMismatch() {
        XCTAssertFalse(confirm(act: 0x02, upper: 79, lower: 78),
                       "firmware stored a different upper value: not verified")
    }

    func testReadbackRejectsLowerMismatch() {
        XCTAssertFalse(confirm(act: 0x02, upper: 80, lower: 70),
                       "firmware stored a different lower value: not verified")
    }

    func testReadbackRejectsPercentTruncation() {
        // A requested 80 stored as 79.999-ish via a truncated write must
        // not count as confirmation (UInt32 equality is strict on purpose).
        XCTAssertFalse(confirm(act: 0x02, upper: 80, lower: 79, requestedUpper: 80, requestedLower: 78))
    }

    // MARK: Value validation stays the first gate

    func testValidationRejectsUnsafeLimitsBeforeAnyWrite() {
        XCTAssertNotNil(FirmwareLimitValidation.problem(upper: 3, lower: 2), "absurdly low values must never be programmed")
        XCTAssertNotNil(FirmwareLimitValidation.problem(upper: 80, lower: 80), "empty band must never be programmed")
        XCTAssertNil(FirmwareLimitValidation.problem(upper: 80, lower: 78))
    }

    // MARK: Stale profile can never certify an incompatible signature

    func testVerifiedTierRequiresExactModelAndFirmwareMatch() {
        let base = PlatformIdentity(
            chipGeneration: .m3,
            isAppleSilicon: true,
            macModelIdentifier: "Mac15,13",
            marketingModelName: "x",
            osMajor: 15, osMinor: 8, osPatch: 0,
            osBuild: "24H23",
            systemFirmwareBuild: "20457.1.29"
        )
        // Same model, same build → verified (the evidence-matched machine).
        XCTAssertEqual(
            FirmwareProfileLibrary.classify(identity: base, detectedFamily: .firmwareLimit, systemFirmwareBuild: "20457.1.29"),
            .verified
        )
        // Same model, DIFFERENT firmware → NOT verified. A stale profile
        // must not silently certify a firmware it never ran on.
        var otherBuild = base
        otherBuild.systemFirmwareBuild = "21000.0.0"
        XCTAssertEqual(
            FirmwareProfileLibrary.classify(identity: otherBuild, detectedFamily: .firmwareLimit, systemFirmwareBuild: "21000.0.0"),
            .compatibleByCapability
        )
        // Different model, same firmware → NOT verified either.
        var otherModel = base
        otherModel.macModelIdentifier = "Mac16,1"
        XCTAssertEqual(
            FirmwareProfileLibrary.classify(identity: otherModel, detectedFamily: .firmwareLimit, systemFirmwareBuild: "20457.1.29"),
            .compatibleByCapability
        )
    }

    func testNovelSignatureNeverReachesVerified() {
        let identity = PlatformIdentity(
            chipGeneration: .m4,
            isAppleSilicon: true,
            macModelIdentifier: "Mac16,9",
            marketingModelName: "x",
            osMajor: 15, osMinor: 8, osPatch: 0,
            osBuild: "25G99",
            systemFirmwareBuild: "22000.0.0"
        )
        // No SMC family detected (novel signature): read-only by tier.
        XCTAssertEqual(
            FirmwareProfileLibrary.classify(identity: identity, detectedFamily: .none, systemFirmwareBuild: "22000.0.0"),
            .untested
        )
        XCTAssertFalse(FirmwareProfileLibrary.shouldAllowControlWrites(.untested))
        // Even a recognized family stays capability-gated, never "verified".
        XCTAssertEqual(
            FirmwareProfileLibrary.classify(identity: identity, detectedFamily: .firmwareLimit, systemFirmwareBuild: "22000.0.0"),
            .compatibleByCapability
        )
    }

    func testReadonlyTierCannotWrite() {
        XCTAssertFalse(FirmwareProfileLibrary.shouldAllowControlWrites(.untested))
        XCTAssertFalse(FirmwareProfileLibrary.shouldAllowControlWrites(.unsupported))
        XCTAssertTrue(FirmwareProfileLibrary.shouldAllowControlWrites(.verified))
        XCTAssertTrue(FirmwareProfileLibrary.shouldAllowControlWrites(.compatibleByCapability),
                      "capability-compatible machines may attempt control — gated by per-action readback verification")
    }

    // MARK: Compatibility report structure (sanitized by construction)

    func testPlatformIdentityCarriesNoPersonalIdentifiers() throws {
        // The compatibility report serializes PlatformIdentity + key
        // signature. Its Codable surface must not contain serials, user
        // names, hardware UUIDs, or filesystem paths.
        let identity = PlatformDetector.detect()
        let data = try JSONEncoder().encode(identity)
        let json = String(data: data, encoding: .utf8) ?? ""
        for forbidden in ["Serial", "serial", "UUID", "userName", "homeDir", "/Users/"] {
            XCTAssertFalse(json.contains(forbidden), "PlatformIdentity JSON must not contain \(forbidden)")
        }
    }
}
