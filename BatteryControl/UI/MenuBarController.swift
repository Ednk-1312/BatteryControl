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
    /// Last menu content the status bar was given. Rebuilding the NSMenu on
    /// every identical snapshot (10s polls) allocated and invalidated menu
    /// items for nothing; equal content now reuses the existing menu.
    private var lastMenuKey: String?

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
        let key = menuContentKey()
        guard key != lastMenuKey else { return }
        lastMenuKey = key
        statusItem?.menu = buildMenu()
        updateIcon()
    }

    /// Everything the menu displays, as a cheap comparable key. The key is
    /// intentionally the SOURCE data (not rendered text) so wording changes
    /// in DashboardSummary still flow through.
    private func menuContentKey() -> String {
        guard let snapshot = appState?.snapshot else { return "no-snapshot" }
        let icon: String
        if snapshot.isForceDischarging {
            icon = "bolt.slash.fill"
        } else if snapshot.activePolicy.mode != .passthrough {
            icon = snapshot.readings.isCharging ? "bolt.badge.a.fill" : "battery.75percent"
        } else {
            icon = "bolt.fill"
        }
        return [
            String(snapshot.readings.percentage),
            snapshot.readings.isExternalConnected ? "ac" : "bat",
            appState?.controlSummary ?? "",
            DashboardSummary.controlStatus(snapshot: snapshot, isSupportedPlatform: true),
            icon,
            appState?.needsSetup == true ? "setup" : "",
        ].joined(separator: "|")
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
        // Recreating the NSImage for an unchanged symbol allocates for
        // nothing; only swap when the glyph actually changes.
        guard symbol != lastIconSymbol else { return }
        lastIconSymbol = symbol
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BatteryControl")
    }

    private var lastIconSymbol: String?

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
