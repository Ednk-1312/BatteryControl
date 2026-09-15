import Foundation

/// Overall charging-control mode chosen by the user.
public enum ControlMode: String, Codable, Sendable, CaseIterable {
    /// No custom charging control; macOS manages charging.
    case passthrough
    /// Hold charge between a lower and an upper threshold (hysteresis band).
    case hysteresis
    /// Maintain a fixed target ("about 80%") — a small band around the value.
    case fixedTarget
}

/// The complete desired charging policy. Owned by the user, applied and
/// verified by the helper.
public struct ChargingPolicy: Codable, Equatable, Sendable {
    public var mode: ControlMode
    /// Upper charge limit in percent (1...100). Ignored in `.passthrough`.
    public var upperLimit: Int
    /// Lower resume threshold in percent. In `.hysteresis` mode charging
    /// resumes only after falling below this value.
    public var lowerLimit: Int
    /// Band used internally for `.fixedTarget` mode.
    public static let fixedTargetBand = 3

    public init(mode: ControlMode, upperLimit: Int, lowerLimit: Int) {
        self.mode = mode
        self.upperLimit = upperLimit
        self.lowerLimit = lowerLimit
    }

    public static func passthrough() -> ChargingPolicy {
        ChargingPolicy(mode: .passthrough, upperLimit: 100, lowerLimit: 90)
    }

    /// Effective lower edge of the control band for this policy.
    public var effectiveLowerLimit: Int {
        switch mode {
        case .passthrough:
            return 0
        case .hysteresis:
            return lowerLimit
        case .fixedTarget:
            return max(1, upperLimit - Self.fixedTargetBand)
        }
    }

    /// Human-readable description, e.g. "Hold 70–80%".
    public var summary: String {
        switch mode {
        case .passthrough:
            return "macOS default charging"
        case .hysteresis:
            return "Hold \(lowerLimit)–\(upperLimit)%"
        case .fixedTarget:
            return "Maintain about \(upperLimit)%"
        }
    }

    /// Normalizes a user-selected band so invariants always hold:
    /// 1 ≤ lower < upper ≤ 100, with a minimum band width of 1.
    public static func sanitized(upper: Int, lower: Int) -> ChargingPolicy {
        let clampedUpper = min(max(upper, 1), 100)
        var clampedLower = min(max(lower, 0), 100)
        if clampedLower >= clampedUpper {
            clampedLower = max(0, clampedUpper - 1)
        }
        return ChargingPolicy(mode: .hysteresis, upperLimit: clampedUpper, lowerLimit: clampedLower)
    }
}

/// Transient overrides on top of the base policy.
public enum PolicyOverride: Codable, Equatable, Sendable {
    case none
    /// Force-discharge toward `targetPercent` while on AC; never below
    /// `floorPercent`.
    case forceDischarge(targetPercent: Int, floorPercent: Int)
    /// Temporarily charge to `targetPercent`, then restore the normal policy.
    case forceCharge(targetPercent: Int)

    public var isDischarge: Bool {
        if case .forceDischarge = self { return true }
        return false
    }

    public var isChargeOverride: Bool {
        if case .forceCharge = self { return true }
        return false
    }
}

/// Output of the policy engine for the current battery level.
public enum ChargingAction: String, Codable, Sendable {
    /// Restore normal charging (clear inhibit + adapter cut).
    case normal
    /// Prevent charging while allowing the adapter to power the system.
    case inhibitCharging
    /// Cut adapter input so the Mac runs off the battery (force discharge).
    case forceDischarge
    /// Keep the previously applied action (used inside a hysteresis band).
    case hold
}

/// Aborts in-progress special operations.
public struct OperationAborts: Codable, Equatable, Sendable {
    public var abortCalibration: Bool

    public init(abortCalibration: Bool = false) {
        self.abortCalibration = abortCalibration
    }

    public static let none = OperationAborts()
}
