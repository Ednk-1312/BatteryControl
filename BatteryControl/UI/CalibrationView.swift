import BatteryCore
import SwiftUI

/// Guided battery-gauge calibration: discharge to 20%, charge to 100%,
/// hold 3 hours, drop to the charge limit, finish resting at the limit on
/// wall power. The helper owns the session so it continues while the app is
/// closed; this view reflects it.
struct CalibrationView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("About calibration") {
                Text("Calibration re-trains the battery gauge's estimate of full-charge capacity by running one controlled full cycle. It does not repair physical battery health — capacity lost to aging cannot be restored by any software.")
                    .font(.callout)
                Text("The cycle: discharge to 20%, charge to 100% without interruption, hold at 100% for 3 hours so the gauge records a true full reference, then drop to your charge limit. Afterwards your normal policy resumes and the battery rests at the limit while the Mac runs off wall power.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("It pauses automatically if the battery reports a fault, falls below the hard floor, or a stage stops making progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let session = appState.snapshot?.activeCalibration,
               session.isActive || session.stage == .finish {
                Section("Progress") {
                    stageList(session: session)
                    if session.stage == .finish {
                        Button("Close") {
                            appState.cancelCalibration()
                        }
                    } else {
                        Button("Cancel Calibration") {
                            appState.cancelCalibration()
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(.red)
                    }
                }
            } else {
                Section("Start") {
                    Text("Plan for most of a day: discharge to 20%, a full charge, a 3-hour hold, and the drop back to your limit. Keep the Mac plugged in except during the two discharge stages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Begin Calibration") {
                        appState.beginCalibration()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.capabilities.supportsCalibration
                              || !appState.effectiveReadings.isExternalConnected)

                    if !appState.effectiveReadings.isExternalConnected {
                        Label("Connect the charger to start — the cycle begins by discharging from whatever level you are at now.",
                              systemImage: "powerplug")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Calibration")
    }

    @ViewBuilder
    private func stageList(session: CalibrationSession) -> some View {
        ForEach(Array(CalibrationStage.progressOrder.enumerated()), id: \.element) { index, stage in
            HStack(spacing: 10) {
                let currentIndex = CalibrationStage.progressOrder.firstIndex(of: session.stage) ?? 0
                let state: StageState = stage == session.stage
                    ? .current
                    : (index < currentIndex ? .done : .pending)
                Image(systemName: state.symbol)
                    .foregroundStyle(state.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(stage.displayName)
                        .font(.callout.weight(state == .current ? .semibold : .regular))
                    if stage == session.stage {
                        Text(session.abortReason ?? stage.detailText)
                            .font(.caption)
                            .foregroundStyle(session.abortReason != nil ? .red : .secondary)
                    }
                }
            }
        }
    }

    private enum StageState {
        case current
        case done
        case pending

        var symbol: String {
            switch self {
            case .current: return "circle.inset.filled"
            case .done: return "checkmark.circle.fill"
            case .pending: return "circle"
            }
        }

        var color: Color {
            switch self {
            case .current: return .green
            case .done: return .secondary
            case .pending: return .secondary.opacity(0.5)
            }
        }
    }
}
