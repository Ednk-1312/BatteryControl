import BatteryCore
import Foundation
import os

/// Daemon logging. Writes to the unified log, to a user-readable log file,
/// and keeps a bounded in-memory ring buffer served over XPC diagnostics.
enum DaemonLog {

    private static let oslog = Logger(subsystem: "com.batterycontrol.daemon", category: "control")
    private static let queue = DispatchQueue(label: "com.batterycontrol.daemon.log")
    private static var ring: [DiagnosticEntry] = []
    private static let ringLimit = 250

    /// /var/log/batterycontrol-daemon.log — readable by a normal user.
    private static var fileHandle: FileHandle?

    static func bootstrap() {
        queue.sync {
            let path = BatteryXPC.helperLogPath
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [
                    .posixPermissions: 0o644,
                ])
            }
            fileHandle = FileHandle(forUpdatingAtPath: path)
        }
    }

    static func info(_ message: String, operation: String, backend: String? = nil) {
        log(.info, message, operation: operation, backend: backend)
    }

    static func warning(_ message: String, operation: String, backend: String? = nil) {
        log(.warning, message, operation: operation, backend: backend)
    }

    static func error(_ message: String, operation: String, backend: String? = nil) {
        log(.error, message, operation: operation, backend: backend)
    }

    static func recentEntries() -> [DiagnosticEntry] {
        queue.sync { ring }
    }

    private static func log(_ severity: DiagnosticEntry.Severity, _ message: String, operation: String, backend: String?) {
        let entry = DiagnosticEntry(
            severity: severity,
            operation: operation,
            backendID: backend,
            message: message
        )
        switch severity {
        case .info: oslog.info("\(operation, privacy: .public): \(message, privacy: .public)")
        case .warning: oslog.warning("\(operation, privacy: .public): \(message, privacy: .public)")
        case .error: oslog.error("\(operation, privacy: .public): \(message, privacy: .public)")
        }

        queue.sync {
            ring.append(entry)
            if ring.count > ringLimit {
                ring.removeFirst(ring.count - ringLimit)
            }
            if let handle = fileHandle {
                let formatter = ISO8601DateFormatter()
                let line = "\(formatter.string(from: entry.timestamp)) [\(severity.rawValue.uppercased())] \(operation)\(backend.map { " (\($0))" } ?? ""): \(message)\n"
                handle.write(line.data(using: .utf8) ?? Data())
            }
        }
    }
}
