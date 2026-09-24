import Foundation

/// The "Fixed Charge Limit" user-facing mode: "Set my Mac to 80%".
///
/// This is a presentation layer over the hysteresis policy — the mechanism
/// every backend implements (the firmware-managed limit programs it as
/// bfD0/bfE0 and the SMC enforces the band autonomously). The user picks a
/// limit and an optional resume threshold; charging stops at/above the
/// limit and resumes once the battery falls to the resume threshold. The
/// deliberate gap prevents rapid charge/pause cycling around a single
/// percentage.
public enum FixedChargeLimit {

    /// The advertised one-tap presets. Every value here is within the
    /// firmware-limit validation bounds (both limits ≥ 5, gap ≥ 1), and
    /// custom limits below 80% are the point: Apple's built-in Charge
    /// Limit only spans 80–100%. A preset is only shown — never a promise
    /// of enforcement: the backend still has to support the mechanism and
    /// verify every write on this specific hardware. 100% is included for
    /// users who want to disable limiting by charging fully.
    public static let presetPercents: [Int] = [50, 60, 70, 75, 80, 85, 90, 95, 100]

    /// Whether `upper` is one of the advertised presets (false → Custom).
    public static func isPreset(_ upper: Int) -> Bool {
        presetPercents.contains(upper)
    }

    /// Bounds for the resume threshold given an upper limit. Keeping the
    /// resume threshold at least `minimumResumeThreshold` below the limit
    /// satisfies firmware-limit validation (both ≥ 5, gap ≥ 1) and keeps a
    /// meaningful band.
    public static let minimumResumeThreshold = 5

    public static func allowedResumeRange(forUpper upper: Int) -> ClosedRange<Int> {
        let clampedUpper = min(max(upper, 1), 100)
        let low = minimumResumeThreshold
        let high = max(low, clampedUpper - 1)
        return low...high
    }

    /// Default resume threshold for a limit: two points below the limit,
    /// clamped into the allowed range (e.g. 80 → 78, 60 → 58, 100 → 98).
    /// The battery rests AT the limit and only tops up briefly after
    /// drifting a couple of points — the behavior users expect from "keep
    /// my Mac around 80%" — instead of coasting in a wide band.
    public static func defaultResumeThreshold(forUpper upper: Int) -> Int {
        let clamped = min(max(upper, 1), 100)
        return min(max(clamped - 2, minimumResumeThreshold), clamped - 1)
    }

    /// Build the policy for a fixed charge limit. `resume` defaults to the
    /// narrow default band (limit − 2); an explicit value is clamped into
    /// the valid range. The result is always a valid hysteresis policy —
    /// the same shape the verified firmware-limit profile programs into
    /// bfD0/bfE0.
    public static func policy(upper: Int, resume: Int? = nil) -> ChargingPolicy {
        let clampedUpper = min(max(upper, 1), 100)
        let threshold = resume.map { clampedResume($0, upper: clampedUpper) }
            ?? defaultResumeThreshold(forUpper: clampedUpper)
        return ChargingPolicy.sanitized(upper: clampedUpper, lower: threshold)
    }

    /// Clamp a resume threshold into the allowed range for `upper`.
    public static func clampedResume(_ resume: Int, upper: Int) -> Int {
        let range = allowedResumeRange(forUpper: upper)
        return min(max(resume, range.lowerBound), range.upperBound)
    }

    /// Human explanation shown in the UI for the current selection.
    public static func explanation(upper: Int, resume: Int) -> String {
        "The battery rests at \(upper)%. If it drifts down to \(resume)%, charging quietly tops it back up to \(upper)% and stops. Enforcement is verified against the battery's actual state."
    }

    /// Whether disabling the active policy changes the charge-limit state
    /// (and therefore requires explicit acknowledgement), or is a harmless
    /// no-op. Pure and unit-testable: the CLI's `limit off` gate uses this
    /// so an unattended `limit off` can never silently remove a deliberate
    /// limit, while an already-disabled limit stays idempotent.
    public static func limitOffChangesState(_ policy: ChargingPolicy) -> Bool {
        policy.mode != .passthrough
    }

    /// The CLI `limit off` acknowledgement gate. Returns the refusal message
    /// when the operation must not proceed, or nil when it may.
    ///
    /// An unattended invocation (cron, launchd, a stale script, an agent)
    /// must not be able to silently remove a deliberate charge limit, so a
    /// state-changing `limit off` requires the explicit `--confirm` flag —
    /// the same convention as `uninstall --confirm` and
    /// `discharge start --allow-below-floor`. With no limit active the
    /// command changes nothing and deliberately needs no confirmation.
    public static func limitOffRejection(policy: ChargingPolicy, confirm: Bool) -> String? {
        guard !confirm, limitOffChangesState(policy) else { return nil }
        return """
        Rejected: a charge limit (\(policy.summary)) is currently active.
        Turning it off hands charging back to macOS and removes BatteryControl's
        enforcement, so it requires explicit confirmation. Re-run with:

          batterycontrol limit off --confirm

        If no limit is active, plain 'batterycontrol limit off' is a no-op
        and needs no confirmation.
        """
    }
}
