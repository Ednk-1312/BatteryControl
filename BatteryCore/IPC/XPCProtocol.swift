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

    /// GUI app bundle identifier. The daemon only accepts clients that are
    /// part of this app (same signing team, or same-bundle for ad-hoc
    /// builds); the classifier uses it to recognize a stale BatteryControl
    /// GUI after an in-place upgrade.
    public static let appBundleID = "com.batterycontrol.app"

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
    /// as `HelperStatus.outdated` and offers the repair flow. Kept in sync
    /// with the release artifact version (`scripts/build-release.sh <ver>`).
    public static let expectedHelperVersion = "1.1.1"
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

    /// Stale-response guard for GUI command racing (§ command/monitor race):
    /// a snapshot the daemon built BEFORE the last command completed does
    /// not reflect that command's effect, so a client must not present it
    /// as the final state — it should request a fresh one instead.
    ///
    /// Clock note: app and daemon run on the same Mac, so wall-clock
    /// comparison is valid. `nil` (no command completed yet) always applies.
    public func isFresh(afterCommandAt completedAt: Date?) -> Bool {
        guard let completedAt else { return true }
        return snapshot.timestamp >= completedAt
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
    /// True only when the user explicitly consented (UI confirmation) to a
    /// discharge floor below the safety floor, accepting accelerated
    /// battery degradation. The daemon independently validates the floor
    /// against the consent flag.
    public var belowFloorConsent: Bool

    public init(targetPercent: Int, floorPercent: Int, belowFloorConsent: Bool = false) {
        self.targetPercent = targetPercent
        self.floorPercent = floorPercent
        self.belowFloorConsent = belowFloorConsent
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
    /// Live state of Apple's built-in Charge Limit (macOS 26.4+), observed
    /// by the daemon. Nil on older daemons that don't report it.
    public var nativeChargeLimit: NativeChargeLimitState?

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
        firmwareProfileSummary: String? = nil,
        nativeChargeLimit: NativeChargeLimitState? = nil
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
        self.nativeChargeLimit = nativeChargeLimit
    }
}

/// Request to install a new compatibility database. The JSON payload rides
/// inside the envelope; the daemon validates it completely before anything
/// touches disk. Clients have no other path to this file.
public struct InstallDatabaseRequest: Codable, Equatable, Sendable {
    /// Schema version the payload claims; must match the daemon's.
    public var schemaVersion: Int
    /// Profiles to install (replaces any previously installed database).
    public var profiles: [FirmwareProfile]

    public init(schemaVersion: Int, profiles: [FirmwareProfile]) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
    }

    /// The payload the daemon-side installer validates and activates.
    public var databasePayload: FirmwareProfileLibrary.DatabasePayload {
        FirmwareProfileLibrary.DatabasePayload(schemaVersion: schemaVersion, profiles: profiles)
    }
}

/// Result of a successful database install (decoded from `OperationAck`
/// context; carried as its own envelope kind so the CLI can print specifics).
public struct DatabaseInstallResult: Codable, Equatable, Sendable {
    public var acceptedProfiles: Int
    public var totalProfiles: Int
    public var installedPath: String

    public init(acceptedProfiles: Int, totalProfiles: Int, installedPath: String) {
        self.acceptedProfiles = acceptedProfiles
        self.totalProfiles = totalProfiles
        self.installedPath = installedPath
    }
}
