import Foundation

/// Firmware compatibility architecture for BatteryControl.
///
/// The goal is a growing library of VERIFIED Apple Silicon firmware/backend
/// combinations, built from hardware evidence rather than assumptions.
///
/// Supporting a mechanism is always decided at runtime by probing the SMC
/// keys that are actually present (never by macOS version or Mac model
/// alone). The profile library complements that probe with a confidence
/// tier: how much hardware evidence backs this particular firmware build's
/// behavior.

/// Confidence tier of a firmware/backend combination.
public enum FirmwareProfileTier: String, Codable, Sendable, CaseIterable {
    /// Exercised on real hardware with readback verification AND observed
    /// battery-state enforcement. Documented with full evidence.
    case verified
    /// The SMC key signature matches a verified profile's mechanism, but
    /// this exact firmware build has not itself been exercised. Behavior is
    /// expected to match by capability; the engine verifies every action
    /// anyway and degrades honestly if it does not.
    case compatibleByCapability
    /// No profile matches and the key signature is novel. Read-only
    /// diagnostics only until evidence is collected.
    case untested
    /// Platform gate rejected the machine (outside M1–M4 / macOS 15), or
    /// no control mechanism was detected at all.
    case unsupported
}

/// The SMC key layout of a control mechanism family.
public struct SMCKeyProfile: Codable, Equatable, Sendable {
    /// Charging-inhibit keys (name, expected size in bytes or nil when the
    /// firmware reports unpopulated metadata).
    public var chargingKeys: [String]
    /// Adapter-cut (inflow disable) keys.
    public var adapterKeys: [String]
    /// Firmware-managed charge-limit keys (activation, upper, lower).
    public var firmwareLimitKeys: [String]

    /// Inhibit value written to charging keys to STOP charging.
    public var chargingInhibitValue: Int
    /// Value written to the adapter key to CUT inflow. Distinguishes the
    /// 0x01 family (CH0I/CH0J) from the 0x08 family (CHIE).
    public var adapterCutValue: Int
    /// Firmware-limit activation byte values (off / active), when present.
    public var firmwareLimitActivationOff: Int?
    public var firmwareLimitActivationActive: Int?
    /// Limit percentages are little-endian ui32 (true for the bf* family,
    /// unlike conventional big-endian SMC ui32 keys).
    public var limitPercentEncodingIsLittleEndian: Bool
    /// The firmware requires deactivate → upper → lower → activate.
    public var requiresDeactivateBeforeWrite: Bool

    public init(
        chargingKeys: [String],
        adapterKeys: [String],
        firmwareLimitKeys: [String],
        chargingInhibitValue: Int,
        adapterCutValue: Int,
        firmwareLimitActivation: (off: Int, active: Int)?,
        limitPercentEncodingIsLittleEndian: Bool,
        requiresDeactivateBeforeWrite: Bool
    ) {
        self.chargingKeys = chargingKeys
        self.adapterKeys = adapterKeys
        self.firmwareLimitKeys = firmwareLimitKeys
        self.chargingInhibitValue = chargingInhibitValue
        self.adapterCutValue = adapterCutValue
        self.firmwareLimitActivationOff = firmwareLimitActivation?.off
        self.firmwareLimitActivationActive = firmwareLimitActivation?.active
        self.limitPercentEncodingIsLittleEndian = limitPercentEncodingIsLittleEndian
        self.requiresDeactivateBeforeWrite = requiresDeactivateBeforeWrite
    }
}

/// The hardware evidence backing a verified profile.
public struct VerifiedEvidence: Codable, Equatable, Sendable {
    public var chip: String
    public var modelIdentifier: String
    /// System (boot) firmware build, e.g. "20457.1.29" from mBoot-20457.1.29.
    public var systemFirmwareBuild: String
    public var osVersion: String
    public var osBuild: String
    /// Human-readable summary of what was actually proven on hardware.
    public var provenBehavior: [String]
    /// Date of the hardware session (ISO-8601, UTC).
    public var verifiedOn: String

    public init(
        chip: String,
        modelIdentifier: String,
        systemFirmwareBuild: String,
        osVersion: String,
        osBuild: String,
        provenBehavior: [String],
        verifiedOn: String
    ) {
        self.chip = chip
        self.modelIdentifier = modelIdentifier
        self.systemFirmwareBuild = systemFirmwareBuild
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.provenBehavior = provenBehavior
        self.verifiedOn = verifiedOn
    }
}

