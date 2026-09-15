import Foundation

/// Apple Silicon chip generations BatteryControl supports.
///
/// Scope (deliberately narrow): M1–M4 on macOS 15 Sequoia. M5 ships with
/// macOS 26 and cannot boot Sequoia, so there is no meaningful M5+macOS 15
/// target. Intel is out of scope entirely (see ATTRIBUTION.md / README).
public enum ChipGeneration: String, Codable, Sendable, CaseIterable, Comparable {
    case m1 = "Apple M1"
    case m2 = "Apple M2"
    case m3 = "Apple M3"
    case m4 = "Apple M4"

    /// Order used for comparisons ("newer than" checks).
    private var rank: Int {
        switch self {
        case .m1: return 1
        case .m2: return 2
        case .m3: return 3
        case .m4: return 4
        }
    }

    public static func < (lhs: ChipGeneration, rhs: ChipGeneration) -> Bool {
        lhs.rank < rhs.rank
    }

    /// Parses a raw `hw.model`-style or marketing chip string such as
    /// "Apple M2 Pro", "M3 Max", or "M1".
    public static func parse(fromRawString raw: String) -> ChipGeneration? {
        let lowered = raw.lowercased()
        for chip in allCases where lowered.contains(chip.rawValue.lowercased()) {
            return chip
        }
        return nil
    }
}

/// The hardware/OS identity of the machine, detected at startup.
public struct PlatformIdentity: Codable, Equatable, Sendable {
    public var chipGeneration: ChipGeneration?
    public var isAppleSilicon: Bool
    public var macModelIdentifier: String
    public var marketingModelName: String
    public var osMajor: Int
    public var osMinor: Int
    public var osPatch: Int
    public var osBuild: String
    /// System (boot) firmware build, e.g. "20457.1.29" parsed from a
    /// raw "mBoot-20457.1.29". Nil when the OS does not expose it.
    public var systemFirmwareBuild: String?

    public init(
        chipGeneration: ChipGeneration?,
        isAppleSilicon: Bool,
        macModelIdentifier: String,
        marketingModelName: String,
        osMajor: Int,
        osMinor: Int,
        osPatch: Int,
        osBuild: String,
        systemFirmwareBuild: String? = nil
    ) {
        self.chipGeneration = chipGeneration
        self.isAppleSilicon = isAppleSilicon
        self.macModelIdentifier = macModelIdentifier
        self.marketingModelName = marketingModelName
        self.osMajor = osMajor
        self.osMinor = osMinor
        self.osPatch = osPatch
        self.osBuild = osBuild
        self.systemFirmwareBuild = systemFirmwareBuild
    }

    public static let unsupportedMessage =
        "BatteryControl supports Apple Silicon Macs from M1 through M4 running macOS 15 Sequoia."

    /// The platform gate: Apple Silicon M1–M4, macOS 15.x only.
    public var isSupportedPlatform: Bool {
        guard isAppleSilicon, let chip = chipGeneration else { return false }
        return (ChipGeneration.m1...ChipGeneration.m4).contains(chip) && osMajor == 15
    }

    /// Human-readable reason when `isSupportedPlatform` is false, or nil.
    public var unsupportedReason: String? {
        if isSupportedPlatform { return nil }
        if !isAppleSilicon {
            return "This Mac uses an Intel processor. \(Self.unsupportedMessage)"
        }
        guard let chip = chipGeneration else {
            return "This Mac's chip could not be identified. \(Self.unsupportedMessage)"
        }
        if chip > .m4 {
            return "This Mac uses \(chip.rawValue), which is newer than the supported range. \(Self.unsupportedMessage)"
        }
        if chip < .m1 {
            return "\(Self.unsupportedMessage)"
        }
        if osMajor < 15 {
            return "This Mac runs macOS \(osMajor).\(osMinor). \(Self.unsupportedMessage)"
        }
        if osMajor > 15 {
            return "This Mac runs macOS \(osMajor) (Tahoe or newer). \(Self.unsupportedMessage)"
        }
        return Self.unsupportedMessage
    }

    /// Short line for diagnostics, e.g. "Apple M2 Pro · macOS 15.8 (24H23)".
    public var summaryLine: String {
        let chip = chipGeneration?.rawValue ?? "Unknown chip"
        return "\(chip) · macOS \(osMajor).\(osMinor).\(osPatch) (\(osBuild))"
    }
}
