import BatteryCore
import SwiftUI

/// Force-discharge panel. The safety floor is enforced in three places:
/// here (UI), at the XPC boundary, and in the daemon before any hardware
/// write — the UI cannot send a value the daemon would refuse. Discharging
/// below the floor additionally requires the explicit red "Remove safety
/// floor" consent switch plus a confirmation dialog.
struct DischargeControlsView: View {

    @EnvironmentObject private var appState: AppState

    @State private var targetPercent = 60.0
    @State private var floorPercent = 20.0
    @State private var belowFloorEnabled = false
    @State private var showConsentDialog = false

    private let supportedFloors: [Double] = [20, 25, 30, 40, 50]

    /// Slider range for the discharge target: extends to 1% only after the
    /// user explicitly removes the safety floor.
    private var targetRange: ClosedRange<Double> {
        belowFloorEnabled
            ? Double(ChargingPolicyEngine.absoluteDischargeFloor)...100
            : Double(ChargingPolicyEngine.minimumDischargeFloor)...100
    }

    var body: some View {
        Form {
            Section("Force discharge") {
                if let snapshot = appState.snapshot, snapshot.isForceDischarging,
                   case .forceDischarge(let target, let floor, _) = snapshot.activeOverride {
                    activeSessionSection(target: target, floor: floor, currentPercent: snapshot.readings.percentage)
                } else {
                    idleControls
                }

                if !appState.effectiveReadings.isExternalConnected,
                   appState.snapshot?.isForceDischarging != true {
                    Label("Connect the charger first — force discharge works while on AC power.",
                          systemImage: "powerplug")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("What to expect") {
                Text("Discharge is slow: roughly 1% every 5–10 minutes on idle. macOS will show the Mac as on battery power while the adapter input is cut; display dimming and idle-sleep timers apply. The battery gauge itself refreshes about once a minute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About the safety floor") {
                Text("The safety floor is a stop line, not a wall. While a discharge is running, BatteryControl checks the battery every \(Int(RecoveryDecisions.tickIntervalSeconds)) seconds and keeps discharging only while the charge is above the floor. The moment a check reads the floor value or lower, the session ends by itself: the adapter is released, the Mac goes back to charging normally, and BatteryControl returns to whatever charge limit you had set — no confirmation needed and nothing left to turn off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Two things are worth knowing. First, \"the moment\" means the next check, not instantly — the battery can drift a little below the floor between checks (usually 1–2%, never far, since the check runs every \(Int(RecoveryDecisions.tickIntervalSeconds)) seconds). Second, below \(ChargingPolicyEngine.minimumDischargeFloor)% macOS starts clipping the reported charge and the gauge gets less accurate, so a displayed 12% is an estimate. The absolute floor BatteryControl will ever program is \(ChargingPolicyEngine.absoluteDischargeFloor)%; macOS shuts the Mac down on its own before 0%.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The floor also protects you when no discharge is running: with the floor removed, the discharge target slider extends below \(ChargingPolicyEngine.minimumDischargeFloor)%, but every hardware write is still checked against the floor by the daemon itself — the app cannot send a value the daemon would refuse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Discharge")
        .confirmationDialog(
            "Remove the safety floor?",
            isPresented: $showConsentDialog,
            titleVisibility: .visible
        ) {
            Button("Remove Safety Floor", role: .destructive) {
                // Consent confirmed; keep the switch on.
                belowFloorEnabled = true
                clampTargetToRange()
            }
            Button("Cancel", role: .cancel) {
                belowFloorEnabled = false
            }
        } message: {
            Text(disclaimerText)
        }
        .onChange(of: belowFloorEnabled) { _, enabled in
            guard enabled else {
                clampTargetToRange()
                return
            }
            showConsentDialog = true
        }
    }

    // MARK: Idle controls

    private var idleControls: some View {
        Group {
            HStack {
                Slider(value: $targetPercent, in: targetRange, step: 1) {
                    Text("Discharge target")
                }
                Text("\(Int(targetPercent))%")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
            .disabled(!appState.capabilities.supportsForceDischarge)

            Picker("Safety floor", selection: $floorPercent) {
                ForEach(supportedFloors, id: \.self) { floor in
                    Text("\(Int(floor))%").tag(floor)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!appState.capabilities.supportsForceDischarge || belowFloorEnabled)

            belowFloorSwitch

            explanationText
            startButton
        }
    }

    private var belowFloorSwitch: some View {
        Toggle(isOn: $belowFloorEnabled) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Remove safety floor")
                    .foregroundStyle(.red)
                    .fontWeight(.semibold)
            }
        }
        .toggleStyle(.switch)
        .tint(.red)
        .disabled(!appState.capabilities.supportsForceDischarge)
    }

    private var explanationText: some View {
        let floorLine = belowFloorEnabled
            ? "The safety floor is REMOVED: discharge may continue to \(Int(targetPercent))% and stop only there."
            : "Discharge stops automatically at the target, at the \(Int(floorPercent))% safety floor, when the charger is physically unplugged, or before sleep."
        return Text(floorLine)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var startButton: some View {
        Button(belowFloorEnabled ? "Start Force Discharge (floor removed)" : "Start Force Discharge") {
            appState.startForceDischarge(
                target: Int(targetPercent),
                floor: belowFloorEnabled
                    ? ChargingPolicyEngine.absoluteDischargeFloor
                    : Int(floorPercent),
                belowFloorConsent: belowFloorEnabled
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(belowFloorEnabled ? .red : .accentColor)
        .disabled(!appState.capabilities.supportsForceDischarge
                  || !appState.effectiveReadings.isExternalConnected)
    }

    // MARK: Active session

    private func activeSessionSection(target: Int, floor: Int, currentPercent: Int) -> some View {
        Group {
            HStack(spacing: 10) {
                Image(systemName: "bolt.slash.fill")
                    .foregroundStyle(.red)
                Text("FORCE DISCHARGE ACTIVE")
                    .font(.headline)
                Spacer()
                Text("Current \(currentPercent)% → Target \(target)%")
                    .font(.callout.monospacedDigit())
            }
            if floor < ChargingPolicyEngine.minimumDischargeFloor {
                Label("Safety floor removed — discharging below \(ChargingPolicyEngine.minimumDischargeFloor)%. This accelerates battery degradation.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Button("Stop Force Discharge") {
                appState.cancelOverrides()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Helpers

    private var disclaimerText: String {
        """
        Discharging below \(ChargingPolicyEngine.minimumDischargeFloor)% bypasses BatteryControl's \
        safety floor and deliberately deep-discharges the battery. This WILL accelerate battery \
        degradation and shorten its usable life, and carries a small risk of an unexpected \
        shutdown near empty. Unsaved work may be lost.

        You can stop the discharge at any time by turning this off or pressing Stop.
        """
    }

    private func clampTargetToRange() {
        if targetPercent < targetRange.lowerBound {
            targetPercent = targetRange.lowerBound
        }
    }
}