/// One entry in the firmware compatibility library.
public struct FirmwareProfile: Codable, Equatable, Sendable {
    /// Stable identifier, e.g. "apple-silicon-20xxx-firmware-limit".
    public var id: String
    public var title: String
    /// Which SMC control family this profile describes.
    public var controlFamily: String
    public var keyProfile: SMCKeyProfile
    /// Nil for tiers below `.verified`.
    public var evidence: VerifiedEvidence?
    /// Notes for users and future maintainers (caveats, boundaries).
    public var notes: [String]

    public init(
        id: String,
        title: String,
        controlFamily: String,
        keyProfile: SMCKeyProfile,
        evidence: VerifiedEvidence?,
        notes: [String]
    ) {
        self.id = id
        self.title = title
        self.controlFamily = controlFamily
        self.keyProfile = keyProfile
        self.evidence = evidence
        self.notes = notes
    }
}

/// The firmware compatibility library. Append entries as hardware evidence
/// is collected; classification and diagnostics read from here.
public enum FirmwareProfileLibrary {

    /// Profile #1 — the first hardware-verified configuration:
    /// MacBook Air M3 (Mac15,13), system firmware mBoot-20457.1.29,
    /// macOS 15.8 (24H23). The bf* firmware-managed charge limit was
    /// programmed (80/70), readback-verified, and observed enforcing on
    /// real hardware (charging refused above the upper limit while wall
    /// power was connected). CHIE/CH0J adapter keys are present for
    /// force discharge; classic CH0B/CH0C/CH0I/CHTE are absent.
    public static let appleSilicon20xxxFirmwareLimit = FirmwareProfile(
        id: "apple-silicon-20xxx-firmware-limit",
        title: "20xxx-firmware firmware-managed charge limit (bfF0/bfD0/bfE0)",
        controlFamily: "firmwareLimit",
        keyProfile: SMCKeyProfile(
            chargingKeys: [],
            adapterKeys: ["CHIE", "CH0J"],
            firmwareLimitKeys: ["bfF0", "bfD0", "bfE0"],
            chargingInhibitValue: 0,
            adapterCutValue: 0x08,
            firmwareLimitActivation: (off: 0x00, active: 0x02),
            limitPercentEncodingIsLittleEndian: true,
            requiresDeactivateBeforeWrite: true
        ),
        evidence: VerifiedEvidence(
            chip: "Apple M3",
            modelIdentifier: "Mac15,13",
            systemFirmwareBuild: "20457.1.29",
            osVersion: "macOS 15.8",
            osBuild: "24H23",
            provenBehavior: [
                "bfF0 = 0x00 inactive / 0x02 active (ui8 activation)",
                "bfD0 = upper percentage (ui32, little-endian)",
                "bfE0 = lower percentage (ui32, little-endian)",
                "Write sequence: deactivate (bfF0=0) → upper → lower → activate (bfF0=2)",
                "Every write read-back verified, per step and after activation",
                "Failed verification automatically deactivates the limit",
                "Charging refused above the upper limit with wall power connected (−390 mA discharge at 92% while AC attached)",
                "Limit state enforced by the SMC autonomously; read identically across processes",
            ],
            verifiedOn: "2026-09-13"
        ),
        notes: [
            "Classic CH0B/CH0C/CH0I/CHTE keys are absent on this firmware generation.",
            "SMC reports unpopulated (size 0) key metadata for live keys; presence must be decided by direct reads.",
            "Verified on ONE machine/build. Every 20xxx firmware must not be assumed to behave identically — new builds start at compatibleByCapability and are promoted only with evidence.",
            "CHIE cuts inflow with value 0x08 (CH0I/CH0J use 0x01) — never write 0x01 to CHIE.",
        ]
    )

    /// Profile 2 — the classic Apple Silicon charging keys, verified by the
    /// battery-limiter project's documented hardware behavior (capability
    /// level: documented by third-party hardware evidence, not exercised by
    /// BatteryControl's own test suite yet).
    public static let appleSiliconLegacySMCInhibit = FirmwareProfile(
        id: "apple-silicon-legacy-smc-inhibit",
        title: "Legacy Apple Silicon SMC charge inhibit (CH0B/CH0C + CH0I)",
        controlFamily: "legacy",
        keyProfile: SMCKeyProfile(
            chargingKeys: ["CH0B", "CH0C"],
            adapterKeys: ["CH0I"],
            firmwareLimitKeys: [],
            chargingInhibitValue: 0x02,
            adapterCutValue: 0x01,
            firmwareLimitActivation: nil,
            limitPercentEncodingIsLittleEndian: false,
            requiresDeactivateBeforeWrite: false
        ),
        evidence: nil,
        notes: [
            "Semantics documented by MIT-licensed projects (battery-limiter/BatFi) on pre-20xxx Apple Silicon firmware.",
            "Absent on 20xxx-firmware machines such as the verified M3 profile.",
        ]
    )

