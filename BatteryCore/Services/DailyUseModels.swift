import Foundation

/// User-facing health values derived only from telemetry that is present and
/// internally consistent. A missing value stays missing; zero is never used
/// as a substitute for unavailable hardware data.
public extension BatteryStatusSnapshot {
    /// Daemon timestamps change on every poll; UI/event deduplication should
    /// compare state content, not the observation clock.
    func meaningfullyEquals(_ other: BatteryStatusSnapshot) -> Bool {
        var lhs = self
        let rhs = other
        lhs.timestamp = rhs.timestamp
        return lhs == rhs
    }
}

public struct BatteryHealthSummary: Codable, Equatable, Sendable {
    public let chargePercent: Int
    public let chargingState: String
    public let cycleCount: Int?
    public let temperatureC: Double?
    public let designCapacitymAh: Int?
    public let fullChargeCapacitymAh: Int?
    public let capacityRatioPercent: Int?
    public let condition: BatteryCondition

    public init(readings: BatteryReadings) {
        chargePercent = min(max(readings.percentage, 0), 100)
        if readings.isCharging {
            chargingState = "Charging"
        } else if readings.isExternalConnected {
            chargingState = "Connected, not charging"
        } else {
            chargingState = "Discharging"
        }
        cycleCount = readings.cycleCount > 0 ? readings.cycleCount : nil
        temperatureC = readings.temperatureC.flatMap { $0.isFinite && $0 > -40 && $0 < 120 ? $0 : nil }
        designCapacitymAh = readings.designCapacitymAh > 0 ? readings.designCapacitymAh : nil
        fullChargeCapacitymAh = readings.maxCapacitymAh > 0 ? readings.maxCapacitymAh : nil
        capacityRatioPercent = readings.healthPercent.flatMap { $0 > 0 && $0 <= 150 ? $0 : nil }
        condition = readings.condition
    }
}

/// The named policies shown in the daily-use UI. These are only policy
/// values; applying one still uses the existing daemon/XPC path and runtime
/// hardware verification.
public enum ChargePreset: String, Codable, CaseIterable, Sendable {
    case daily
    case batterySaver
    case chronicallyPluggedIn
    case fullCharge
    case custom

    public var title: String {
        switch self {
        case .daily: return "Daily"
        case .batterySaver: return "Battery Saver"
        case .chronicallyPluggedIn: return "Chronically Plugged In"
        case .fullCharge: return "Full Charge"
        case .custom: return "Custom"
        }
    }

    public var explanation: String {
        switch self {
        case .daily: return "80% upper / 70% lower"
        case .batterySaver: return "70% upper / 60% lower"
        case .chronicallyPluggedIn: return "50% upper / 48% lower — less time at high voltage, which can slow battery wear"
        case .fullCharge: return "100% — use macOS default charging"
        case .custom: return "Choose your own upper and lower limits"
        }
    }

    public var policy: ChargingPolicy? {
        switch self {
        case .daily: return FixedChargeLimit.policy(upper: 80, resume: 70)
        case .batterySaver: return FixedChargeLimit.policy(upper: 70, resume: 60)
        case .chronicallyPluggedIn: return FixedChargeLimit.policy(upper: 50)
        case .fullCharge: return .passthrough()
        case .custom: return nil
        }
    }

    public static func matching(policy: ChargingPolicy) -> ChargePreset {
        if policy.mode == .passthrough { return .fullCharge }
        if policy == FixedChargeLimit.policy(upper: 80, resume: 70) { return .daily }
        if policy == FixedChargeLimit.policy(upper: 70, resume: 60) { return .batterySaver }
        if policy == FixedChargeLimit.policy(upper: 50) { return .chronicallyPluggedIn }
        return .custom
    }
}

/// A factual local event. It intentionally contains no user identity,
/// filenames, serial numbers, or raw log payloads.
public struct BatteryControlEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let kind: String
    public let detail: String

    public init(kind: String, detail: String, timestamp: Date = Date()) {
        self.timestamp = timestamp
        self.kind = kind
        self.detail = detail
    }

    /// Support exports contain only factual event text. Redact path-shaped
    /// values even if a future diagnostic detail accidentally includes one.
    public var sanitizedForExport: BatteryControlEvent {
        let sanitized = detail.replacingOccurrences(
            of: #"/Users/[^ ]+"#,
            with: "/Users/<redacted>",
            options: .regularExpression
        )
        return BatteryControlEvent(kind: kind, detail: sanitized, timestamp: timestamp)
    }
}

/// Bounded local history store. Callers may persist the encoded payload in
/// Application Support; the core type itself has no filesystem side effects.
public final class LocalEventHistory: @unchecked Sendable {
    public let maximumCount: Int
    private let lock = NSLock()
    private var events: [BatteryControlEvent]

    public init(maximumCount: Int = 500, events: [BatteryControlEvent] = []) {
        self.maximumCount = max(1, maximumCount)
        self.events = Array(events.suffix(max(1, maximumCount)))
    }

    public func append(_ event: BatteryControlEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
        if events.count > maximumCount { events.removeFirst(events.count - maximumCount) }
    }

    public func snapshot() -> [BatteryControlEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        events.removeAll(keepingCapacity: true)
    }

    public func encodedData() throws -> Data {
        try JSONEncoder.batteryControl.encode(snapshot())
    }

    public static func decode(_ data: Data, maximumCount: Int = 500) -> LocalEventHistory {
        guard let decoded = try? JSONDecoder.batteryControl.decode([BatteryControlEvent].self, from: data) else {
            return LocalEventHistory(maximumCount: maximumCount)
        }
        return LocalEventHistory(maximumCount: maximumCount, events: decoded)
    }
}

private extension JSONEncoder {
    static var batteryControl: JSONEncoder { JSONEncoder() }
}
private extension JSONDecoder {
    static var batteryControl: JSONDecoder { JSONDecoder() }
}

/// Sanitized, local-only support bundle content. This is deliberately a
/// Codable manifest rather than an archive writer so the UI can show exactly
/// what will be exported before writing a file.
public struct SupportBundleManifest: Codable, Equatable, Sendable {
    public let appVersion: String
    public let compatibilityReport: CompatibilityReport?
    /// The last daemon-confirmed status, including policy, override, and
    /// verification state. This is a DTO snapshot, not a second authority.
    public let statusSnapshot: BatteryStatusSnapshot?
    public let events: [BatteryControlEvent]

    public init(
        appVersion: String,
        compatibilityReport: CompatibilityReport?,
        statusSnapshot: BatteryStatusSnapshot? = nil,
        events: [BatteryControlEvent]
    ) {
        self.appVersion = appVersion
        self.compatibilityReport = compatibilityReport
        self.statusSnapshot = statusSnapshot
        self.events = events.map(\.sanitizedForExport)
    }

    public func jsonData() throws -> Data {
        try JSONEncoder.batteryControl.encode(self)
    }
}
