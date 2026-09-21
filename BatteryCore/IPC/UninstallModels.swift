import Foundation

/// The only privileged uninstall request exposed to clients. The daemon
/// always restores normal charging before removing its own files.
public struct UninstallRequest: Codable, Equatable, Sendable {
    /// Remove the CLI installed by the GUI+CLI package as well.
    public let removeCLI: Bool

    public init(removeCLI: Bool = true) {
        self.removeCLI = removeCLI
    }
}

public enum UninstallDataChoice: String, Codable, CaseIterable, Sendable {
    case removeData
    case keepData

    public var title: String {
        switch self {
        case .removeData: return "Remove BatteryControl and its local data"
        case .keepData: return "Remove BatteryControl but keep settings/history"
        }
    }
}

/// User-owned data paths are separate from root-owned daemon state. The GUI
/// removes these only when the user explicitly chooses removeData.
public enum BatteryControlUserData {
    public static let applicationSupportFolderName = "BatteryControl"

    public static func applicationSupportURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }
}

/// Read-only verification used after the privileged teardown request. File
/// deletion alone is not enough: launchd can retain a loaded job after its
/// plist is gone, so uninstall must also confirm the named job is absent.
public enum BatteryControlUninstallVerification {
    public static func launchJobExists() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(BatteryXPC.helperBundleID)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            // If launchctl itself cannot be executed, do not claim removal.
            return true
        }
    }

    public static func privilegedComponentsGone() -> Bool {
        !FileManager.default.fileExists(atPath: BatteryXPC.helperInstallPath)
            && !FileManager.default.fileExists(atPath: BatteryXPC.launchDaemonPlistPath)
            && !launchJobExists()
    }
}
