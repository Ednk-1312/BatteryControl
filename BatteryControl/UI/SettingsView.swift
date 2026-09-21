import AppKit
import BatteryCore
import os
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

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

            Section("Compatibility Database") {
                Button("Install Database File…") {
                    installDatabase()
                }
                if let databaseMessage {
                    Text(databaseMessage)
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundStyle(databaseAccepted ? Color.secondary : Color.red)
                }
                Text("Optional: install a reviewed compatibility database (JSON) so newly verified Macs are recognized without waiting for an app update. The privileged helper validates the file and is the only thing that can write it. A database entry broadens recognition only — this Mac's hardware is still probed and verified at runtime before any control is allowed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local history") {
                Text("BatteryControl keeps a bounded list of factual control events on this Mac. It is not uploaded and does not include usernames, serial numbers, or raw system logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Events stored", value: "\(appState.localHistory.snapshot().count)")
                Button("Clear Local History", role: .destructive) {
                    appState.clearLocalHistory()
                }
            }

            Section("Updates") {
                Toggle("Check for updates (daily, passive)", isOn: Binding(
                    get: { appState.updateCheckEnabled },
                    set: { appState.updateCheckEnabled = $0 }
                ))
                Text("Asks GitHub once a day whether a newer release exists. Nothing is downloaded or installed automatically, and no identifying information is sent. Turning this off stops all update-related network requests.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let update = appState.availableUpdate {
                    HStack {
                        Text("Newer release available: \(update.tagName)")
                            .font(.callout.weight(.medium))
                        Link("View release", destination: URL(string: update.htmlURL) ?? UpdateCheck.releasesURL)
                    }
                } else if appState.updateCheckFailed {
                    Text("The last update check could not reach GitHub. It will retry later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Check Now") {
                    appState.performUpdateCheckNow()
                }
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Scope", value: "Apple Silicon M1–M5 · macOS 14/15/26/27")
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

    // MARK: Compatibility database install

    @State private var databaseMessage: String?
    @State private var databaseAccepted = true

    /// Hand a community database file to the daemon over XPC. The daemon
    /// validates and installs it; this UI never writes the root-owned file.
    private func installDatabase() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(FirmwareProfileLibrary.DatabasePayload.self, from: data) else {
                databaseAccepted = false
                databaseMessage = "\(url.lastPathComponent) is not a valid compatibility database."
                return
            }
            guard let outcome = await DaemonXPCClient.shared.installCompatibilityDatabaseWithRejection(payload) else {
                databaseAccepted = false
                databaseMessage = "Could not reach the helper — try again after Repair Helper."
                return
            }
            if let rejection = outcome.rejectedMessage {
                databaseAccepted = false
                databaseMessage = "Rejected: \(rejection)"
                return
            }
            guard let result = outcome.result else {
                databaseAccepted = false
                databaseMessage = "Communication with the helper failed mid-request."
                return
            }
            databaseAccepted = true
            databaseMessage = "Installed \(result.acceptedProfiles) profile(s); \(result.totalProfiles) now active."
        }
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
