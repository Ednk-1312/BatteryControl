import AppKit
import BatteryCore
import SwiftUI
import UniformTypeIdentifiers

/// Battery information: only fields the hardware actually provides. When a
/// value is unavailable it is omitted, not faked.
struct BatteryInformationView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Battery health") {
                let health = appState.healthSummary
                infoRow("Charge", "\(health.chargePercent)%")
                infoRow("State", health.chargingState)
                infoRow("Condition", health.condition.displayName)
                optionalRow("Cycle count", health.cycleCount.map(String.init))
                optionalRow("Temperature", health.temperatureC.map { String(format: "%.1f °C", $0) })
                if let ratio = health.capacityRatioPercent {
                    infoRow("Capacity ratio", "\(ratio)%")
                    Text("Calculated from full-charge capacity ÷ design capacity. This is not Apple's internal Battery Health percentage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Capacity") {
                optionalRow("Full charge capacity", appState.healthSummary.fullChargeCapacitymAh.map { "\($0) mAh" })
                optionalRow("Design capacity", appState.healthSummary.designCapacitymAh.map { "\($0) mAh" })
            }

            Section("Measurements") {
                if appState.effectiveReadings.voltagemV > 0 {
                    infoRow("Voltage", String(format: "%.2f V", Double(appState.effectiveReadings.voltagemV) / 1000))
                }
                if appState.effectiveReadings.amperageMA != 0 {
                    infoRow("Current", "\(appState.effectiveReadings.amperageMA) mA")
                }
                let watts = Double(appState.effectiveReadings.amperageMA) * Double(appState.effectiveReadings.voltagemV) / 1_000_000
                if watts != 0 {
                    infoRow("Power", String(format: "%.1f W", watts))
                }
                if let temp = appState.effectiveReadings.temperatureC {
                    infoRow("Temperature", String(format: "%.1f °C", temp))
                }
            }

            Section("Control") {
                infoRow("Charging mode", appState.snapshot?.activePolicy.summary ?? "—")
                if let policy = appState.snapshot?.activePolicy, policy.mode == .hysteresis {
                    infoRow("Charge limit", "\(policy.upperLimit)%")
                    infoRow("Resumes at", "\(policy.lowerLimit)%")
                }
                infoRow("Active backend", appState.snapshot.map { BackendID($0.activeBackendID).displayName } ?? "—")
                infoRow("Control verified", appState.snapshot?.controlIsVerified == true ? "Yes" : "Not yet")
            }

            Section("Backend capabilities") {
                capsList(appState.capabilities)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Battery Info")
    }

    @ViewBuilder
    private func capsList(_ caps: BatteryCapabilities) -> some View {
        capsRow("Upper limit", caps.supportsUpperLimit)
        capsRow("Lower limit", caps.supportsLowerLimit)
        capsRow("Fixed target", caps.supportsFixedLimit)
        capsRow("Force discharge", caps.supportsForceDischarge)
        capsRow("Force charge", caps.supportsForceCharge)
        capsRow("Calibration", caps.supportsCalibration)
        capsRow("SMC access", caps.supportsSMC)
        capsRow("Verified charging control", caps.supportsVerifiedChargingControl)
    }

    private func capsRow(_ title: String, _ supported: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(supported ? .green : .secondary)
        }
    }

    private func optionalRow(_ title: String, _ value: String?) -> some View {
        infoRow(title, value ?? "Unavailable")
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// Diagnostics page: full system picture + Run Diagnostics + readable log.
struct DiagnosticsView: View {

    @EnvironmentObject private var appState: AppState

    @State private var report: DiagnosticsReport?

    var body: some View {
        Form {
            Section("System") {
                if let platform = report?.platform {
                    infoRow("Model", platform.marketingModelName)
                    infoRow("Model identifier", platform.macModelIdentifier)
                    infoRow("Chip", platform.chipGeneration?.rawValue ?? "Unknown")
                    infoRow("macOS", "\(platform.osMajor).\(platform.osMinor).\(platform.osPatch) (\(platform.osBuild))")
                    if let fw = platform.systemFirmwareBuild {
                        infoRow("System firmware", "mBoot-\(fw)")
                    }
                } else {
                    infoRow("Model", appState.platform.marketingModelName)
                    infoRow("Chip", appState.platform.chipGeneration?.rawValue ?? "Unknown")
                    infoRow("macOS", "\(appState.platform.osMajor).\(appState.platform.osMinor) (\(appState.platform.osBuild))")
                }
                infoRow("Helper", appState.helperStatusText)
            }

            Section("Control") {
                if let report {
                    infoRow("Backend", BackendID(report.backendID).displayName)
                    infoRow("Backend description", report.backendDescription)
                    if let tier = report.firmwareProfileTier {
                        infoRow("Firmware profile", tierDisplay(tier))
                    }
                    if let summary = report.firmwareProfileSummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    infoRow("Requested action", report.requestedAction.displayName)
                    infoRow("Verified", report.verified ? "Yes" : "No")
                    if let attempt = report.lastAttempt {
                        infoRow("Last operation", attempt.action.displayName)
                        infoRow("Verification", attempt.verified ? "Verified" : attempt.verificationDetail)
                        if let error = attempt.errorText {
                            infoRow("Error", error)
                        }
                    }
                    if let error = report.lastError {
                        infoRow("Last error", error.message)
                    }
                } else {
                    Text("Run diagnostics to gather the full report from the helper.")
                        .foregroundStyle(.secondary)
                }
                if let explanation = lastExplanation {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What happened")
                            .font(.subheadline.weight(.medium))
                        Text("Operation: \(explanation.operation)")
                        Text("Error: \(explanation.error)")
                        Text("Verification: \(explanation.verificationResult)")
                        Text("Suggested next action: \(explanation.suggestedNextAction)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Run Diagnostics") {
                    Task {
                        report = await DaemonXPCClient.shared.runDiagnostics()
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Export Compatibility Report…") {
                    exportCompatibilityReport()
                }
                .disabled(report == nil)
                Button("Export Support Bundle…") {
                    exportSupportBundle()
                }
                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("The report contains hardware and firmware facts only — no serial numbers, names, or locations. Submit it with a compatibility report so this Mac can be added to the verified database (see CONTRIBUTING.md).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recent helper log") {
                if let entries = report?.recentLogEntries, !entries.isEmpty {
                    ForEach(Array(entries.suffix(25).reversed().enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(entry.timestamp.formatted(date: .omitted, time: .standard)) — \(entry.operation)\(entry.backendID.map { " (\($0))" } ?? "")")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                            Text(entry.message)
                                .font(.caption.monospaced())
                                .foregroundStyle(entry.severity == .error ? .red : .primary)
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Text("No helper log entries. The helper writes to \(BatteryXPC.helperLogPath) — an empty log usually means nothing has failed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
    }

    private var lastExplanation: ControlErrorExplainer.Explanation? {
        guard let attempt = report?.lastAttempt, !attempt.verified else { return nil }
        return ControlErrorExplainer.explain(
            attempt,
            suggestedNextAction: "Try Repair Helper in Settings. If the problem persists on this macOS version, the backend may be incompatible — see Diagnostics for the detected capabilities."
        )
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    /// Human labels for the firmware-profile confidence tiers. Deliberately
    /// unambiguous: "verified" is only claimed for physically tested
    /// model+firmware evidence; capability matches are labeled as such.
    private func tierDisplay(_ raw: String) -> String {
        switch raw {
        case "verified": return "Verified on this firmware (physically tested)"
        case "compatibleByCapability": return "Compatible by capability (this exact firmware not physically tested)"
        case "untested": return "Untested firmware (read-only)"
        case "unsupported": return "Unsupported"
        default: return raw
        }
    }

    // MARK: Compatibility report export

    @State private var exportMessage: String?

    /// Writes a small, sanitized JSON support bundle. It contains the same
    /// compatibility report the daemon already exposes plus bounded local
    /// factual events; it does not include raw system logs or user files.
    private func exportSupportBundle() {
        Task {
            let compatibility = await DaemonXPCClient.shared.exportCompatibilityReport()
            let diagnostics = await DaemonXPCClient.shared.runDiagnostics()
            let status = await DaemonXPCClient.shared.getStatus()
            let events = diagnostics?.recentEvents.isEmpty == false
                ? diagnostics!.recentEvents
                : appState.localHistory.snapshot()
            let manifest = SupportBundleManifest(
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                compatibilityReport: compatibility,
                statusSnapshot: status?.snapshot,
                events: Array(events.suffix(500))
            )
            guard let data = try? manifest.jsonData() else {
                exportMessage = "Could not serialize the support bundle."
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "batterycontrol-support-bundle.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                exportMessage = "Saved sanitized support data to \(url.lastPathComponent)."
            } catch {
                exportMessage = "Could not write the support bundle: \(error.localizedDescription)"
            }
        }
    }

    /// Generate the machine-evidence report through the daemon and hand the
    /// user a save dialog. Same generator as the CLI and the daemon flag.
    private func exportCompatibilityReport() {
        Task {
            guard let report = await DaemonXPCClient.shared.exportCompatibilityReport() else {
                exportMessage = "Could not reach the helper — try again after Repair Helper."
                return
            }
            let violations = CompatibilityReport.privacyViolations(in: report)
            if !violations.isEmpty {
                exportMessage = "Report blocked: it contains unexpected keys (\(violations.joined(separator: ", "))). No file was written."
                return
            }
            guard let data = try? report.jsonData() else {
                exportMessage = "Could not serialize the report."
                return
            }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "batterycontrol-compatibility-report.json"
            guard panel.runModal() == .OK, let url = panel.url else {
                exportMessage = nil
                return
            }
            do {
                try data.write(to: url)
                exportMessage = "Saved to \(url.lastPathComponent)."
            } catch {
                exportMessage = "Could not write the file: \(error.localizedDescription)"
            }
        }
    }
}
