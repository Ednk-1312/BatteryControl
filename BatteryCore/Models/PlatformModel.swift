import Foundation

/// Apple Silicon chip generations BatteryControl recognizes.
///
/// M1–M4 are the admitted hardware range. M5 is parsed (so the app can
/// name it precisely when refusing it); Intel is out of scope entirely.
/// Hardware admission is necessary but not sufficient: what BatteryControl
/// can actually control is decided at runtime by SMC probing and the
/// firmware compatibility database — never by chip alone.
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

    /// The OS generations BatteryControl attempts to support: macOS 14
    /// Sonoma, 15 Sequoia, 26 Tahoe, and 27.
    public static let supportedOSMajors: [Int] = [14, 15, 26, 27]

    public static let unsupportedMessage =
        "BatteryControl supports Apple Silicon Macs from M1 through M4 running macOS 14 Sonoma, macOS 15 Sequoia, macOS 26 Tahoe, or macOS 27."

    /// The platform gate: Apple Silicon M1–M4 on macOS 14, 15, 26, or 27.
    ///
    /// Admission only allows the daemon to probe the machine's actual SMC
    /// capabilities. Control is never granted by OS version alone — an
    /// admitted machine with no recognizable mechanism stays read-only.
    public var isSupportedPlatform: Bool {
        guard isAppleSilicon, let chip = chipGeneration else { return false }
        guard (ChipGeneration.m1...ChipGeneration.m4).contains(chip) else { return false }
        return Self.supportedOSMajors.contains(osMajor)
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
            return "This Mac uses \(chip.rawValue), which is newer than the supported hardware range. \(Self.unsupportedMessage)"
        }
        if chip < .m1 {
            return "\(Self.unsupportedMessage)"
        }
        if !Self.supportedOSMajors.contains(osMajor) {
            let osName: String
            if osMajor < 14 {
                osName = "macOS \(osMajor).\(osMinor)"
            } else if osMajor == 26 {
                osName = "macOS 26 (Tahoe)"
            } else {
                osName = "macOS \(osMajor)"
            }
            return "This Mac runs \(osName), which is outside the supported OS range. \(Self.unsupportedMessage)"
        }
        return Self.unsupportedMessage
    }

    /// The detected OS generation, when in the supported range.
    public var osGeneration: OSGeneration? {
        OSGeneration.from(major: osMajor)
    }

    /// Short line for diagnostics, e.g. "Apple M2 Pro · macOS 15.8 (24H23)".
    public var summaryLine: String {
        let chip = chipGeneration?.rawValue ?? "Unknown chip"
        return "\(chip) · macOS \(osMajor).\(osMinor).\(osPatch) (\(osBuild))"
    }
}
