import Foundation

/// Why a control operation was requested. Recorded for diagnostics so the UI
/// can show the difference between "user asked" and "recovery re-applied".
public enum ControlRequestReason: String, Codable, Sendable {
    case userRequest
    case policyTick
    case sleepWakeRecovery
    case powerSourceChange
    case bootRecovery
    case daemonStart
    case calibration
    case safetyStop
}

/// The outcome of one control attempt. Verification is mandatory: an action
/// is never reported as applied unless the resulting state was confirmed.
/// The policy context that produced the last firmware-limit configuration.
/// Compared (Equatable) each tick so an unchanged context with a verified
/// state skips redundant hardware maintenance; any change reconfigures.
/// Deliberately no timestamps — only the semantic inputs of configure().
public struct FirmwareMaintContext: Codable, Equatable, Sendable {
    public var policy: ChargingPolicy
    public var override: PolicyOverride
    public var calibrationActive: Bool

    public init(
        policy: ChargingPolicy,
        override: PolicyOverride,
        calibrationActive: Bool
    ) {
        self.policy = policy
        self.override = override
        self.calibrationActive = calibrationActive
    }
}

public struct ControlAttemptResult: Codable, Equatable, Sendable {
    public var action: ChargingAction
    public var backendID: String
    public var verified: Bool
    public var verificationDetail: String
    public var errorText: String?
    public var attemptNumber: Int
    public var timestamp: Date

    public init(
        action: ChargingAction,
        backendID: String,
        verified: Bool,
        verificationDetail: String,
        errorText: String? = nil,
        attemptNumber: Int,
        timestamp: Date = Date()
    ) {
        self.action = action
        self.backendID = backendID
        self.verified = verified
        self.verificationDetail = verificationDetail
        self.errorText = errorText
        self.attemptNumber = attemptNumber
        self.timestamp = timestamp
    }
}
