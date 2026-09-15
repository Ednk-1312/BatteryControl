import BatteryCore
import SwiftUI

/// Force-discharge panel. The safety floor is enforced in three places:
/// here (UI), at the XPC boundary, and in the daemon before any hardware
/// write — the UI cannot send a value the daemon would refuse.
struct DischargeControlsView: View {

    @EnvironmentObject private var appState: AppState

    @State private var targetPercent = 60.0
    @State private var floorPercent = 20.0

    private let supportedFloors: [Double] = [20, 25, 30, 40, 50]

    var body: some View {
        Form {
            Section("Force discharge") {
                if let snapshot = appState.snapshot, snapshot.isForceDischarging,
                   case .forceDischarge(let target, _) = snapshot.activeOverride {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.slash.fill")
                            .foregroundStyle(.red)
                        Text("FORCE DISCHARGE ACTIVE")
                            .font(.headline)
                        Spacer()
                        Text("Current \(snapshot.readings.percentage)% → Target \(target)%")
                            .font(.callout.monospacedDigit())
                    }
                    Button("Stop Force Discharge") {
                        appState.cancelOverrides()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    HStack {
                        Slider(value: $targetPercent, in: 20...100, step: 1) {
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
                    .disabled(!appState.capabilities.supportsForceDischarge)

                    Text("The Mac stops drawing adapter power and runs on the battery until it reaches \(Int(targetPercent))%. Discharge stops automatically at the target, at the safety floor, when the charger is physically unplugged, or before sleep. It cannot be run below \(ChargingPolicyEngine.minimumDischargeFloor)%.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Start Force Discharge") {
                        appState.startForceDischarge(target: Int(targetPercent))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.capabilities.supportsForceDischarge
                              || !appState.effectiveReadings.isExternalConnected)
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
        }
        .formStyle(.grouped)
        .navigationTitle("Discharge")
    }
}
