import BatteryCore
import SwiftUI

/// The primary dashboard: exactly the summary the spec asks for.
struct DashboardView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                staleProcessBanner
                daemonUnavailableBanner
                statusRow
                banners
                controls
                quickFacts
            }
            .padding(20)
        }
    }

    /// Shown when this GUI process predates the installed app bundle: the
    /// daemon keeps refusing its connections after an in-place upgrade, so
    /// no amount of waiting will restore control. Offer the relaunch.
    @ViewBuilder
    private var staleProcessBanner: some View {
        if appState.isStaleProcess {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("BatteryControl was updated while it was running")
                        .font(.headline)
                    Text("Reopen the app to reconnect to the privileged daemon. Charging control continues meanwhile under the saved settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reopen") { appState.relaunchApp() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// State-matrix row "daemon unavailable": an explicit banner instead of
    /// silently keeping stale values — and the control tile reads
    /// "Unavailable", never "Verified" (enforced by DashboardSummary).
    @ViewBuilder
    private var daemonUnavailableBanner: some View {
        // Superseded by staleProcessBanner when the process itself is stale:
        // there is no "reconnect automatically" to wait for.
        if appState.snapshot == nil && !appState.isStaleProcess {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Can't reach the privileged helper")
                        .font(.headline)
                    Text("Charging control status is unknown until the connection is restored. Your saved settings are safe and will be re-applied by the helper.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retry") { appState.poll() }
                    .buttonStyle(.bordered)
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: Status grid

    /// A uniform 2×3 grid: every cell identical in size regardless of text
    /// length, so the dashboard stays visually even (long backend names or
    /// band values can no longer stretch one tile and squeeze the rest).
    private var statusRow: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
            alignment: .leading,
            spacing: 12
        ) {
            statusCell(
                title: "Battery",
                value: "\(appState.effectiveReadings.percentage)%",
                icon: batteryIcon
            )
            statusCell(
                title: "Power",
                value: appState.effectiveReadings.isExternalConnected ? "AC" : "Battery",
                icon: appState.effectiveReadings.isExternalConnected ? "powerplug.fill" : "battery.100"
            )
            statusCell(
                title: "Charging",
                value: chargingText,
                icon: chargingIcon
            )
            statusCell(
                title: "Charge Limit",
                value: limitText,
                icon: "gauge.with.dots.needle.bottom.50percent"
            )
            statusCell(
                title: "Backend",
                value: backendText,
                icon: "cpu"
            )
            statusCell(
                title: "Control",
                value: controlText,
                icon: "checkmark.shield"
            )
        }
    }

    private func statusCell(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var batteryIcon: String {
        let pct = appState.effectiveReadings.percentage
        if appState.effectiveReadings.isCharging { return "battery.100.bolt" }
        if pct >= 75 { return "battery.100" }
        if pct >= 50 { return "battery.75" }
        if pct >= 25 { return "battery.50" }
        return "battery.25"
    }

    private var chargingText: String {
        let r = appState.effectiveReadings
        if appState.snapshot?.isForceDischarging == true { return "Discharging (forced)" }
        if appState.snapshot?.isForceCharging == true { return "Charging (override)" }
        if !r.isExternalConnected { return "On battery" }
        if r.isCharging { return "Charging" }
        if appState.snapshot?.activePolicy.mode != .passthrough { return "Limited" }
        return "Not charging"
    }

    private var chargingIcon: String {
        if appState.snapshot?.isForceDischarging == true { return "bolt.slash.fill" }
        if appState.effectiveReadings.isCharging { return "bolt.fill" }
        return "pause.circle"
    }

    /// The user-facing limit is the number the user set ("80%"), not the
    /// internal hysteresis band. Derived from the shared, tested
    /// DashboardSummary model — the single definition of this semantics.
    private var limitText: String {
        DashboardSummary.primaryLimitText(policy: appState.snapshot?.activePolicy)
    }

    private var backendText: String {
        guard let snapshot = appState.snapshot else { return "—" }
        return BackendID(snapshot.activeBackendID).shortName
    }

    private var controlText: String {
        DashboardSummary.controlStatus(snapshot: appState.snapshot, isSupportedPlatform: appState.isSupported)
    }

    // MARK: Banners

    @ViewBuilder
    private var banners: some View {
        if let snapshot = appState.snapshot {
            if snapshot.isForceDischarging, case .forceDischarge(let target, _, _) = snapshot.activeOverride {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.slash.fill")
                        .foregroundStyle(.red)
                    Text("FORCE DISCHARGE ACTIVE")
                        .font(.headline)
                    Text("Current: \(snapshot.readings.percentage)% · Target: \(target)%")
                        .font(.callout.monospacedDigit())
                    Spacer()
                    Button("Stop") { appState.cancelOverrides() }
                        .buttonStyle(.bordered)
                }
                .padding(12)
                .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            if snapshot.isForceCharging, case .forceCharge(let target) = snapshot.activeOverride {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.badge.clock.fill")
                        .foregroundStyle(.orange)
                    Text("CHARGING OVERRIDE ACTIVE")
                        .font(.headline)
                    Text("Charging to \(target)%; the normal limit resumes afterwards.")
                        .font(.callout)
                    Spacer()
                    Button("Cancel Override") { appState.cancelOverrides() }
                        .buttonStyle(.bordered)
                }
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            if !snapshot.controlIsVerified,
               snapshot.activePolicy.mode != .passthrough || snapshot.isForceDischarging || snapshot.isForceCharging {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text("The last control change has not been verified yet. The state is re-checked automatically — after a charge change the battery's firmware can take a couple of minutes to report it. If this warning survives several minutes, see Diagnostics.")
                        .font(.callout)
                    Spacer()
                }
                .padding(12)
                .background(.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Controls")
                .font(.headline)
            HStack(spacing: 12) {
                NavigationLink {
                    ChargingSettingsView()
                } label: {
                    BigControlButton(
                        title: "Charge Limit",
                        subtitle: "Set where charging stops",
                        icon: "gauge.with.dots.needle.bottom.50percent"
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    DischargeControlsView()
                } label: {
                    BigControlButton(
                        title: "Force Discharge",
                        subtitle: "Drain to a safe target on AC",
                        icon: "bolt.slash.fill"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    appState.startForceCharge(target: 100)
                } label: {
                    BigControlButton(
                        title: "Charge to 100%",
                        subtitle: "One-time override, then back to your limit",
                        icon: "bolt.badge.clock"
                    )
                }
                .buttonStyle(.plain)
                .disabled(!appState.capabilities.supportsForceCharge)

                NavigationLink {
                    CalibrationView()
                } label: {
                    BigControlButton(
                        title: "Calibration",
                        subtitle: "Guided gauge refresh, safely",
                        icon: "arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Charging behavior (the hysteresis explanation)

    /// Explains the band in USER terms. The lower hysteresis threshold is
    /// presented as when charging RESUMES — never as a second "limit"
    /// (the old "Lower limit: 78%" card leaked an implementation detail
    /// as if it were the user's charge limit).
    private var quickFacts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(DashboardSummary.chargingBehaviorTitle(policy: appState.snapshot?.activePolicy))
                .font(.subheadline.weight(.medium))
            Text(behaviorText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message = appState.lastAckMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var behaviorText: String {
        guard let policy = appState.snapshot?.activePolicy else {
            return "BatteryControl can't reach the privileged helper right now, so your charging behavior can't be confirmed. It will reconnect automatically."
        }
        return DashboardSummary.resumeBehaviorText(policy: policy)
    }
}

/// A large, calm control tile.
struct BigControlButton: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(14)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
