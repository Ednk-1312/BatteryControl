import Foundation
import os

/// Unified logging for the app process.
enum DaemonAppLog {
    static let ui = Logger(subsystem: "com.batterycontrol.app", category: "ui")
    static let ipc = Logger(subsystem: "com.batterycontrol.app", category: "ipc")
    static let installer = Logger(subsystem: "com.batterycontrol.app", category: "installer")
}
