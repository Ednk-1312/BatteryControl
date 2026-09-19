import BatteryCore
import SwiftUI

/// Root layout: sidebar navigation + detail pane. On first run a prominent
/// setup banner routes the user through helper installation.
struct RootView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { appState.route },
                set: { appState.route = $0 ?? .dashboard }
            )) {
                Section {
                    Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent")
                        .tag(AppState.Route.dashboard)
                    Label("Charging", systemImage: "bolt.fill")
                        .tag(AppState.Route.charging)
                    Label("Discharge", systemImage: "bolt.slash.fill")
                        .tag(AppState.Route.discharge)
                    Label("Calibration", systemImage: "arrow.triangle.2.circlepath")
                        .tag(AppState.Route.calibration)
                }
                Section("Reference") {
                    Label("Battery Info", systemImage: "info.circle")
                        .tag(AppState.Route.info)
                    Label("Diagnostics", systemImage: "stethoscope")
                        .tag(AppState.Route.diagnostics)
                    Label("Settings", systemImage: "gearshape")
                        .tag(AppState.Route.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("BatteryControl")
        } detail: {
            VStack(spacing: 0) {
                if appState.needsSetup && appState.isSupported {
                    SetupBanner()
                }
                if !appState.isSupported {
                    UnsupportedView()
                }
                detail
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.route {
        case .dashboard: DashboardView()
        case .charging: ChargingSettingsView()
        case .discharge: DischargeControlsView()
        case .calibration: CalibrationView()
        case .info: BatteryInformationView()
        case .diagnostics: DiagnosticsView()
        case .settings: SettingsView()
        }
    }
}

/// Persistent setup banner until the helper is running.
struct SetupBanner: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.yellow)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Privileged helper required")
                    .font(.headline)
                Text("BatteryControl needs a small privileged helper to control charging. It runs in the background and enforces your limits even when this app is closed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let progress = appState.installProgress {
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let message = appState.lastAckMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(spacing: 8) {
                Button(appState.helperStatus == .notInstalled ? "Install Helper" : "Repair Helper") {
                    appState.installHelper()
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isInstalling)
                Button("Open Setup Guide") {
                    appState.route = .dashboard
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .top])
    }
}

/// Shown when the Mac is outside the supported M1–M4 / macOS 15 scope.
struct UnsupportedView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(PlatformIdentity.unsupportedMessage)
                .font(.title3)
                .multilineTextAlignment(.center)
            Text(appState.platform.unsupportedReason ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(appState.platform.summaryLine)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
