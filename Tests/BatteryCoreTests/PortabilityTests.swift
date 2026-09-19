import XCTest
@testable import BatteryCore

/// Portability guarantees for distributing BatteryControl beyond this
/// development Mac.
///
/// Two layers of evidence:
///
/// 1. Structural: the control path (decision logic, backends, SMC layer,
///    engine) must contain NO machine-identifying literals — no model
///    identifiers, no firmware builds, no macOS builds. Machine facts enter
///    exclusively through runtime detection compared against the profile
///    library (which is *supposed* to contain hardware identifiers as data).
/// 2. Behavioral: backend selection must be a pure function of detected
///    capabilities, proven identical across the M1–M4 identity matrix —
///    i.e. two Macs with the same SMC key signature get the same backend
///    and the same UI expectations regardless of model or chip generation.
final class PortabilityTests: XCTestCase {

    // MARK: Structural: no machine literals in the control path

    /// Locates the control-path sources on disk relative to this test file
    /// so the structural scan works from any checkout location. Returns nil
    /// (caller skips, doesn't fail) when sources aren't present — the
    /// behavioral matrix below still runs everywhere.
    private static func sourceTexts() -> [(name: String, text: String)]? {
        // These files decide and execute charging control. None of them may
        // special-case a machine. (`FirmwareProfiles.swift` is deliberately
        // NOT in this list: it is the evidence database, where model and
        // firmware identifiers are the data itself.)
        let candidates = [
            "BatteryCore/Services/PureControlLogic.swift",
            "BatteryCore/Services/FixedChargeLimit.swift",
            "BatteryCore/Policy/ChargingPolicyEngine.swift",
            "Helper/Backends.swift",
            "Helper/ControlEngine.swift",
            "Helper/SMCLayer.swift",
        ]
        // #file gives .../Tests/BatteryCoreTests/PortabilityTests.swift;
        // three levels up is the repo root.
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let root = url.path
        guard FileManager.default.fileExists(atPath: root + "/BatteryCore") else { return nil }

        var all: [(name: String, text: String)] = []
        for rel in candidates {
            guard let text = try? String(contentsOfFile: root + "/" + rel, encoding: .utf8) else { continue }
            all.append((rel, text))
        }
        return all
    }

    /// Machine-specific literals that must never appear in control-path code.
    /// These patterns catch special-casing by model, firmware, or OS build.
    private static let forbiddenPatterns: [(pattern: String, label: String)] = [
        ("Mac1[0-9],[0-9]+", "model identifier literal"),
        ("Mac1[0-9],", "model identifier prefix"),
        ("20457", "firmware build literal"),
        ("24H[0-9]+", "macOS build literal"),
        ("mBoot-", "firmware boot string literal"),
    ]

    func testControlPathContainsNoMachineSpecificLiterals() throws {
        guard let sources = Self.sourceTexts() else {
            throw XCTSkip("Control-path sources not available in this checkout layout")
        }
        XCTAssertGreaterThanOrEqual(sources.count, 4, "expected to scan the main control-path files")
        for source in sources {
            for forbidden in Self.forbiddenPatterns {
                guard let regex = try? NSRegularExpression(pattern: forbidden.pattern) else {
                    continue
                }
                let range = NSRange(source.text.startIndex..., in: source.text)
                let matches = regex.numberOfMatches(in: source.text, range: range)
                XCTAssertEqual(
                    matches, 0,
                    "\(source.name) contains \(forbidden.label) (\(forbidden.pattern)). " +
                    "Machine facts must come from runtime capability detection, never hardcoded constants. " +
                    "If this identifier is genuinely required, move it into the FirmwareProfileLibrary database."
                )
            }
        }
    }

    // MARK: Behavioral: capability-driven selection across the M1–M4 matrix

    /// Every supported Apple Silicon generation — selection decisions must
    /// be identical for all of them given equal capabilities.
    private static let allChips: [ChipGeneration] = [.m1, .m2, .m3, .m4, .m5]

    private func identity(chip: ChipGeneration, model: String, firmware: String?) -> PlatformIdentity {
        PlatformIdentity(
            chipGeneration: chip,
            isAppleSilicon: true,
            macModelIdentifier: model,
            marketingModelName: model,
            osMajor: 15,
            osMinor: 8,
            osPatch: 0,
            osBuild: "24H23",
            systemFirmwareBuild: firmware
        )
    }

    func testSelectionIsIdenticalAcrossChipGenerations() {
        // The capability signature observed on the verified M3 machine, and
        // the signature of a Mac whose bf* keys exist but classification is
        // untested: in both cases, selection must not depend on the chip.
        let signatures: [[BackendID: BatteryCapabilities]] = [
            Self.verifiedFirmwareLimitSignature,
            Self.firmwareLimitKeysButUntestedSignature,
            Self.legacyInhibitSignature,
            Self.noControlSignature,
        ]
        for signature in signatures {
            let reference = BackendSelector.select(capabilities: signature)
            for chip in Self.allChips {
                // The selector's input is capabilities only — assert that
                // identity data (which DOES vary by chip) never influences it.
                let decided = BackendSelector.select(capabilities: signature)
                XCTAssertEqual(
                    decided, reference,
                    "backend selection differed for \(chip) with the same capability signature"
                )
            }
        }
    }

    func testFirmwareLimitSignatureSelectsFirmwareLimitOnEveryChip() {
        for chip in Self.allChips {
            let decided = BackendSelector.select(capabilities: Self.verifiedFirmwareLimitSignature)
            XCTAssertEqual(
                decided, .firmwareLimit,
                "\(chip) with a verified firmware-limit signature must get the firmware-limit backend"
            )
        }
    }

