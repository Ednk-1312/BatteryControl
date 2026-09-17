import Foundation

/// Executes parsed CLI commands against the daemon and renders output.
///
/// State classification is honest and explicit (never a generic "error"):
/// 1. daemon unavailable (not installed / not running / unreachable)
/// 2. daemon available, hardware unsupported
/// 3. hardware supported, control exists but is NOT verified
/// 4. hardware supported, control active and verified
///
/// A state is never claimed from cached configuration alone: "Limit State:
/// Active" requires the daemon's verified flag, which the daemon sets only
/// after hardware readback.
public enum CLIRunner {

    // MARK: - Execution

    public static func run(_ command: BatteryControlCLI.Command) async -> (String, BatteryControlCLI.ExitCode) {
        switch command {
        case .help:
            return (BatteryControlCLI.helpText, .success)
        case .version:
            return await version()
        case .status:
            return await status()
        case .limitStatus:
            return await limitStatus()
        case .limitSet(let upper, let resume):
            return await limitSet(upper: upper, resume: resume)
        case .limitOff:
            return await limitOff()
        case .dischargeStatus:
            return await dischargeStatus()
        case .dischargeStart(let target, let floor, let consent):
            return await dischargeStart(target: target, floor: floor, consent: consent)
        case .dischargeStop:
            return await dischargeStop()
        case .diagnostics:
            return await diagnostics()
        case .compatibility:
            return await compatibility()
        }
    }

    // MARK: - Version

