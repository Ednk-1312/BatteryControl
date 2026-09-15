import BatteryCore
import SwiftUI

/// Battery information: only fields the hardware actually provides. When a
/// value is unavailable it is omitted, not faked.
struct BatteryInformationView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Battery") {
                infoRow("Charge", "\(appState.effectiveReadings.percentage)%")
                infoRow("Charging", appState.effectiveReadings.isCharging ? "Yes" : "No")
                infoRow("External power", appState.effectiveReadings.isExternalConnected ? "Connected" : "Not connected")
                infoRow("Condition", appState.effectiveReadings.condition.displayName)
                if appState.effectiveReadings.cycleCount > 0 {
                    infoRow("Cycle count", "\(appState.effectiveReadings.cycleCount)")
                }
            }

            Section("Capacity") {
                if appState.effectiveReadings.maxCapacitymAh > 0 {
                    infoRow("Full charge capacity", "\(appState.effectiveReadings.maxCapacitymAh) mAh")
                }
                if appState.effectiveReadings.designCapacitymAh > 0 {
                    infoRow("Design capacity", "\(appState.effectiveReadings.designCapacitymAh) mAh")
                }
                if let health = appState.effectiveReadings.healthPercent {
                    infoRow("Health (capacity ratio)", "\(health)%")
                }
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
                    infoRow("Upper limit", "\(policy.upperLimit)%")
                    infoRow("Lower limit", "\(policy.lowerLimit)%")
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
                        report = await DaemonClient.shared.runDiagnostics()
                    }
                }
                .buttonStyle(.borderedProminent)
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

    /// Human labels for the firmware-profile confidence tiers.
    private func tierDisplay(_ raw: String) -> String {
        switch raw {
        case "verified": return "Verified on this firmware ✅"
        case "compatibleByCapability": return "Compatible by capability"
        case "untested": return "Untested firmware"
        case "unsupported": return "Unsupported"
        default: return raw
        }
    }
}