    /// All entries, in discovery order. The first verified profile leads.
    public static let builtIn: [FirmwareProfile] = [
        appleSilicon20xxxFirmwareLimit,
        appleSiliconLegacySMCInhibit,
    ]

    /// Profiles loaded from the distributable compatibility database
    /// (JSON). Entries with the same id as a built-in profile override it,
    /// so the community database can update evidence without an app update.
    /// Populated once at startup via `loadDatabase`; thread-safe afterwards.
    private static let externalLock = NSLock()
    private static var _external: [FirmwareProfile] = []

    public static var all: [FirmwareProfile] {
        externalLock.lock()
        defer { externalLock.unlock() }
        let external = _external
        // External entries override built-ins with the same id.
        let externalIDs = Set(external.map(\.id))
        return builtIn.filter { !externalIDs.contains($0.id) } + external
    }

    /// Codable payload of the compatibility database file.
    public struct DatabasePayload: Codable, Equatable, Sendable {
        public var schemaVersion: Int
        public var profiles: [FirmwareProfile]

        public init(schemaVersion: Int, profiles: [FirmwareProfile]) {
            self.schemaVersion = schemaVersion
            self.profiles = profiles
        }
    }

    /// Errors from loading a compatibility database.
    public enum DatabaseError: Error, Equatable {
        case unsupportedSchema(Int)
        case invalidProfile(id: String, reason: String)
    }

    /// Current schema version accepted by this build.
    public static let databaseSchemaVersion = 1

    /// Load and activate a compatibility database from disk. Invalid entries
    /// are rejected individually (with an error listing the id) so one bad
    /// record cannot poison the rest; an unsupported schema is rejected
    /// wholesale — an older app must never guess at newer semantics.
    @discardableResult
    public static func loadDatabase(atPath path: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let payload = try JSONDecoder().decode(DatabasePayload.self, from: data)
        return try activateDatabase(payload)
    }

    /// Validate and activate a database payload. Returns the number of
    /// profiles accepted.
    @discardableResult
    public static func activateDatabase(_ payload: DatabasePayload) throws -> Int {
        guard payload.schemaVersion == databaseSchemaVersion else {
            throw DatabaseError.unsupportedSchema(payload.schemaVersion)
        }
        var accepted: [FirmwareProfile] = []
        for profile in payload.profiles {
            if let problem = profileValidationProblem(profile) {
                throw DatabaseError.invalidProfile(id: profile.id, reason: problem)
            }
            accepted.append(profile)
        }
        externalLock.lock()
        _external = accepted
        externalLock.unlock()
        return accepted.count
    }

    /// Clear externally loaded profiles (built-ins only). Used by tests and
    /// by diagnostics modes that must reflect code defaults.
    public static func resetDatabase() {
        externalLock.lock()
        _external = []
        externalLock.unlock()
    }

    /// Structural validation for database entries. Evidence-bearing
    /// profiles must name the machine and firmware they were verified on;
    /// key profiles must not be empty.
    public static func profileValidationProblem(_ profile: FirmwareProfile) -> String? {
        guard !profile.id.isEmpty else { return "profile id is empty" }
        guard !profile.controlFamily.isEmpty else { return "controlFamily is empty" }
        let keys = profile.keyProfile.chargingKeys + profile.keyProfile.adapterKeys + profile.keyProfile.firmwareLimitKeys
        guard !keys.isEmpty else { return "key profile names no SMC keys" }
        if profile.evidence != nil {
            guard let evidence = profile.evidence else { return "evidence missing" }
            guard !evidence.modelIdentifier.isEmpty, !evidence.systemFirmwareBuild.isEmpty else {
                return "verified profile must record modelIdentifier and systemFirmwareBuild"
            }
            guard !evidence.provenBehavior.isEmpty else {
                return "verified profile must record provenBehavior"
            }
        }
        return nil
    }

