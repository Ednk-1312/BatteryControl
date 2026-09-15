import Foundation

/// Wire format shared by the app and the privileged helper over XPC.
///
/// The daemon exposes only the operations in `PrivilegedOperation`; every
/// value that reaches hardware is validated here, at the boundary, before any
/// backend runs. Raw SMC access is never exposed through XPC.
public enum BatteryXPC {

    /// Mach service name the helper registers with launchd
    /// (MachServices key in the LaunchDaemon plist).
    public static let machServiceName = "com.batterycontrol.daemon"

    /// Helper bundle identifier. Also the launchd label.
    public static let helperBundleID = "com.batterycontrol.daemon"

    /// Helper install location (the conventional PrivilegedHelperTools dir).
    public static let helperInstallPath = "/Library/PrivilegedHelperTools/com.batterycontrol.daemon"

    /// LaunchDaemon plist location.
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/com.batterycontrol.daemon.plist"

    /// Helper policy/config store directory (root-owned).
    public static let helperConfigPath = "/Library/Application Support/BatteryControl/policy.json"

    /// Helper log file readable by a normal user.
    public static let helperLogPath = "/var/log/batterycontrol-daemon.log"

    /// Distributable firmware compatibility database. Ships with releases
    /// and can be updated independently of the app; entries override the
    /// built-in profiles by id. Missing file = built-in profiles only.
    public static let compatibilityDatabasePath = "/Library/Application Support/BatteryControl/compatibility.json"

    /// Version of the helper this build expects. Bumped whenever the XPC
    /// protocol or control logic changes incompatibly; a mismatch is reported
    /// as `HelperStatus.outdated` and offers the repair flow.
    public static let expectedHelperVersion = "1.0.0"
}

/// Root XPC message envelope. One struct per operation keeps the protocol
/// versionable without breaking older callers badly.
public struct XPCStatusResponse: Codable, Equatable, Sendable {
    public var snapshot: BatteryStatusSnapshot
    public var lastAttempt: ControlAttemptResult?
    public var lastError: DiagnosticEntry?
    public var daemonVersion: String

    public init(
        snapshot: BatteryStatusSnapshot,
        lastAttempt: ControlAttemptResult?,
        lastError: DiagnosticEntry?,
        daemonVersion: String
    ) {
        self.snapshot = snapshot
        self.lastAttempt = lastAttempt
        self.lastError = lastError
        self.daemonVersion = daemonVersion
    }
}

public struct ApplyPolicyRequest: Codable, Equatable, Sendable {
    public var policy: ChargingPolicy
    public var reason: ControlRequestReason

    public init(policy: ChargingPolicy, reason: ControlRequestReason) {
        self.policy = policy
        self.reason = reason
    }
}

public struct StartForceDischargeRequest: Codable, Equatable, Sendable {
    public var targetPercent: Int
    public var floorPercent: Int

    public init(targetPercent: Int, floorPercent: Int) {
        self.targetPercent = targetPercent
        self.floorPercent = floorPercent
    }
}

public struct StartForceChargeRequest: Codable, Equatable, Sendable {
    public var targetPercent: Int

    public init(targetPercent: Int) {
        self.targetPercent = targetPercent
    }
}

public struct OperationAck: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var message: String

    public init(accepted: Bool, message: String) {
        self.accepted = accepted
        self.message = message
    }
}

public struct DiagnosticsReport: Codable, Equatable, Sendable {
    public var platform: PlatformIdentity
    public var backendID: String
    public var backendDescription: String
    public var capabilities: BatteryCapabilities
    public var currentAction: ChargingAction
    public var requestedAction: ChargingAction
    public var verified: Bool
    public var lastAttempt: ControlAttemptResult?
    public var lastError: DiagnosticEntry?
    public var daemonVersion: String
    public var helperUptimeSeconds: TimeInterval
    public var recentLogEntries: [DiagnosticEntry]
    /// Confidence tier from the firmware compatibility library
    /// (verified / compatibleByCapability / untested / unsupported).
    public var firmwareProfileTier: String?
    /// Human-readable explanation of the tier for the diagnostics UI.
    public var firmwareProfileSummary: String?

    public init(
        platform: PlatformIdentity,
        backendID: String,
        backendDescription: String,
        capabilities: BatteryCapabilities,
        currentAction: ChargingAction,
        requestedAction: ChargingAction,
        verified: Bool,
        lastAttempt: ControlAttemptResult?,
        lastError: DiagnosticEntry?,
        daemonVersion: String,
        helperUptimeSeconds: TimeInterval,
        recentLogEntries: [DiagnosticEntry],
        firmwareProfileTier: String? = nil,
        firmwareProfileSummary: String? = nil
    ) {
        self.platform = platform
        self.backendID = backendID
        self.backendDescription = backendDescription
        self.capabilities = capabilities
        self.currentAction = currentAction
        self.requestedAction = requestedAction
        self.verified = verified
        self.lastAttempt = lastAttempt
        self.lastError = lastError
        self.daemonVersion = daemonVersion
        self.helperUptimeSeconds = helperUptimeSeconds
        self.recentLogEntries = recentLogEntries
        self.firmwareProfileTier = firmwareProfileTier
        self.firmwareProfileSummary = firmwareProfileSummary
    }
}
