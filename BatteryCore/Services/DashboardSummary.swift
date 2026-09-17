import Foundation

/// The pure presentation model for user-facing control status. Every
/// surface (dashboard, menu bar, Battery Info) derives its display from
/// this model so the semantics are defined and tested in exactly one
/// place — instead of each view re-deriving (and drifting on) its own.
///
/// The rules it encodes:
/// - The user's charge limit is the number THEY set (the policy upper
///   limit). The lower hysteresis threshold is an implementation detail,
///   presented as "resumes at" behavior — never as a second "limit".
/// - Control status is honest against the state matrix: when the daemon
///   cannot be reached, nothing is reported as active/verified; cached
///   policy never becomes "verified".
/// - Compatibility tier wording distinguishes physically verified
///   hardware from capability-compatible machines (never overclaims).
public enum DashboardSummary {

    // MARK: State matrix

    /// The honest top-level state of the system, derived from authoritative
    /// daemon data only.
    public enum SystemState: Equatable {
        /// Daemon answered; everything below is from its live snapshot.
        case connected
        /// Daemon unreachable — no claims about control are possible.
        case daemonUnavailable
        /// Platform gate rejected this machine.
        case unsupportedPlatform
    }

    /// One-line control summary for the dashboard's Control tile and the
    /// menu bar. Never fabricates: unavailable states never read "verified".
    public static func controlStatus(
        snapshot: BatteryStatusSnapshot?,
        isSupportedPlatform: Bool
    ) -> String {
        guard isSupportedPlatform else { return "Unsupported" }
        guard let snapshot else { return "Unavailable" }
        if snapshot.activePolicy.mode == .passthrough,
           !snapshot.isForceDischarging, !snapshot.isForceCharging {
            return "macOS managed"
        }
        if snapshot.isForceDischarging { return snapshot.controlIsVerified ? "Discharge active" : "Discharge (unverified)" }
        if snapshot.isForceCharging { return snapshot.controlIsVerified ? "Charge active" : "Charge (unverified)" }
        return snapshot.controlIsVerified ? "Active & verified" : "Active, not verified"
    }

    // MARK: The user's limit vs the hysteresis band

    /// The primary dashboard limit value: the number the user set.
    /// The lower hysteresis threshold must never appear here (that was the
    /// "Lower Limit: 78%" bug: internal implementation detail displayed as
    /// if it were the user's charge limit).
    public static func primaryLimitText(policy: ChargingPolicy?) -> String {
        guard let policy, policy.mode != .passthrough else { return "None" }
        return "\(policy.upperLimit)%"
    }

    /// The resume behavior as a complete, honest sentence describing the
    /// hysteresis band without calling the lower threshold a "limit".
    public static func resumeBehaviorText(policy: ChargingPolicy) -> String {
        switch policy.mode {
        case .passthrough:
            return "macOS manages charging."
        case .hysteresis:
            return "Charging stops at \(policy.upperLimit)% and resumes when the battery drains to \(policy.lowerLimit)%."
        case .fixedTarget:
            return "The battery is held near \(policy.upperLimit)%."
        }
    }

    /// Headline for the explanation card. Names the concept the USER chose,
    /// not the internal threshold ("Lower limit" was leaking internals).
    public static func chargingBehaviorTitle(policy: ChargingPolicy?) -> String {
        guard let policy, policy.mode != .passthrough else { return "Charging behavior" }
        return "Charging behavior"
    }

    // MARK: Compatibility tier (honest wording)

    /// What the UI may tell the user about this machine's compatibility,
    /// derived from the daemon's firmware-profile tier. Verified ≠ merely
    /// capability-compatible; unknown machines stay read-only in wording.
    public static func compatibilityLine(tier: FirmwareProfileTier?) -> String {
        switch tier {
        case .verified:
            return "This exact model and firmware has been physically tested."
        case .compatibleByCapability:
            return "Compatible by detected capability — the exact firmware has not been physically tested. Every action is verified by hardware readback."
        case .untested:
            return "This machine's firmware is not yet in the compatibility library. Control stays read-only until it can be verified."
        case .unsupported, nil:
            return "This machine is outside BatteryControl's supported scope."
        }
    }
}