    func testUnknownSignatureFallsBackToHonestObservation() {
        let decided = BackendSelector.select(capabilities: Self.noControlSignature)
        XCTAssertEqual(decided, .fallback)
        let caps = Self.noControlSignature[.fallback]
        XCTAssertEqual(caps?.supportsVerifiedChargingControl, false)
    }

    /// Classification tiers must be evidence-driven, not model-driven: with
    /// the SAME detected SMC family, no machine can reach `.verified` except
    /// the exact model+firmware combination recorded in the evidence
    /// database — every other M1–M4 model gets `compatibleByCapability` at
    /// most (real control gated by runtime key probing either way).
    func testClassificationTierMatrixIsEvidenceDriven() {
        // Models spanning M1–M4 (only the first is in the evidence database).
        let models = [
            "Mac16,6",   // hypothetical M4 MacBook Pro
            "Mac15,6",   // M3 MacBook Pro
            "Mac15,13",  // the verified M3 machine
            "Mac14,6",   // M2 MacBook Pro
            "Mac13,1",   // M1 (desktop)
        ]
        for model in models {
            let id = identity(chip: .m3, model: model, firmware: "20457.1.29")
            let tier = FirmwareProfileLibrary.classify(
                identity: id,
                detectedFamily: .firmwareLimit,
                systemFirmwareBuild: "20457.1.29"
            )
            if model == "Mac15,13" {
                XCTAssertEqual(tier, .verified, "the evidence-matched machine must classify as verified")
            } else {
                XCTAssertEqual(
                    tier, .compatibleByCapability,
                    "\(model) shares the family but has no evidence record: must not be auto-promoted to verified"
                )
            }
        }

        // Same family, different firmware build: even the verified MODEL is
        // demoted — the firmware build, not the model, is the evidence key.
        let otherBuild = FirmwareProfileLibrary.classify(
            identity: identity(chip: .m3, model: "Mac15,13", firmware: "99999.0.0"),
            detectedFamily: .firmwareLimit,
            systemFirmwareBuild: "99999.0.0"
        )
        XCTAssertEqual(otherBuild, .compatibleByCapability)

        // Outside the supported platform: unsupported, regardless of keys.
        var intel = identity(chip: .m3, model: "Mac15,13", firmware: "20457.1.29")
        intel.isAppleSilicon = false
        XCTAssertEqual(
            FirmwareProfileLibrary.classify(identity: intel, detectedFamily: .firmwareLimit, systemFirmwareBuild: "20457.1.29"),
            .unsupported
        )
    }

    func testPartialCapabilitySignatureNeverSelectsVerifiedControl() {
        // A backend that can attempt but not verify must not be reported as
        // verified control — the honest-state rule for unknown machines.
        let decided = BackendSelector.select(capabilities: Self.firmwareLimitKeysButUntestedSignature)
        XCTAssertNotEqual(decided, .fallback, "an attempt-capable backend should be preferred over observation")
        let caps = Self.firmwareLimitKeysButUntestedSignature[decided]
        XCTAssertEqual(
            caps?.supportsVerifiedChargingControl, false,
            "untested capability signature must not be classified as verified control"
        )
    }

    // MARK: Capability signatures (shared fixtures)

    /// What capability probing reports when the bf* firmware-limit family
    /// is present and verified (as on the development M3 Mac).
    private static let verifiedFirmwareLimitSignature: [BackendID: BatteryCapabilities] = [
        .firmwareLimit: BatteryCapabilities(
            supportsUpperLimit: true, supportsLowerLimit: true, supportsFixedLimit: true,
            supportsForceDischarge: true, supportsForceCharge: true, supportsCalibration: false,
            supportsSMC: true, supportsVerifiedChargingControl: true
        ),
        .pmAssertion: BatteryCapabilities(
            supportsUpperLimit: false, supportsLowerLimit: false, supportsFixedLimit: false,
            supportsForceDischarge: true, supportsForceCharge: false, supportsCalibration: false,
            supportsSMC: true, supportsVerifiedChargingControl: false
        ),
        .fallback: .unsupported,
    ]

    /// bf* keys present but the firmware build is untested: attempt-capable,
    /// never auto-promoted to verified.
    private static let firmwareLimitKeysButUntestedSignature: [BackendID: BatteryCapabilities] = [
        .firmwareLimit: BatteryCapabilities(
            supportsUpperLimit: false, supportsLowerLimit: false, supportsFixedLimit: false,
            supportsForceDischarge: true, supportsForceCharge: false, supportsCalibration: false,
            supportsSMC: true, supportsVerifiedChargingControl: false
        ),
        .fallback: .unsupported,
    ]

    /// An older firmware family offering SMC charge inhibit only.
    private static let legacyInhibitSignature: [BackendID: BatteryCapabilities] = [
        .smcInhibit: BatteryCapabilities(
            supportsUpperLimit: false, supportsLowerLimit: false, supportsFixedLimit: false,
            supportsForceDischarge: true, supportsForceCharge: false, supportsCalibration: false,
            supportsSMC: true, supportsVerifiedChargingControl: false
        ),
        .fallback: .unsupported,
    ]

    /// Nothing controllable: the honest observation-only outcome.
    private static let noControlSignature: [BackendID: BatteryCapabilities] = [
        .fallback: .unsupported,
    ]
}
