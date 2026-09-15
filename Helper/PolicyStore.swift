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
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o755,
        ])
        guard let data = try? JSONEncoder().encode(cached) else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: data, attributes: [
                .posixPermissions: 0o600,
            ])
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func load(from path: String) -> StoredState? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(StoredState.self, from: data)
    }
}
