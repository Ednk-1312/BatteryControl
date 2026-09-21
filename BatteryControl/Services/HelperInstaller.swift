import BatteryCore
import Foundation
import os
import ServiceManagement

/// Installs, verifies, repairs, and removes the privileged helper.
///
/// Primary path: SMAppService.daemon (SMAppService, macOS 13+). It requires
/// the LaunchDaemon plist to live inside the app bundle under
/// `Contents/Library/LaunchDaemons/` and registers it with launchd after an
/// administrator authorization prompt. Fallback: an osascript
/// administrator-authenticated copy + bootstrap, which performs the same
/// three steps explicitly — used when SMAppService is unavailable or its
/// registration fails.
final class HelperInstaller {

    enum InstallStep: String {
        case notStarted
        case registeringWithLaunchd = "Registering the privileged helper with launchd…"
        case copyingFiles = "Installing the helper binary…"
        case bootstrapping = "Starting the helper…"
        case verifying = "Verifying the helper…"
        case done = "Done"
        case failed = "Failed"
    }

    /// Errors from the legacy install path.
    enum InstallError: LocalizedError {
        case missingHelper
        case authorizationDeclined

        var errorDescription: String? {
            switch self {
            case .missingHelper:
                return "The helper binary is missing from the app bundle."
            case .authorizationDeclined:
                return "Administrator authorization is required to install the helper."
            }
        }
    }

    private var service: SMAppService? {
        SMAppService.daemon(plistName: "com.batterycontrol.daemon.plist")
    }

    // MARK: Status

    /// Best-effort status of the helper, for the setup UI and diagnostics.
    func currentStatus() -> HelperStatus {
        switch service?.status {
        case .enabled:
            return xpcReachable() ? .running : .unreachable
        case .requiresApproval:
            return .notRunning
        case .notRegistered:
            return filePresent ? .notRunning : .notInstalled
        case .notFound:
            return .notInstalled
        default:
            return xpcReachable() ? .running : filePresent ? .notRunning : .notInstalled
        }
    }

    private var filePresent: Bool {
        FileManager.default.fileExists(atPath: BatteryXPC.helperInstallPath)
    }

    /// Can the app talk to the daemon right now?
    ///
    /// BLOCKING: waits up to ~3s for the XPC round-trip. Only call from a
    /// background queue (the installer paths do). For main-thread call sites
    /// use `staticStatus(xpcDead:)` instead.
    func xpcReachable() -> Bool {
        let probe = DaemonXPCClient.shared
        return probe.pingSync()
    }

    /// Status derived only from registration state and file presence —
    /// never probes XPC, so it never blocks. `xpcDead: true` (the caller
    /// just observed a failed XPC round-trip) promotes an enabled-looking
    /// registration to `.unreachable` honestly.
    func staticStatus(xpcDead: Bool) -> HelperStatus {
        let base: HelperStatus
        switch service?.status {
        case .enabled: base = .running
        case .requiresApproval: base = .notRunning
        case .notRegistered: base = filePresent ? .notRunning : .notInstalled
        case .notFound: base = .notInstalled
        default: base = filePresent ? .notRunning : .notInstalled
        }
        if base == .running, xpcDead { return .unreachable }
        return base
    }

    // MARK: Install / repair

    /// Install (or repair) the helper. `progress` is called on the main
    /// queue with human-readable step text; completion reports success and
    /// an error text when false.
    func install(progress: @escaping (String) -> Void, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Progress is a main-queue contract (mutates @Published state).
            DispatchQueue.main.async { progress(InstallStep.registeringWithLaunchd.rawValue) }

            if let service = self.service {
                switch service.status {
                case .enabled:
                    // Already registered — treat as repair: re-check XPC.
                    break
                case .requiresApproval:
                    DispatchQueue.main.async {
                        completion(false, "macOS needs your approval: open System Settings → General → Login Items & Extensions and enable the BatteryControl helper.")
                    }
                    return
                default:
                    break
                }

                do {
                    try service.register()
                } catch {
                    // Fall through to the osascript fallback below.
                    DaemonAppLog.ui.warning("SMAppService register failed: \(error.localizedDescription)")
                }
            }

            // Verify SMAppService actually took effect; otherwise fall back.
            DispatchQueue.main.async { progress(InstallStep.bootstrapping.rawValue) }
            if self.waitForXPC(timeout: 12) {
                DispatchQueue.main.async { progress(InstallStep.verifying.rawValue) }
                let ok = self.waitForXPC(timeout: 8)
                DispatchQueue.main.async {
                    progress(InstallStep.done.rawValue)
                    completion(ok, ok ? "" : "The helper is registered but did not answer over XPC.")
                }
                return
            }

            DispatchQueue.main.async { progress(InstallStep.copyingFiles.rawValue) }
            let fallbackResult = self.legacyInstall()
            switch fallbackResult {
            case .success:
                DispatchQueue.main.async { progress(InstallStep.verifying.rawValue) }
                let ok = self.waitForXPC(timeout: 20)
                DispatchQueue.main.async {
                    completion(ok, ok ? "" : "The helper is installed but did not answer over XPC.")
                }
            case .failure(let error):
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    /// Remove BatteryControl completely. The daemon owns safe-state
    /// restoration and removal of privileged files; this client only removes
    /// the app bundle and, with explicit consent, user-owned data.
    func uninstallApplication(removeUserData: Bool, progress: @escaping (String) -> Void, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { progress("Restoring normal charging…") }
            guard DaemonXPCClient.shared.uninstallPrivilegedComponentsSync(removeCLI: true) else {
                DispatchQueue.main.async {
                    completion(false, "BatteryControl could not verify normal charging or remove the privileged helper. Nothing else was deleted.")
                }
                return
            }

            if let service = self.service { try? service.unregister() }
            if removeUserData {
                let support = BatteryControlUserData.applicationSupportURL()
                try? FileManager.default.removeItem(at: support)
                UserDefaults.standard.removePersistentDomain(forName: BatteryXPC.appBundleID)
                UserDefaults.standard.synchronize()
            }

            DispatchQueue.main.async { progress("Removing BatteryControl…") }
            let appPath = Bundle.main.bundlePath
            // Bundle.main is expected to be an app bundle, but validate the
            // path before constructing the destructive command. Shell-quote
            // the path independently of AppleScript quoting so an unusual
            // installation path cannot become command injection.
            guard appPath.hasSuffix(".app"), appPath.count > 5, appPath != "/" else {
                DispatchQueue.main.async {
                    completion(false, "The application path could not be validated; privileged components were left untouched.")
                }
                return
            }
            let shell = "/bin/rm -rf \(shellQuoted(appPath))"
            let script = "do shell script \"" + escapedForAppleScript(shell) + "\" with administrator privileges"
            guard self.runOsaScript(script) else {
                DispatchQueue.main.async {
                    completion(false, "The privileged components were removed, but the application could not be removed. You can move BatteryControl.app to the Trash manually.")
                }
                return
            }
            let removed = self.waitForPrivilegedRemoval(timeout: 5)
                && !FileManager.default.fileExists(atPath: appPath)
            DispatchQueue.main.async {
                completion(removed, removed ? "BatteryControl was completely removed; macOS has resumed normal charging management." : "Uninstall could not verify that every BatteryControl component was removed.")
            }
        }
    }

    /// Helper-only removal used by the existing Settings action. It never
    /// deletes the application bundle; the first-class uninstall flow above
    /// does that only after the user confirms it.
    func uninstall(progress: @escaping (String) -> Void, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { progress("Restoring normal charging…") }
            let ok = DaemonXPCClient.shared.uninstallPrivilegedComponentsSync(removeCLI: false)
            if let service = self.service { try? service.unregister() }
            let verified = ok && self.waitForPrivilegedRemoval(timeout: 5)
            DispatchQueue.main.async {
                completion(verified, verified
                    ? "The helper was removed and macOS/default charging restored."
                    : "BatteryControl could not verify safe helper removal; no application files were deleted.")
            }
        }
    }

