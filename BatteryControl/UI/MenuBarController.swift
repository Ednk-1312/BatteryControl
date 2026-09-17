import AppKit
import BatteryCore
import Combine

/// Optional menu-bar icon (NSStatusItem) — the primary access point to the
/// app UI. Owned by the app delegate so it can appear and disappear at
/// runtime with zero placeholders: when hidden, the item is removed from
/// the status bar entirely.
///
/// This is convenience UI only: the privileged daemon enforces charging
/// independently, and the app process keeps running (holding XPC telemetry,
/// persistence, and wake/reconnect handling) with the icon hidden.
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private var appState: AppState?
    private var cancellable: AnyCancellable?

    func start(appState: AppState) {
        self.appState = appState
        // Redraw on every snapshot poll.
        cancellable = appState.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMenu()
            }
        refreshVisibility()
    }

    /// Apply the user's "Show menu bar icon" preference. Default: shown.
    func refreshVisibility() {
        let show = MenuBarVisibility.shouldShowIcon(defaults: .standard)
        if show {
            if statusItem == nil {
                install()
            }
        } else {
            remove()
        }
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "BatteryControl")
        item.menu = buildMenu()
        statusItem = item
    }

    private func remove() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    private func refreshMenu() {
        statusItem?.menu = buildMenu()
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        if let snapshot = appState?.snapshot {
            if snapshot.isForceDischarging {
                symbol = "bolt.slash.fill"
            } else if snapshot.activePolicy.mode != .passthrough {
                symbol = snapshot.readings.isCharging ? "bolt.badge.a.fill" : "battery.75percent"
            } else {
                symbol = "bolt.fill"
            }
        } else {
            symbol = "bolt.fill"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BatteryControl")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let appState = self.appState

        if let snapshot = appState?.snapshot {
            let statusLine = NSMenuItem(
                title: "\(snapshot.readings.percentage)% · \(snapshot.readings.isExternalConnected ? "AC" : "Battery") · \(appState?.controlSummary ?? "")",
                action: nil,
                keyEquivalent: ""
            )
            statusLine.isEnabled = false
            menu.addItem(statusLine)

            let verified = NSMenuItem(
                title: "Control: \(DashboardSummary.controlStatus(snapshot: snapshot, isSupportedPlatform: true))",
                action: nil,
                keyEquivalent: ""
            )
            verified.isEnabled = false
            menu.addItem(verified)
            menu.addItem(.separator())
        }

        let open = NSMenuItem(title: "Open BatteryControl", action: #selector(openMainWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        if appState?.needsSetup == true {
            let setup = NSMenuItem(title: "Complete Setup…", action: #selector(openMainWindow), keyEquivalent: "")
            setup.target = self
            menu.addItem(setup)
        }

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // In-menu mirror of the Settings toggle, so the icon can be hidden
        // without hunting through settings. Hiding never stops control —
        // the daemon keeps enforcing and the app keeps running.
        let showIcon = NSMenuItem(
            title: "Show Menu Bar Icon",
            action: #selector(toggleIconVisibility(_:)),
            keyEquivalent: ""
        )
        showIcon.target = self
        showIcon.state = MenuBarVisibility.shouldShowIcon(defaults: .standard) ? .on : .off
        menu.addItem(showIcon)

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Check Status", action: #selector(checkStatus), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "Quit BatteryControl", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openMainWindow() {
        appState?.route = .dashboard
        NotificationCenter.default.post(name: .openMainWindowRequested, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleIconVisibility(_ sender: NSMenuItem) {
        let show = !MenuBarVisibility.shouldShowIcon(defaults: .standard)
        MenuBarVisibility.setShowIcon(show, defaults: .standard)
        NotificationCenter.default.post(name: .menuBarVisibilityChanged, object: nil)
    }

    @objc private func checkStatus() {
        appState?.poll()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let openMainWindowRequested = Notification.Name("openMainWindowRequested")
    static let openSettingsRequested = Notification.Name("openSettingsRequested")
    static let menuBarVisibilityChanged = Notification.Name("menuBarVisibilityChanged")
}
