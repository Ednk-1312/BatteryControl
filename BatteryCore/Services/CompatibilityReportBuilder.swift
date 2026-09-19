import Foundation

/// The machine-evidence format behind BatteryControl's compatibility
/// database. One generator, several surfaces: the daemon's
/// `--export-compat-report` flag, `batterycontrol compatibility --report`,
/// and the GUI's Diagnostics export all emit exactly this JSON, so a report
/// can land in the database review queue without hand-editing.
///
/// Privacy: the report intentionally contains NO serial numbers, no user
/// names, no host names, no locations. Only hardware/firmware facts a
/// compatibility reviewer needs.
public struct CompatibilityReport: Codable, Equatable, Sendable {
    /// Bump when the schema changes; reviewers pin on it.
    public var reportVersion: Int
    /// ISO-8601 UTC timestamp of generation.
    public var generatedAt: String
    /// chip, modelIdentifier, osVersion, osBuild, systemFirmwareBuild.
    public var hardware: [String: String]
    /// SMC control-key signature: key → "present:<4-byte hex>" or "absent".
    public var smcCapabilitySignature: [String: String]
    /// firmwareLimit / legacy / legacyTahoe / none — the runtime-detected
    /// SMC control family.
    public var detectedControlFamily: String
    /// verified / compatibleByCapability / untested / unsupported.
    public var firmwareProfileTier: String
    /// Matching profile ids from the compatibility library.
    public var profileNotes: [String]

    public init(
        reportVersion: Int,
        generatedAt: String,
        hardware: [String: String],
        smcCapabilitySignature: [String: String],
        detectedControlFamily: String,
        firmwareProfileTier: String,
        profileNotes: [String]
    ) {
        self.reportVersion = reportVersion
        self.generatedAt = generatedAt
        self.hardware = hardware
        self.smcCapabilitySignature = smcCapabilitySignature
        self.detectedControlFamily = detectedControlFamily
        self.firmwareProfileTier = firmwareProfileTier
        self.profileNotes = profileNotes
    }

    /// Keys that must never appear in a report, enforced by `validate`.
    public static let forbiddenKeySubstrings = [
        "serial", "uuid", "hostname", "username", "name", "email",
    ]

    /// Sanity check for outgoing reports: no PII-shaped keys. Returns the
    /// offending keys, empty when clean.
    public static func privacyViolations(in report: CompatibilityReport) -> [String] {
        let allKeys = Set(report.hardware.keys).union(report.smcCapabilitySignature.keys)
        return allKeys
            .filter { key in
                let lowered = key.lowercased()
                return forbiddenKeySubstrings.contains { lowered.contains($0) }
            }
            .sorted()
    }

    /// Canonical JSON (pretty-printed, sorted keys) for diffable reports.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

/// Pure builder: assembles a `CompatibilityReport` from facts gathered by
/// the caller (the daemon binary supplies the live SMC signature; tests
/// supply fixtures). Keeping it pure makes the evidence format testable
/// without hardware.
public enum CompatibilityReportBuilder {

    public static let currentVersion = 1

    public static func build(
        identity: PlatformIdentity,
        tier: FirmwareProfileTier,
        detectedFamily: FirmwareProfileLibrary.DetectedFamily,
        smcSignature: [String: String],
        now: Date = Date()
    ) -> CompatibilityReport {
        CompatibilityReport(
            reportVersion: currentVersion,
            generatedAt: ISO8601DateFormatter().string(from: now),
            hardware: [
                "chip": identity.chipGeneration?.rawValue ?? "unknown",
                "modelIdentifier": identity.macModelIdentifier,
                "osVersion": "\(identity.osMajor).\(identity.osMinor).\(identity.osPatch)",
                "osBuild": identity.osBuild,
                "systemFirmwareBuild": identity.systemFirmwareBuild ?? "unknown",
            ],
            smcCapabilitySignature: smcSignature,
            detectedControlFamily: familyName(detectedFamily),
            firmwareProfileTier: tier.rawValue,
            profileNotes: FirmwareProfileLibrary.all
                .filter { $0.controlFamily == familyName(detectedFamily) }
                .map { $0.id }
        )
    }

    private static func familyName(_ family: FirmwareProfileLibrary.DetectedFamily) -> String {
        switch family {
        case .firmwareLimit: return "firmwareLimit"
        case .legacy: return "legacy"
        case .legacyTahoe: return "legacyTahoe"
        case .none: return "none"
        }
    }
}
