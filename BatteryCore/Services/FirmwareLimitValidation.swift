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

    // MARK: Key-shape acceptance (negative-path logic)

    /// The declared SMC metadata shapes the firmware-limit control path
    /// accepts: activation ui8 (1 byte), upper/lower ui32 (4 bytes). Zero
    /// means the firmware leaves key metadata unpopulated even for live
    /// keys (observed on verified hardware), which is treated as
    /// unknown-but-usable ONLY because the write path re-confirms every
    /// value by readback — an unexpected real shape cannot survive that.
    public static let expectedKeyShapes = [
        "bfF0": 1,  // ui8 activation
        "bfD0": 4,  // ui32 upper percentage (little-endian)
        "bfE0": 4,  // ui32 lower percentage (little-endian)
    ]

    /// Decides whether reported key data sizes are acceptable for control.
    /// Pure; the daemon probe applies this before declaring the backend
    /// available (Part 9 of the compatibility audit: capability detection
    /// must match the actual control path — the control path reads bfF0 as
    /// 1 byte and bfD0/bfE0 as 4-byte little-endian values).
    public static func keyShapesAreAcceptable(_ sizes: [String: Int]) -> Bool {
        for (key, expected) in expectedKeyShapes.sorted(by: { $0.key < $1.key }) {
            let actual = sizes[key]
            guard let actual else { return false } // a required key unreported
            // 0 = unpopulated metadata (unknown-but-usable); anything else
            // must match the expected width exactly.
            if actual != 0 && actual != expected { return false }
        }
        return true
    }

    /// Decides whether a post-write readback of the programmed limit
    /// confirms the request. Pure; used by the backend's verification loop
    /// (activation byte must read active, both percentages must match).
    public static func readbackConfirms(activationByte: UInt8, upperPercent: UInt32, lowerPercent: UInt32, requestedUpper: Int, requestedLower: Int) -> Bool {
        activationByte == 0x02
            && upperPercent == UInt32(requestedUpper)
            && lowerPercent == UInt32(requestedLower)
    }
}
