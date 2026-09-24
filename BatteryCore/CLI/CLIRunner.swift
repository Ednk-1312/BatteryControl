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
        case .limitOff(let confirm):
            return await limitOff(confirm: confirm)
        case .dischargeStatus:
            return await dischargeStatus()
        case .dischargeStart(let target, let floor, let consent):
            return await dischargeStart(target: target, floor: floor, consent: consent)
        case .dischargeStop:
            return await dischargeStop()
        case .chargeStart(let target, let durationSeconds):
            return await chargeStart(target: target, durationSeconds: durationSeconds)
        case .chargeStop:
            return await chargeStop()
        case .calibrationStatus:
            return await calibrationStatus()
        case .calibrationStart:
            return await calibrationStart()
        case .calibrationCancel:
            return await calibrationCancel()
        case .updateCheck:
            return await updateCheck()
        case .diagnostics:
            return await diagnostics()
        case .compatibility:
            return await compatibility()
        case .compatibilityReport:
            return await compatibilityReport()
        case .databaseInstall(let path):
            return await databaseInstall(path: path)
        case .uninstall(let confirm, let removeData):
            return await uninstall(confirm: confirm, removeData: removeData)
        }
    }

    // MARK: - Version

    private static func version() async -> (String, BatteryControlCLI.ExitCode) {
        // Version is a local metadata query. It must remain useful when the
        // daemon is absent or being upgraded; status/control commands still
        // report daemon availability honestly.
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable:
            return ("BatteryControl CLI \(BatteryXPC.expectedHelperVersion)\nDaemon        unavailable", .success)
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
        guard (5...100).contains(upper) else {
            return ("Invalid charge limit: choose a percentage from 5 through 100.", .invalidArguments)
        }
        if let resume, !(5..<upper).contains(resume) {
            return ("Invalid resume threshold: it must be 5 through one point below the upper limit.", .invalidArguments)
        }
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

    /// Disabling an active charge limit is a state-changing operation that
    /// cron, launchd, or a stale script must not be able to perform
    /// silently, so it requires explicit acknowledgement (`--confirm`) —
    /// the same convention as `uninstall --confirm`. With no limit active
    /// the command is a harmless no-op and deliberately needs no flag.
    private static func limitOff(confirm: Bool) async -> (String, BatteryControlCLI.ExitCode) {
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available(let response):
            // Decide from the daemon's authoritative policy, never from
            // local caches. A hysteresis/fixed-target limit is active → an
            // unconfirmed request must fail safely before any XPC write.
            // The decision is pure (FixedChargeLimit.limitOffRejection) so
            // the refusal is unit-testable without a daemon.
            if let rejection = FixedChargeLimit.limitOffRejection(
                policy: response.snapshot.activePolicy,
                confirm: confirm
            ) {
                return (rejection, .safetyRejection)
            }
            guard let ack = await DaemonXPCClient.shared.applyPolicy(.passthrough()) else {
                return (communicationFailure(), .communicationFailure)
            }
            return (renderAck(ack), ack.accepted ? .success : .safetyRejection)
        }
    }

    // MARK: - Discharge

    private static func dischargeStart(target: Int, floor: Int?, consent: Bool) async -> (String, BatteryControlCLI.ExitCode) {
        guard (1...100).contains(target) else {
            return ("Invalid discharge target: choose a percentage from 1 through 100.", .invalidArguments)
        }
        if let floor, !(1...100).contains(floor) {
            return ("Invalid discharge floor: choose a percentage from 1 through 100.", .invalidArguments)
        }
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

    // MARK: - Force charge

    private static func chargeStart(target: Int?, durationSeconds: TimeInterval?) async -> (String, BatteryControlCLI.ExitCode) {
        let effectiveTarget = target ?? 100
        guard (1...100).contains(effectiveTarget) else {
            return ("Invalid charge target: choose a percentage from 1 through 100.", .invalidArguments)
        }
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available(let response):
            guard response.snapshot.capabilities.supportsForceCharge else {
                return (safetyRejection(response, reason:
                    "The active backend on this machine cannot verify force charge, " +
                    "so the command is refused rather than pretending to work."), .safetyRejection)
            }
            guard let ack = await DaemonXPCClient.shared.startForceCharge(
                targetPercent: effectiveTarget,
                durationSeconds: durationSeconds
            ) else {
                return (communicationFailure(), .communicationFailure)
            }
            return (renderAck(ack), ack.accepted ? .success : .safetyRejection)
        }
    }

    private static func chargeStop() async -> (String, BatteryControlCLI.ExitCode) {
        guard let ack = await DaemonXPCClient.shared.cancelOverrides() else {
            return (communicationFailure(), .communicationFailure)
        }
        return (renderAck(ack), .success)
    }

    // MARK: - Calibration

    private static func calibrationStatus() async -> (String, BatteryControlCLI.ExitCode) {
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available(let response):
            return (renderCalibration(response.snapshot), .success)
        }
    }

    private static func calibrationStart() async -> (String, BatteryControlCLI.ExitCode) {
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available(let response):
            guard response.snapshot.capabilities.supportsCalibration else {
                return (safetyRejection(response, reason:
                    "The active backend on this machine cannot verify the calibration " +
                    "stages, so the command is refused rather than pretending to work."), .safetyRejection)
            }
            guard let ack = await DaemonXPCClient.shared.beginCalibration() else {
                return (communicationFailure(), .communicationFailure)
            }
            return (renderAck(ack), ack.accepted ? .success : .safetyRejection)
        }
    }

    private static func calibrationCancel() async -> (String, BatteryControlCLI.ExitCode) {
        guard let ack = await DaemonXPCClient.shared.cancelCalibration() else {
            return (communicationFailure(), .communicationFailure)
        }
        return (renderAck(ack), .success)
    }

    // MARK: - Compatibility report / database

    private static func updateCheck() async -> (String, BatteryControlCLI.ExitCode) {
        var request = URLRequest(url: UpdateCheck.apiLatestRelease)
        request.timeoutInterval = 15
        request.setValue("BatteryControl-CLI/\(BatteryXPC.expectedHelperVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try UpdateCheck.parseLatestRelease(fromData: data)
            let current = BatteryXPC.expectedHelperVersion
            if UpdateCheck.isNewer(release.tagName, than: current) {
                return ("""
                A newer release is available: \(release.tagName) (installed: \(current))
                \(release.htmlURL)

                BatteryControl never updates itself — download and install the new
                release when you choose to.
                """, .success)
            }
            return ("BatteryControl is up to date (\(current)).", .success)
        } catch UpdateCheck.ParseError.notARelease {
            return ("No published release was found.", .success)
        } catch {
            return ("Could not reach GitHub: \(error.localizedDescription)", .communicationFailure)
        }
    }

    private static func compatibilityReport() async -> (String, BatteryControlCLI.ExitCode) {
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available:
            guard let report = await DaemonXPCClient.shared.exportCompatibilityReport() else {
                return (communicationFailure(), .communicationFailure)
            }
            let violations = CompatibilityReport.privacyViolations(in: report)
            if !violations.isEmpty {
                return ("""
                Refused to emit the report: it contains PII-shaped keys (\(violations.joined(separator: ", "))).
                This is a bug — please report it. No file was written.
                """, .safetyRejection)
            }
            guard let data = try? report.jsonData(), let json = String(data: data, encoding: .utf8) else {
                return ("FAILED to serialize the report.", .hardwareWriteFailure)
            }
            return (json, .success)
        }
    }

    private static func databaseInstall(path: String) async -> (String, BatteryControlCLI.ExitCode) {
        let daemonState = await daemonState()
        switch daemonState {
        case .unavailable(let explanation):
            return (explanation, .daemonUnavailable)
        case .available:
            guard let data = FileManager.default.contents(atPath: path) else {
                return ("Could not read \(path).", .notFound)
            }
            guard let payload = try? JSONDecoder().decode(FirmwareProfileLibrary.DatabasePayload.self, from: data) else {
                return ("""
                \(path) is not a valid compatibility database (expected {"schemaVersion":1,"profiles":[…]}).
                """, .invalidArguments)
            }
            // Early, precise feedback; the daemon re-validates everything.
            do {
                _ = try CompatibilityDatabaseInstaller.validatedPayload(payload)
            } catch let error as CompatibilityDatabaseInstaller.InstallError {
                if case .databaseInvalid(let reason) = error {
                    return ("Rejected: \(reason)", .safetyRejection)
                }
            } catch {}
            guard let outcome = await DaemonXPCClient.shared.installCompatibilityDatabaseWithRejection(payload) else {
                return (communicationFailure(), .communicationFailure)
            }
            if let rejection = outcome.rejectedMessage {
                return ("Rejected by the daemon: \(rejection)", .safetyRejection)
            }
            guard let result = outcome.result else {
                return (communicationFailure(), .communicationFailure)
            }
            return ("""
            Installed \(result.acceptedProfiles) profile(s); \(result.totalProfiles) profile(s) now active.
            Path: \(result.installedPath)
            Database entries broaden recognition only — every machine is still probed and verified at runtime.
            """, .success)
        }
    }

    // MARK: - Uninstall

    private static func uninstall(confirm: Bool, removeData: Bool) async -> (String, BatteryControlCLI.ExitCode) {
        guard confirm else {
            return ("Uninstall is destructive. Re-run with 'batterycontrol uninstall --confirm' (add --remove-data only if you also want local CLI data removed).", .invalidArguments)
        }
        guard let ack = await DaemonXPCClient.shared.uninstallPrivilegedComponents(removeCLI: true), ack.accepted else {
            return ("Uninstall refused: normal charging could not be verified before privileged removal. Nothing was removed.", .safetyRejection)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let helperGone = !BatteryControlUninstallVerification.launchJobExists()
            && BatteryControlUninstallVerification.privilegedComponentsGone()
        if removeData {
            try? FileManager.default.removeItem(at: BatteryControlUserData.applicationSupportURL())
        }
        guard helperGone else {
            return ("Uninstall started but could not verify that the privileged daemon and launch configuration are gone.", .communicationFailure)
        }
        return ("BatteryControl's privileged daemon and CLI were removed. macOS/default charging management is now responsible.", .success)
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
        lines.append("Supported operations: \(supportedOperations(report.capabilities))")
        if let native = report.nativeChargeLimit, native.featureExistsOnThisOS {
            let engaged: String
            switch native.nativeLimitEngaged {
            case .some(true): engaged = "engaged (80–100%)"
            case .some(false): engaged = "not engaged"
            case .none: engaged = "state could not be read"
            }
            lines.append("Apple Charge Limit:   \(engaged)")
            lines.append("                      BatteryControl's custom limits can go below Apple's 80% minimum.")
        }
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

    /// Human-readable list of what the active backend can do on this
    /// machine, from the daemon's runtime capability probe.
    private static func supportedOperations(_ caps: BatteryCapabilities) -> String {
        var ops: [String] = []
        if caps.supportsVerifiedChargingControl {
            ops.append("charge limit (verified)")
        } else if caps.supportsFixedLimit {
            ops.append("charge limit (unverified on this OS — diagnostics only)")
        }
        if caps.supportsForceDischarge { ops.append("force discharge") }
        if caps.supportsForceCharge { ops.append("force charge") }
        if caps.supportsCalibration { ops.append("calibration") }
        if caps.supportsSMC { ops.append("SMC telemetry") }
        return ops.isEmpty ? "none — diagnostics only" : ops.joined(separator: ", ")
    }

    private static func renderCalibration(_ s: BatteryStatusSnapshot) -> String {
        var lines: [String] = []
        lines.append("BatteryControl calibration")
        lines.append("")
        guard let session = s.activeCalibration, session.isActive else {
            if let finished = s.activeCalibration, finished.stage == .finish {
                lines.append("Stage:               Finished")
                lines.append("Your normal charging policy is active again.")
            } else {
                lines.append("Stage:               Not running")
                lines.append("Start one with: batterycontrol calibration start")
            }
            lines.append("Hardware Verified:   \(s.controlIsVerified ? "Yes" : "Unknown")")
            return lines.joined(separator: "\n")
        }
        lines.append("Stage:               \(session.stage.displayName)")
        lines.append("Detail:              \(session.stage.detailText)")
        lines.append("Battery:             \(s.readings.percentage)%")
        if let entered = session.stageEnteredAt {
            let minutes = Int(Date().timeIntervalSince(entered) / 60)
            lines.append("Time in stage:       \(minutes) min")
        }
        if let abort = session.abortReason {
            lines.append("Aborted:             \(abort)")
        }
        lines.append("Hardware Verified:   \(s.controlIsVerified ? "Yes" : "Unknown")")
        return lines.joined(separator: "\n")
    }
}