    private static func version() async -> (String, BatteryControlCLI.ExitCode) {
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available(let response):
            return (cliVersionLine(daemonVersion: response.daemonVersion), .success)
        }
    }

    private static func cliVersionLine(daemonVersion: String) -> String {
        """
        BatteryControl CLI \(BatteryXPC.expectedHelperVersion)
        Daemon        \(daemonVersion)
        """
    }

    // MARK: - Status / limit

    private static func status() async -> (String, BatteryControlCLI.ExitCode) {
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available(let response):
            if response.snapshot.firmwareProfileTier == .unsupported {
                return (renderStatus(response), .unsupportedHardware)
            }
            return (renderStatus(response), .success)
        }
    }

    private static func dischargeStatus() async -> (String, BatteryControlCLI.ExitCode) {
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available(let response):
            return (renderDischargeStatus(response.snapshot), .success)
        }
    }

    private static func limitStatus() async -> (String, BatteryControlCLI.ExitCode) {
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available(let response):
            return (renderStatus(response), .success)
        }
    }

    private static func limitSet(upper: Int, resume: Int?) async -> (String, BatteryControlCLI.ExitCode) {
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available(let response):
            guard response.snapshot.capabilities.supportsUpperLimit else {
                return (safetyRejection(response, reason:
                    "The active backend on this machine cannot verify a charge limit, " +
                    "so the command is refused rather than pretending to work."), .safetyRejection)
            }
            // The daemon re-validates; the client uses FixedChargeLimit only
            // to give early, precise feedback and to build the same policy
            // the GUI's Fixed Charge Limit mode builds.
            let policy = FixedChargeLimit.policy(upper: upper, resume: resume)
            guard let ack = await DaemonXPCClient.shared.applyPolicy(policy) else {
                return (communicationFailure(), .communicationFailure)
            }
            return (renderAck(ack), ack.accepted ? .success : .safetyRejection)
        }
    }

    private static func limitOff() async -> (String, BatteryControlCLI.ExitCode) {
        guard let ack = await DaemonXPCClient.shared.applyPolicy(.passthrough()) else {
            return (communicationFailure(), .communicationFailure)
        }
        return (renderAck(ack), ack.accepted ? .success : .safetyRejection)
    }

    // MARK: - Discharge

    private static func dischargeStart(target: Int, floor: Int?, consent: Bool) async -> (String, BatteryControlCLI.ExitCode) {
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available(let response):
            guard response.snapshot.capabilities.supportsForceDischarge else {
                return (safetyRejection(response, reason:
                    "The active backend on this machine cannot verify force discharge, " +
                    "so the command is refused rather than pretending to work."), .safetyRejection)
            }
            let effectiveFloor = floor ?? ChargingPolicyEngine.minimumDischargeFloor
            if ChargingPolicyEngine.requiresBelowFloorConsent(floor: effectiveFloor), !consent {
                return (
                    """
                    Rejected: \(effectiveFloor)% is below the \(ChargingPolicyEngine.minimumDischargeFloor)% safety floor.
                    Discharging below the safety floor deliberately deep-discharges the battery,
                    which accelerates battery degradation. If you are sure, re-run with:

                      batterycontrol discharge start \(target) --allow-below-floor

                    Consent applies to this discharge session only.
                    """,
                    .safetyRejection
                )
            }
            guard let ack = await DaemonXPCClient.shared.startForceDischarge(
                targetPercent: target,
                floorPercent: effectiveFloor,
                belowFloorConsent: consent
            ) else {
                return (communicationFailure(), .communicationFailure)
            }
            return (renderAck(ack), ack.accepted ? .success : .safetyRejection)
        }
    }

    private static func dischargeStop() async -> (String, BatteryControlCLI.ExitCode) {
        guard let ack = await DaemonXPCClient.shared.cancelOverrides() else {
            return (communicationFailure(), .communicationFailure)
        }
        return (renderAck(ack), .success)
    }

    // MARK: - Diagnostics / compatibility

    private static func diagnostics() async -> (String, BatteryControlCLI.ExitCode) {
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available:
            guard let report = await DaemonXPCClient.shared.runDiagnostics() else {
                return (communicationFailure(), .communicationFailure)
            }
            return (renderDiagnostics(report), .success)
        }
    }

    private static func compatibility() async -> (String, BatteryControlCLI.ExitCode) {
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available:
            guard let report = await DaemonXPCClient.shared.runDiagnostics() else {
                return (communicationFailure(), .communicationFailure)
            }
            return (renderCompatibility(report), .success)
        }
    }

    // MARK: - Daemon state classification

    private enum DaemonState {
        case unavailable(String)
        case available(XPCStatusResponse)
    }

    private static func daemonState() async -> DaemonState {
        guard let response = await DaemonXPCClient.shared.getStatus() else {
            return .unavailable(daemonUnavailableText())
        }
        return .available(response)
    }

    public static func daemonUnavailableText() -> String {
        let installed = FileManager.default.fileExists(atPath: BatteryXPC.helperInstallPath)
        if !installed {
            return """
            BatteryControl daemon is not installed.

            The CLI is a client of the BatteryControl privileged daemon, which owns
            all hardware operations. Install BatteryControl (GUI + CLI) and follow
            its first-launch setup, or install the daemon from the GUI edition.

              https://github.com/ — see BatteryControl releases
            """
        }
        return """
        BatteryControl daemon is installed but not reachable.

        It may not be running. Check:

          launchctl print system/com.batterycontrol.daemon
          tail /var/log/batterycontrol-daemon.log

        If it was recently installed, launching the BatteryControl app once
        completes registration.
        """
    }

    private static func communicationFailure() -> String {
        """
        Communication with the BatteryControl daemon failed mid-request.
        The daemon may have restarted. Retry; if it persists:

          launchctl print system/com.batterycontrol.daemon
        """
    }

    private static func safetyRejection(_ response: XPCStatusResponse, reason: String) -> String {
        """
        Rejected by safety rules.

        \(reason)

        Backend: \(BackendID(response.snapshot.activeBackendID).displayName)
        Tier:    \(response.snapshot.firmwareProfileTier.map { $0.rawValue } ?? "unknown")
        """
    }

    // MARK: - Rendering

    private static func renderStatus(_ response: XPCStatusResponse) -> String {
        let s = response.snapshot
        let r = s.readings

        let power: String
        if r.isExternalConnected {
            power = "Connected"
        } else if r.isAdapterAttached {
            power = "Connected (input cut)"
        } else {
            power = "On battery"
        }

        var lines: [String] = []
        lines.append("BatteryControl")
        lines.append("")
        lines.append("Battery:              \(r.percentage)%")
        lines.append("Power:                \(power)")
        lines.append("Charging:             \(r.isCharging ? "Charging" : "Not charging")")

        switch s.activePolicy.mode {
        case .hysteresis:
            lines.append("Charge Limit:         \(s.activePolicy.upperLimit)%")
            lines.append("Resumes At:           \(s.activePolicy.lowerLimit)%")
        case .fixedTarget:
            lines.append("Charge Limit:         ~\(s.activePolicy.upperLimit)%")
        case .passthrough:
            lines.append("Charge Limit:         Off (macOS default)")
        }

        if case .forceDischarge(let target, let floor, _) = s.activeOverride {
            lines.append("Force Discharge:      Active → \(target)% (floor \(floor)%)")
        } else if case .forceCharge(let target) = s.activeOverride {
            lines.append("Force Charge:         Active → \(target)%")
        }

        lines.append("Limit State:          \(limitState(s))")
        lines.append("Hardware Verified:    \(s.controlIsVerified ? "Yes" : "Unknown")")
        lines.append("Backend:              \(BackendID(s.activeBackendID).displayName)")
        return lines.joined(separator: "\n")
    }

    private static func limitState(_ s: BatteryStatusSnapshot) -> String {
        switch s.activePolicy.mode {
        case .passthrough:
            return s.controlIsVerified ? "Off (verified)" : "Off"
        default:
            if s.controlIsVerified { return "Active" }
            return "Pending verification"
        }
    }

    private static func renderAck(_ ack: OperationAck) -> String {
        ack.accepted ? ack.message : "Rejected: \(ack.message)"
    }

    private static func renderDischargeStatus(_ s: BatteryStatusSnapshot) -> String {
        var lines: [String] = []
        lines.append("BatteryControl")
        lines.append("")
        if case .forceDischarge(let target, let floor, _) = s.activeOverride, s.isForceDischarging {
            lines.append("Force Discharge:      Active")
            lines.append("Current:              \(s.readings.percentage)%")
            lines.append("Target:               \(target)%")
            lines.append("Stop floor:           \(floor)%")
            if floor < ChargingPolicyEngine.minimumDischargeFloor {
                lines.append("Safety floor:         REMOVED (consented this session; accelerates degradation)")
            } else {
                lines.append("Safety floor:         \(floor)%")
            }
        } else {
            lines.append("Force Discharge:      Not active")
            lines.append("Battery:              \(s.readings.percentage)%")
            lines.append("Power:                \(s.readings.isExternalConnected ? "Connected" : "On battery")")
            lines.append("Safety floor:         \(ChargingPolicyEngine.minimumDischargeFloor)% (removal requires explicit consent)")
        }
        lines.append("Hardware Verified:    \(s.controlIsVerified ? "Yes" : "Unknown")")
        return lines.joined(separator: "\n")
    }

    private static func renderDiagnostics(_ report: DiagnosticsReport) -> String {
        var lines: [String] = []
        lines.append("BatteryControl diagnostics")
        lines.append("")
        lines.append("Platform:             \(report.platform.summaryLine)")
        lines.append("Backend:              \(report.backendID) — \(report.backendDescription)")
        lines.append("Current action:       \(report.currentAction.rawValue)")
        lines.append("Verified:             \(report.verified ? "Yes" : "No")")
        if let tier = report.firmwareProfileTier {
            lines.append("Compatibility tier:   \(tier)")
        }
        if let summary = report.firmwareProfileSummary {
            lines.append("                      \(summary)")
        }
        lines.append("Daemon version:       \(report.daemonVersion)")
        lines.append("Daemon uptime:        \(Int(report.helperUptimeSeconds))s")
        if let error = report.lastError {
            lines.append("Last error:           \(error.message)")
        }
        if !report.recentLogEntries.isEmpty {
            lines.append("")
            lines.append("Recent log:")
            for entry in report.recentLogEntries.suffix(8) {
                lines.append("  \(entry.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func renderCompatibility(_ report: DiagnosticsReport) -> String {
        var lines: [String] = []
        lines.append("Machine:              \(report.platform.summaryLine)")
        lines.append("Model ID:             \(report.platform.macModelIdentifier)")
        if let build = report.platform.systemFirmwareBuild {
            lines.append("System firmware:      \(build)")
        }
        lines.append("Compatibility tier:   \(report.firmwareProfileTier ?? "unknown")")
        switch report.firmwareProfileTier {
        case FirmwareProfileTier.verified.rawValue:
            lines.append("This exact hardware/firmware combination has been exercised with readback verification.")
        case FirmwareProfileTier.compatibleByCapability.rawValue:
            lines.append("Key signature matches a known mechanism; every action is verified at runtime.")
        case FirmwareProfileTier.untested.rawValue:
            lines.append("Unknown key signature: READ-ONLY diagnostics. No control writes are attempted.")
        case FirmwareProfileTier.unsupported.rawValue:
            lines.append("This machine is outside BatteryControl's supported platform scope.")
        default:
            break
        }
        return lines.joined(separator: "\n")
    }
}
