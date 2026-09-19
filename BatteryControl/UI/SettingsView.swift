import BatteryCore
import os
import ServiceManagement
import SwiftUI

/// Settings scene: menu-bar visibility, launch-at-login, helper management.
struct SettingsView: View {

    @EnvironmentObject private var appState: AppState
    @AppStorage(MenuBarVisibility.key) private var showMenuBarIcon = MenuBarVisibility.defaultShowIcon
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Menu Bar") {
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { _, _ in
                        NotificationCenter.default.post(name: .menuBarVisibilityChanged, object: nil)
                    }
                Text("The menu-bar icon is optional and is the primary way to open BatteryControl. Hiding it changes nothing else: charging limits, force discharge, and calibration keep running in the privileged helper, and this app keeps working in the background. To reopen the window with the icon hidden, just launch BatteryControl again from Launchpad, Spotlight, or Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open BatteryControl at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            Section("Privileged Helper") {
                LabeledContent("Status", value: appState.helperStatusText)
                if let progress = appState.installProgress {
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button(appState.helperStatus == .notInstalled ? "Install Helper…" : "Repair Helper…") {
                        appState.installHelper()
                    }
                    .disabled(appState.isInstalling)

                    if appState.helperStatus == .running {
                        Button("Remove Helper…", role: .destructive) {
                            appState.removeHelper()
                        }
                        .disabled(appState.isInstalling)
                    }
                }
                Text("Removing the helper restores macOS charging control and stops all BatteryControl background enforcement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Scope", value: "Apple Silicon M1–M4 · macOS 14/15/26/27")
                if let tier = appState.snapshot?.firmwareProfileTier {
                    LabeledContent("This Mac", value: tierHeadline(tier))
                    Text(DashboardSummary.compatibilityLine(tier: tier))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("BatteryControl is honest by design: controls that cannot be verified are shown as unverified, and features the hardware does not support are disabled rather than faked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Short tier headline for Settings; the plain-language explanation is
    /// shared with the dashboard via DashboardSummary.
    private func tierHeadline(_ tier: FirmwareProfileTier) -> String {
        switch tier {
        case .verified: return "Hardware verified"
        case .compatibleByCapability: return "Capability compatible"
        case .untested: return "Read-only (untested firmware)"
        case .unsupported: return "Unsupported"
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            DaemonAppLog.installer.error("Launch-at-login failed: \(error.localizedDescription)")
        }
    }
}
