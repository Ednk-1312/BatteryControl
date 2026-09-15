import Foundation

/// Explicit capability report for the active backend. The UI disables
/// features the backend cannot deliver instead of pretending they work.
public struct BatteryCapabilities: Codable, Equatable, Sendable {
    public var supportsUpperLimit: Bool
    public var supportsLowerLimit: Bool
    public var supportsFixedLimit: Bool
    public var supportsForceDischarge: Bool
    public var supportsForceCharge: Bool
    public var supportsCalibration: Bool
    public var supportsSMC: Bool
    public var supportsVerifiedChargingControl: Bool

    public init(
        supportsUpperLimit: Bool,
        supportsLowerLimit: Bool,
        supportsFixedLimit: Bool,
        supportsForceDischarge: Bool,
        supportsForceCharge: Bool,
        supportsCalibration: Bool,
        supportsSMC: Bool,
        supportsVerifiedChargingControl: Bool
    ) {
        self.supportsUpperLimit = supportsUpperLimit
        self.supportsLowerLimit = supportsLowerLimit
        self.supportsFixedLimit = supportsFixedLimit
        self.supportsForceDischarge = supportsForceDischarge
        self.supportsForceCharge = supportsForceCharge
        self.supportsCalibration = supportsCalibration
        self.supportsSMC = supportsSMC
        self.supportsVerifiedChargingControl = supportsVerifiedChargingControl
    }

    /// No control available (unsupported platform, or backend probe failed).
    public static let unsupported = BatteryCapabilities(
        supportsUpperLimit: false,
        supportsLowerLimit: false,
        supportsFixedLimit: false,
        supportsForceDischarge: false,
        supportsForceCharge: false,
        supportsCalibration: false,
        supportsSMC: false,
        supportsVerifiedChargingControl: false
    )
}

/// Status of the privileged helper as seen by the app.
public enum HelperStatus: String, Codable, Sendable {
    case notInstalled
    case outdated
    case notRunning
    case unreachable
    case running
}

/// The privileged operations exposed over XPC. Deliberately tiny.
public enum PrivilegedOperation: String, Codable, Sendable, CaseIterable {
    case getStatus
    case applyPolicy
    case startForceDischarge
    case stopForceDischarge
    case startForceCharge
    case cancelOverrides
    case beginCalibration
    case cancelCalibration
    case runDiagnostics

    public var requiresValidatedValues: Bool {
        switch self {
        case .getStatus: return false
        default: return true
        }
    }
}

public enum ControlModeHelpers {
    /// Minimum band width between lower and upper limit.
    public static let minimumBandWidth = 1

    /// Validates a policy against hard safety invariants. Returns an error
    /// message when invalid, nil when acceptable.
    public static func validate(_ policy: ChargingPolicy) -> String? {
        switch policy.mode {
        case .passthrough:
            return nil
        case .hysteresis, .fixedTarget:
            guard (1...100).contains(policy.upperLimit) else {
                return "Upper limit must be between 1 and 100 percent."
            }
            guard (0...100).contains(policy.lowerLimit) else {
                return "Lower threshold must be between 0 and 100 percent."
            }
            if policy.mode == .hysteresis {
                guard policy.upperLimit - policy.lowerLimit >= minimumBandWidth else {
                    return "Lower threshold must be below the upper limit."
                }
            }
            return nil
        }
    }
}