    /// The safety gate: which tiers may receive control writes.
    ///
    /// - verified: exercised on this exact machine + firmware build.
    /// - compatibleByCapability ("probable"): the runtime key signature
    ///   matches a known mechanism family; writes are allowed and every
    ///   action is verified by observed battery state anyway.
    /// - untested: NOVEL key signature — never receive speculative writes.
    ///   Diagnostics/read-only only until evidence exists.
    /// - unsupported: platform gate or no mechanism — never.
    public static func shouldAllowControlWrites(_ tier: FirmwareProfileTier) -> Bool {
        switch tier {
        case .verified, .compatibleByCapability:
            return true
        case .untested, .unsupported:
            return false
        }
    }

    /// The SMC control family as detected at runtime (mirrors the helper's
    /// SMCChargeControl.Family as a plain string so BatteryCore stays free
    /// of IOKit dependencies).
    public enum DetectedFamily {
        case firmwareLimit
        case legacy
        case legacyTahoe
        case none
    }

    /// Classify a machine into a confidence tier. Pure and unit-tested.
    ///
    /// - Platform gate failures → `.unsupported` (never probe hardware).
    /// - A detected family matching a verified profile whose firmware build
    ///   matches the running machine → `.verified`.
    /// - Same family, different build → `.compatibleByCapability`.
    /// - No family detected → `.untested` (novel signature) or
    ///   `.unsupported` when the platform gate already excluded the machine.
    public static func classify(
        identity: PlatformIdentity,
        detectedFamily: DetectedFamily,
        systemFirmwareBuild: String?
    ) -> FirmwareProfileTier {
        guard identity.isSupportedPlatform else { return .unsupported }
        guard detectedFamily != .none else { return .untested }

        let familyName: String
        switch detectedFamily {
        case .firmwareLimit: familyName = "firmwareLimit"
        case .legacy: familyName = "legacy"
        case .legacyTahoe: familyName = "legacyTahoe"
        case .none: familyName = "none"
        }

        let familyProfiles = all.filter { $0.controlFamily == familyName }
        guard !familyProfiles.isEmpty else { return .untested }

        // Exact firmware-build match on a verified profile promotes the tier.
        if let build = systemFirmwareBuild, !build.isEmpty,
           let identityFirmware = Self.parseBootBuild(from: build) {
            let exact = familyProfiles.contains { profile in
                guard let evidence = profile.evidence else { return false }
                return evidence.modelIdentifier == identity.macModelIdentifier
                    && evidence.systemFirmwareBuild == identityFirmware
            }
            if exact { return .verified }
        }
        return .compatibleByCapability
    }

    /// "mBoot-20457.1.29" / "iBoot-1234.0.0" / "20457.1.29" → the bare build
    /// number. Tolerates the NUL padding device-tree strings carry.
    /// Nil for empty input.
    public static func parseBootBuild(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \n\r\t"))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("mBoot-") { return String(trimmed.dropFirst("mBoot-".count)) }
        if trimmed.hasPrefix("iBoot-") { return String(trimmed.dropFirst("iBoot-".count)) }
        return trimmed
    }

    /// One-line summary for diagnostics: tier + profile id + evidence.
    public static func summary(for tier: FirmwareProfileTier, identity: PlatformIdentity, detectedFamily: DetectedFamily) -> String {
        switch tier {
        case .verified:
            let profile = all.first { $0.evidence != nil && $0.controlFamily == familyName(detectedFamily) }
            if let profile, let evidence = profile.evidence {
                return "VERIFIED firmware profile: \(profile.id) — matches this machine (\(evidence.modelIdentifier), mBoot-\(evidence.systemFirmwareBuild))."
            }
            return "VERIFIED firmware profile."
        case .compatibleByCapability:
            return "Compatible by capability: the detected key signature matches a known mechanism, but this exact firmware build has not been hardware-verified yet. Every action is verified at runtime regardless."
        case .untested:
            return "Untested firmware: the detected SMC signature is not in the compatibility library yet. Control writes are disabled — read-only diagnostics only. Export a compatibility report (see CONTRIBUTING.md) to help verify this machine."
        case .unsupported:
            return identity.unsupportedReason ?? "Unsupported platform: no control attempted."
        }
    }

    private static func familyName(_ family: DetectedFamily) -> String {
        switch family {
        case .firmwareLimit: return "firmwareLimit"
        case .legacy: return "legacy"
        case .legacyTahoe: return "legacyTahoe"
        case .none: return "none"
        }
    }
}
