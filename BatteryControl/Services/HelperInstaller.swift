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
    func xpcReachable() -> Bool {
        let probe = DaemonClient.shared
        return probe.pingSync()
    }

    // MARK: Install / repair

    /// Install (or repair) the helper. `progress` is called on the main
    /// queue with human-readable step text; completion reports success and
    /// an error text when false.
    func install(progress: @escaping (String) -> Void, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            progress(InstallStep.registeringWithLaunchd.rawValue)

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
            progress(InstallStep.bootstrapping.rawValue)
            if self.waitForXPC(timeout: 12) {
                progress(InstallStep.verifying.rawValue)
                let ok = self.waitForXPC(timeout: 8)
                DispatchQueue.main.async {
                    progress(InstallStep.done.rawValue)
                    completion(ok, ok ? "" : "The helper is registered but did not answer over XPC.")
                }
                return
            }

            progress(InstallStep.copyingFiles.rawValue)
            let fallbackResult = self.legacyInstall()
            switch fallbackResult {
            case .success:
                progress(InstallStep.verifying.rawValue)
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

    /// Remove the helper (restore charging first). Used by "Remove Helper".
    func uninstall(progress: @escaping (String) -> Void, completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Restore normal charging via XPC before tearing down, if we can.
            _ = DaemonClient.shared.cancelOverridesSync()

            if let service = self.service {
                try? service.unregister()
            }
            progress("Removing the helper files…")
            let shell = "/bin/launchctl bootout system/\(BatteryXPC.helperBundleID) 2>/dev/null; /bin/rm -f '\(BatteryXPC.launchDaemonPlistPath)' '\(BatteryXPC.helperInstallPath)'"
            let script = "do shell script \"" + escapedForAppleScript(shell) + "\" with administrator privileges"
            let ok = runOsaScript(script)
            DispatchQueue.main.async {
                completion(ok, ok ? "" : "Administrator authorization was declined or the files could not be removed.")
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
        /bin/cp -f '\(daemonSource)' '\(BatteryXPC.helperInstallPath)'
        /bin/chmod 755 '\(BatteryXPC.helperInstallPath)'
        /usr/sbin/chown root:wheel '\(BatteryXPC.helperInstallPath)'
        /bin/mkdir -p '/Library/LaunchDaemons'
        /bin/cp -f '\(plistSource)' '\(installedPlist)'
        /bin/chmod 644 '\(installedPlist)'
        /usr/sbin/chown root:wheel '\(installedPlist)'
        /usr/libexec/PlistBuddy -c 'Delete :BundleProgram' '\(installedPlist)' 2>/dev/null || true
        /usr/libexec/PlistBuddy -c 'Add :Program string \(BatteryXPC.helperInstallPath)' '\(installedPlist)' 2>/dev/null || /usr/libexec/PlistBuddy -c 'Set :Program \(BatteryXPC.helperInstallPath)' '\(installedPlist)'
        /bin/launchctl bootout system/\(BatteryXPC.helperBundleID) 2>/dev/null || true
        /bin/launchctl bootstrap system '\(installedPlist)'
        """

        let appleScript = "do shell script \"" + escapedForAppleScript(shell) + "\" with administrator privileges"
        return runOsaScript(appleScript)
            ? .success(())
            : .failure(.authorizationDeclined)
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
