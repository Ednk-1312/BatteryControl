import BatteryCore
import Foundation

/// Persists the desired policy (and any override) in a root-owned JSON file
/// so the charging policy survives daemon restarts and reboots. The main app
/// never writes this file — it goes through XPC.
final class PolicyStore {

    struct StoredState: Codable, Equatable {
        var policy: ChargingPolicy
        var override: PolicyOverride
        var calibration: CalibrationSession?
        var updatedAt: Date
    }

    private let path = BatteryXPC.helperConfigPath
    private let queue = DispatchQueue(label: "com.batterycontrol.daemon.store")

    private var cached: StoredState
    /// Modification date of the file `cached` was loaded from. The file is
    /// also written by recovery tooling (the daemon CLI) while the daemon
    /// runs, so `state` re-reads it whenever the mtime changes — otherwise
    /// an externally persisted policy would never reach the live engine.
    private var cachedMtime: Date?

    init() {
        if let loaded = PolicyStore.load(from: BatteryXPC.helperConfigPath) {
            cached = loaded
            cachedMtime = PolicyStore.modificationDate(of: BatteryXPC.helperConfigPath)
        } else {
            if FileManager.default.fileExists(atPath: BatteryXPC.helperConfigPath) {
                // A store that exists but does not decode is quarantined
                // (never silently overwritten) so a corrupt file can be
                // inspected later. With atomic saves below this should not
                // happen; the old non-atomic writer could produce it.
                let quarantine = "\(BatteryXPC.helperConfigPath).corrupt-\(Int(Date().timeIntervalSince1970))"
                _ = try? FileManager.default.moveItem(
                    atPath: BatteryXPC.helperConfigPath,
                    toPath: quarantine
                )
                DaemonLog.error(
                    "Policy store was unreadable and has been quarantined to \(quarantine); starting from defaults.",
                    operation: "startup"
                )
            }
            cached = StoredState(
                policy: .passthrough(),
                override: .none,
                calibration: nil,
                updatedAt: Date()
            )
        }
    }

    var state: StoredState {
        queue.sync {
            reloadFromDiskIfChanged()
            return cached
        }
    }

    private func reloadFromDiskIfChanged() {
        guard let mtime = PolicyStore.modificationDate(of: path) else { return }
        guard mtime != cachedMtime else { return }
        if let loaded = PolicyStore.load(from: path) {
            cached = loaded
            cachedMtime = mtime
        }
    }

    private static func modificationDate(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    func update(_ mutate: (inout StoredState) -> Void) {
        queue.sync {
            mutate(&cached)
            cached.updatedAt = Date()
            save()
        }
    }

    private func save() {
        // Called with `queue` held.
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o755,
        ])
        guard let data = try? JSONEncoder().encode(cached) else { return }
        // Atomic replacement. A crash mid-write must never truncate or
        // corrupt the store: decode failure silently reverts the charging
        // policy to passthrough (limit gone, battery charges to 100%).
        // Write a complete temp file in the same directory, fsync it, then
        // rename(2) it over the target — readers observe either the old or
        // the new file, never a partial one.
        let tmp = "\(path).tmp-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [
            .posixPermissions: 0o600,
        ]), let handle = FileHandle(forUpdatingAtPath: tmp) else {
            try? FileManager.default.removeItem(atPath: tmp)
            return
        }
        _ = try? handle.synchronize() // fsync the data before the rename
        try? handle.close()
        let renamed: Bool
        if FileManager.default.fileExists(atPath: path) {
            renamed = (try? FileManager.default.replaceItemAt(
                URL(fileURLWithPath: path),
                withItemAt: URL(fileURLWithPath: tmp)
            )) != nil
        } else {
            renamed = (try? FileManager.default.moveItem(atPath: tmp, toPath: path)) != nil
        }
        guard renamed else {
            try? FileManager.default.removeItem(atPath: tmp)
            return
        }
        cachedMtime = PolicyStore.modificationDate(of: path)
    }

    private static func load(from path: String) -> StoredState? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(StoredState.self, from: data)
    }
}