    /// The explicit fallback: copy the helper into place and bootstrap it
    /// with an administrator-authenticated shell script. The daemon binary
    /// and the LaunchDaemon plist both ride inside the app bundle under
    /// Contents/Library/LaunchDaemons (SMAppService layout).
    private func legacyInstall() -> Result<Void, InstallError> {
        let bundleLaunchDaemons = (Bundle.main.bundlePath as NSString)
            .appendingPathComponent("Contents/Library/LaunchDaemons")
        let daemonSource = (bundleLaunchDaemons as NSString)
            .appendingPathComponent("com.batterycontrol.daemon")
        let plistSource = (bundleLaunchDaemons as NSString)
            .appendingPathComponent("com.batterycontrol.daemon.plist")

        guard FileManager.default.fileExists(atPath: daemonSource) else {
            return .failure(.missingHelper)
        }

        // Copy the daemon to a stable root-owned path, install the plist
        // with an absolute Program path (the bundle copy uses BundleProgram,
        // which only works under SMAppService — a direct launchctl bootstrap
        // needs a concrete executable), then bootstrap it.
        let installedPlist = BatteryXPC.launchDaemonPlistPath
        let shell = """
        set -e
        /bin/mkdir -p '/Library/PrivilegedHelperTools'
        /bin/cp -f \(shellQuoted(daemonSource)) \(shellQuoted(BatteryXPC.helperInstallPath))
        /bin/chmod 755 \(shellQuoted(BatteryXPC.helperInstallPath))
        /usr/sbin/chown root:wheel \(shellQuoted(BatteryXPC.helperInstallPath))
        /bin/mkdir -p '/Library/LaunchDaemons'
        /bin/cp -f \(shellQuoted(plistSource)) \(shellQuoted(installedPlist))
        /bin/chmod 644 \(shellQuoted(installedPlist))
        /usr/sbin/chown root:wheel \(shellQuoted(installedPlist))
        /usr/libexec/PlistBuddy -c 'Delete :BundleProgram' \(shellQuoted(installedPlist)) 2>/dev/null || true
        /usr/libexec/PlistBuddy -c 'Add :Program string \(BatteryXPC.helperInstallPath)' \(shellQuoted(installedPlist)) 2>/dev/null || /usr/libexec/PlistBuddy -c 'Set :Program \(BatteryXPC.helperInstallPath)' \(shellQuoted(installedPlist))
        /bin/launchctl bootout system/\(BatteryXPC.helperBundleID) 2>/dev/null || true
        /bin/launchctl bootstrap system \(shellQuoted(installedPlist))
        """

        let appleScript = "do shell script \"" + escapedForAppleScript(shell) + "\" with administrator privileges"
        return runOsaScript(appleScript)
            ? .success(())
            : .failure(.authorizationDeclined)
    }

    /// Quote one argument for the POSIX shell. This is separate from the
    /// AppleScript escaping below: the shell must never interpret characters
    /// from an app-bundle path as syntax.
    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'") + "'"
    }

    /// Escape a shell string for embedding inside an AppleScript
    /// `do shell script "…"` literal.
    private func escapedForAppleScript(_ shell: String) -> String {
        shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runOsaScript(_ source: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func waitForPrivilegedRemoval(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if BatteryControlUninstallVerification.privilegedComponentsGone() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return BatteryControlUninstallVerification.privilegedComponentsGone()
    }

    @discardableResult
    private func waitForXPC(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if xpcReachable() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
