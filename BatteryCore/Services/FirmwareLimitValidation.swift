import Foundation

/// Validation for the firmware-managed charge-limit (bfF0/bfD0/bfE0) values.
/// Pure and unit-testable; both the daemon backend and the diagnostics CLI
/// run every requested limit through this before any SMC write happens.
public enum FirmwareLimitValidation {

    /// The activation key (bfF0) must be off while limits are reprogrammed;
    /// the firmware requires deactivate → write upper → write lower →
    /// activate (documented behavior of the mechanism).
    public static let minimumLimitGap = 1

    /// Returns nil when the requested limit pair is safe to program, or a
    /// human-readable problem description. Enforces:
    ///   - both values inside 5...100 (never program absurdly low values)
    ///   - lower < upper with a minimum gap
    public static func problem(upper: Int, lower: Int) -> String? {
        guard (5...100).contains(upper) else {
            return "The upper limit must be between 5 and 100 percent (got \(upper))."
        }
        guard (5...100).contains(lower) else {
            return "The lower threshold must be between 5 and 100 percent (got \(lower))."
        }
        guard upper - lower >= minimumLimitGap else {
            return "The lower threshold must be at least \(minimumLimitGap) percent below the upper limit."
        }
        return nil
    }

    /// Maps a user policy + override onto the firmware-limit values to
    /// program. Returns nil when the firmware limit should be deactivated
    /// instead (passthrough policy, or a force-charge target above the
    /// programable range). Pure; unit-tested.
    public static func requestedLimit(policy: ChargingPolicy, override: PolicyOverride) -> (upper: Int, lower: Int)? {
        switch override {
        case .forceCharge(let target):
            // Above the programable ceiling the firmware limit must be
            // deactivated so the charge can complete.
            return target > 100 - minimumLimitGap ? nil : (upper: policy.upperLimit, lower: policy.effectiveLowerLimit)
        case .forceDischarge:
            // Discharge rides the adapter cut; keep the last limit active so
            // the band still governs recharging.
            if policy.mode == .passthrough { return nil }
            return (upper: policy.upperLimit, lower: policy.effectiveLowerLimit)
        case .none:
            switch policy.mode {
            case .passthrough:
                return nil
            case .hysteresis, .fixedTarget:
                return (upper: policy.upperLimit, lower: policy.effectiveLowerLimit)
            }
        }
    }
}
