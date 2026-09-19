import Foundation

/// The macOS release generations BatteryControl distinguishes, and the
/// ownership model for Apple's built-in Charge Limit.
///
/// Supporting an OS version is NEVER a control decision by itself: the
/// platform gate admits the OS generation, but what BatteryControl can
/// actually do is decided by runtime SMC capability probing, per-write
/// readback verification, and the firmware compatibility database. An OS
/// in `OSGeneration.allCases` with no usable SMC mechanism still ends up
/// read-only — the gate just allows the daemon to probe at all.
public enum OSGeneration: Int, Codable, Sendable, CaseIterable, Comparable {

    /// macOS 14 Sonoma.
    case sonoma = 14
    /// macOS 15 Sequoia.
    case sequoia = 15
    /// macOS 26 Tahoe (Apple's version numbering jumped from 15 to 26).
    case tahoe = 26
    /// macOS 27. A separate compatibility target: behavior is NOT assumed
    /// to carry forward from Tahoe; the SMC probe and per-write
    /// verification decide what is safe, and nothing is claimed as
    /// supported until evidence exists.
    case macos27 = 27

    /// Maps a major OS version to a generation. Nil for versions outside
    /// BatteryControl's supported range (13-, 16–25 do not exist; anything
    /// unlisted is refused by the platform gate).
    public static func from(major: Int) -> OSGeneration? {
        OSGeneration(rawValue: major)
    }

    public static func < (lhs: OSGeneration, rhs: OSGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .sonoma: return "macOS 14 Sonoma"
        case .sequoia: return "macOS 15 Sequoia"
        case .tahoe: return "macOS 26 Tahoe"
        case .macos27: return "macOS 27"
        }
    }

    /// Apple's own Charge Limit (80–100% in System Settings) exists on
    /// macOS 26.4 and later. It does not exist on 14 or 15.
    ///
    /// macOS 27 is treated as PROBABLY having it (assume the newer OS kept
    /// the feature), but the daemon never relies on this statically: it
    /// probes the IOKit battery registry at runtime, and the ownership
    /// decision reads live state, not this flag.
    public static func hasNativeChargeLimit(major: Int, minor: Int) -> Bool {
        switch major {
        case 26:
            return minor >= 4
        case 27:
            return true
        default:
            return false
        }
    }
}

/// The authority currently responsible for charge-limit enforcement.
public enum ChargeControlOwner: String, Codable, Sendable, CaseIterable {
    /// BatteryControl's policy is being enforced (verified by the daemon).
    case batteryControl
    /// No BatteryControl policy is active; macOS's own Charge Limit
    /// (where present) governs charging.
    case nativeAppleLimit
    /// No limit anywhere, or state could not be determined.
    case undetermined
}

/// Live state of Apple's built-in Charge Limit, as far as it can be
/// observed from the IOKit battery registry. The daemon fills this in on
/// every enforcement tick; all fields are best-effort and unknown values
/// stay nil — nothing here is ever guessed into a control decision.
public struct NativeChargeLimitState: Codable, Equatable, Sendable {
    /// Apple's Charge Limit feature exists on this OS generation
    /// (static knowledge, e.g. macOS 26.4+).
    public var featureExistsOnThisOS: Bool
    /// The feature appears to be engaged right now (observed from the
    /// battery registry). Nil when it could not be determined.
    public var nativeLimitEngaged: Bool?

    public init(featureExistsOnThisOS: Bool, nativeLimitEngaged: Bool?) {
        self.featureExistsOnThisOS = featureExistsOnThisOS
        self.nativeLimitEngaged = nativeLimitEngaged
    }

    public static let unknown = NativeChargeLimitState(featureExistsOnThisOS: false, nativeLimitEngaged: nil)
}

/// Pure ownership decisions for the native-charge-limit interaction.
///
/// The invariant: there is exactly one authoritative controller at a time.
/// BatteryControl never writes Apple's Charge Limit setting — when the user
/// has Apple's limit engaged and no BatteryControl policy, macOS owns
/// charging and the UI says so. When a BatteryControl policy IS active, the
/// daemon owns enforcement (it verifies every action against the real
/// battery state; that is what makes it authoritative).
public enum OwnershipDecisions {

    /// Which controller is authoritative right now.
    ///
    /// - A BatteryControl hysteresis/fixed-target policy (anything not
    ///   `.passthrough`) means BatteryControl owns control.
    /// - Passthrough (limit off) with Apple's limit engaged → native owns.
    /// - Passthrough with no native feature (or undetermined state) →
    ///   undetermined: macOS default charging governs.
    public static func owner(
        policyMode: ControlMode,
        native: NativeChargeLimitState
    ) -> ChargeControlOwner {
        switch policyMode {
        case .passthrough:
            if native.featureExistsOnThisOS, native.nativeLimitEngaged == true {
                return .nativeAppleLimit
            }
            return .undetermined
        default:
            return .batteryControl
        }
    }

    /// One-line explanation for the UI/CLI describing who is enforcing what.
    public static func explanation(
        owner: ChargeControlOwner,
        native: NativeChargeLimitState,
        policyMode: ControlMode
    ) -> String {
        switch owner {
        case .batteryControl:
            return "BatteryControl is enforcing your charge limit (verified against the battery's actual state)."
        case .nativeAppleLimit:
            return "No BatteryControl limit is set. macOS's own Charge Limit (80–100%) is managing charging. Set a BatteryControl limit below 80% for a lower target."
        case .undetermined:
            if native.featureExistsOnThisOS {
                return "No BatteryControl limit is set. macOS default charging applies (Apple's Charge Limit state could not be read)."
            }
            return "No charge limit is set. macOS default charging applies."
        }
    }

    /// Extract native-charge-limit state from the raw AppleSmartBattery
    /// registry. Apple does not document these keys; the probe is tolerant
    /// (several plausible key names, read-only) and everything unknown
    /// stays nil. Called by the daemon each tick; pure and unit-tested.
    public static func nativeState(fromSmartBattery smart: [String: Any], osMajor: Int, osMinor: Int) -> NativeChargeLimitState {
        let featureExists = OSGeneration.hasNativeChargeLimit(major: osMajor, minor: osMinor)
        guard featureExists else {
            return NativeChargeLimitState(featureExistsOnThisOS: false, nativeLimitEngaged: nil)
        }

        // Plausible registry keys for Apple's charging-control feature,
        // probed read-only. Presence of a non-default value is treated as
        // "engaged". Apple renames things; the tolerant scan keeps this
        // honest — when nothing recognizable is found we report nil
        // (undetermined) rather than a guess.
        let engagedKeyCandidates = [
            "ChargingControlMode", "ChargeControlMode",
            "BatteryChargeLimitMode", "ChargeLimitMode",
        ]
        var engaged: Bool? = nil
        for key in engagedKeyCandidates where smart[key] != nil {
            if let number = smart[key] as? Int {
                engaged = number != 0
            } else if let flag = smart[key] as? Bool {
                engaged = flag
            } else if let string = smart[key] as? String {
                engaged = !string.isEmpty && string.lowercased() != "none" && string.lowercased() != "off"
            }
            break
        }
        return NativeChargeLimitState(featureExistsOnThisOS: true, nativeLimitEngaged: engaged)
    }
}
