import BatteryCore
import SwiftUI

/// Root layout: sidebar navigation + detail pane. On first run a prominent
/// setup banner routes the user through helper installation.
struct RootView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            // Plain button rows, not `List(selection:)`. The selection-based
            // sidebar desynced from the route binding on macOS 15 (clicks
            // stopped registering after entering a pane), stranding the user
            // in that pane — the only escape was relaunching. A button is a
            // stateless action on the route, so navigation cannot wedge.
            List {
                Section {
                    sidebarRow(.dashboard, "Dashboard", "gauge.with.dots.needle.67percent")
                    sidebarRow(.charging, "Charging", "bolt.fill")
                    sidebarRow(.discharge, "Discharge", "bolt.slash.fill")
                    sidebarRow(.calibration, "Calibration", "arrow.triangle.2.circlepath")
                }
                Section("Reference") {
                    sidebarRow(.info, "Battery Info", "info.circle")
                    sidebarRow(.diagnostics, "Diagnostics", "stethoscope")
                    sidebarRow(.settings, "Settings", "gearshape")
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("BatteryControl")
        } detail: {
            VStack(spacing: 0) {
                // A stale process (app upgraded while running) supersedes the
                // setup banner: the helper is fine — this process is the
                // outdated component. Showing "Repair Helper" here was the
                // contradiction on the dashboard (banner + "Active &
                // verified" tiles at once) and offered an action that could
                // never fix the actual problem.
                if HelperStatusDerivation.shouldShowSetupBanner(
                    needsSetup: appState.needsSetup,
                    isSupported: appState.isSupported,
                    isStaleProcess: appState.isStaleProcess
                ) {
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

    /// One sidebar entry: full-row hit area, selected row visibly marked.
    private func sidebarRow(_ route: AppState.Route, _ title: String, _ systemImage: String) -> some View {
        let isSelected = appState.route == route
        return Button {
            appState.route = route
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
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
    @State private var showingGuide = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.yellow)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Privileged helper required")
                    .font(.headline)
                if appState.helperStatus == .outdated {
                    Text("The privileged helper is an older version than this app. Reopen BatteryControl after updating — if the banner persists, Repair Helper will bring the helper up to date.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("BatteryControl needs a small privileged helper to control charging. It runs in the background and enforces your limits even when this app is closed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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
                    showingGuide = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .top])
        .sheet(isPresented: $showingGuide) {
            SetupGuideView()
                .environmentObject(appState)
                .frame(width: 520, height: 390)
        }
    }
}

/// The setup guide is a real surface rather than a no-op navigation action.
/// It remains unprivileged; installation still goes through AppState and the
/// existing authenticated helper-registration flow.
private struct SetupGuideView: View {

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
                Text("Set up BatteryControl")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }

            Text("BatteryControl needs one privileged helper to control charging safely. The helper runs independently in the background, so limits continue working when the window is closed.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                setupStep("1", "Click Install Helper below.")
                setupStep("2", "Approve the administrator prompt from macOS when it appears. BatteryControl never stores your password.")
                setupStep("3", "Wait for the helper status to show Running, then choose a charge limit in Charging.")
            }

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

            Spacer()

            HStack {
                Text("Helper: \(appState.helperStatusText)")
                    .font(.callout.weight(.medium))
                Spacer()
                Button(appState.helperStatus == .notInstalled ? "Install Helper" : "Repair Helper") {
                    appState.installHelper()
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isInstalling)
            }
        }
        .padding(24)
    }

    private func setupStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
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
