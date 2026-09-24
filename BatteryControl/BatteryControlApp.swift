import AppKit
import BatteryCore
import SwiftUI

/// App lifecycle for a true menu-bar (background) utility:
///
/// - The app never appears in the Dock: the activation policy is
///   `.accessory` for the whole process lifetime, set as early as possible.
///   This is the platform-correct configuration for a menu-bar utility —
///   not a temporary Dock-hiding hack.
/// - The menu-bar icon is the primary way to access the app UI. It is
///   visible by default and can be hidden via the "Show menu bar icon"
///   setting; hiding it does not stop the app or the privileged daemon.
/// - The main window is hosted in AppKit (not a SwiftUI `Window` scene) so
///   it can be reliably re-opened after being closed — an accessory app gets
///   no Window menu and no Dock icon to click, so re-opening must be fully
///   under our control.
/// - Closing the window never terminates the app
///   (`applicationShouldTerminateAfterLastWindowClosed` → false), and the
///   privileged daemon runs independently regardless.
///
/// Reopen path when the icon is hidden: relaunching BatteryControl (Finder,
/// Spotlight, or `open -a`) routes into `applicationShouldHandleReopen`,
/// which shows the window. No Terminal and no reinstall required.
final class AppDelegate: NSObject, NSApplicationDelegate {

    let appState = AppState()
    private let menuBarController = MenuBarController()
    private var mainWindowController: NSWindowController?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Single-instance guard. BatteryControl is a menu-bar accessory, so a
    /// second launched instance is never useful — it would add a second
    /// status item, double the polling, and split the UI across two
    /// processes. `open -n` (or two rapid launches) otherwise happily runs
    /// duplicates forever. When another instance owns the app, this process
    /// asks that instance to show its window and exits immediately.
    ///
    /// The check is the bundle identifier among GUI apps owned by this
    /// user, which is robust for this purpose: the daemon is a separate
    /// executable with a different bundle ID and is never matched.
    private static func anotherInstanceIsRunning() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.batterycontrol.app")
            .contains { $0 != NSRunningApplication.current }
    }

    /// Accessory from the very first moment — no Dock icon flash at launch.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Duplicate launch: hand over to the running instance and exit.
        // Activating first makes the existing instance show its window (the
        // same reopen path a user expects from clicking the icon again).
        //
        // Handoff exception: `relaunchApp()` (stale-process recovery) starts
        // the new instance BEFORE the old one exits. A naive guard would make
        // the newborn exit, then the old process terminate — zero instances.
        // So the duplicate briefly re-checks: if the other instance goes away
        // within the handoff window, this process continues as the primary;
        // otherwise it activates the established instance and exits.
        if Self.anotherInstanceIsRunning() {
            NSApp.setActivationPolicy(.accessory)
            let handoffDeadline = Date().addingTimeInterval(6)
            var tookOver = false
            while Date() < handoffDeadline {
                Thread.sleep(forTimeInterval: 0.5)
                if !Self.anotherInstanceIsRunning() {
                    tookOver = true
                    break
                }
            }
            guard !tookOver else {
                // The previous instance exited mid-handoff; we are the app now.
                return
            }
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.batterycontrol.app")
                .first { $0 != NSRunningApplication.current }?
                .activate()
            exit(0)
        }

        // Belt and braces: also assert the policy after launch in case any
        // framework code changed it.
        NSApp.setActivationPolicy(.accessory)

        menuBarController.start(appState: appState)

        NotificationCenter.default.addObserver(
            self, selector: #selector(openMainWindow),
            name: .openMainWindowRequested, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuBarVisibilityChanged),
            name: .menuBarVisibilityChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings),
            name: .openSettingsRequested, object: nil
        )

        // Always leave the user one visible access point on a fresh launch:
        // the setup flow if setup isn't complete, otherwise the main window
        // whenever the menu-bar icon is hidden. (Without this, quitting and
        // relaunching with the icon hidden would present no UI at all.)
        if !appState.setupComplete || !MenuBarVisibility.shouldShowIcon(defaults: .standard) {
            openMainWindow()
        }
    }

    /// Relaunch while already running (Finder/Spotlight/`open -a`) re-opens
    /// the UI. This is the documented reopen path when the menu-bar icon is
    /// hidden — no reinstall, no Terminal.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
    }

    // MARK: Main window

    /// Show (creating if needed) the main window and bring it to front.
    @objc func openMainWindow() {
        appState.route = .dashboard
        let controller: NSWindowController
        if let existing = mainWindowController {
            controller = existing
        } else {
            controller = NSWindowController(window: Self.makeMainWindow(appState: appState))
            mainWindowController = controller
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func makeMainWindow(appState: AppState) -> NSWindow {
        let root = RootView()
            .environmentObject(appState)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "BatteryControl"
        window.styleMask.insert([.miniaturizable, .resizable])
        window.setContentSize(NSSize(width: 900, height: 640))
        window.minSize = NSSize(width: 760, height: 560)
        window.center()
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        return window
    }

    @objc private func menuBarVisibilityChanged() {
        menuBarController.refreshVisibility()
    }

    /// Open the Settings scene (macOS 14+ renamed the selector).
    @objc func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

@main
struct BatteryControlApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The main window is hosted in AppKit (see AppDelegate) so it can be
        // re-opened reliably in an accessory (menu-bar-only) app. SwiftUI
        // scenes are intentionally limited to Settings.
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
                .frame(width: 460)
        }
    }
}
