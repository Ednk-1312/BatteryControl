import Foundation

/// Raw readings from the system battery (IOKit AppleSmartBattery in the
/// helper; mirrored into DTOs for the UI).
public struct BatteryReadings: Codable, Equatable, Sendable {
    /// State of charge in percent 0...100.
    public var percentage: Int
    public var isCharging: Bool
    public var isExternalConnected: Bool
    /// Whether the AC adapter is PHYSICALLY attached (AdapterDetails present
    /// in the AppleSmartBattery registry), regardless of whether input is
    /// currently allowed to flow. During a forced discharge the adapter
    /// input is cut, so `isExternalConnected` reads false while the charger
    /// remains plugged in — abort logic must use this flag to tell "user
    /// pulled the plug" apart from "we cut the input ourselves".
    /// Defaults to `isExternalConnected` for callers that don't supply it.
    public var isAdapterAttached: Bool
    /// macOS' own battery-health verdict, when available.
    public var condition: BatteryCondition
    public var cycleCount: Int
    /// milliamp-hours.
    public var currentCapacitymAh: Int
    public var maxCapacitymAh: Int
    public var designCapacitymAh: Int
    /// millivolts.
    public var voltagemV: Int
    /// milliamps; negative while discharging.
    public var amperageMA: Int
    /// Battery temperature in degrees Celsius, when the hardware provides it.
    public var temperatureC: Double?
    /// When the helper assembled this reading.
    public var timestamp: Date

    public init(
        percentage: Int,
        isCharging: Bool,
        isExternalConnected: Bool,
        isAdapterAttached: Bool? = nil,
        condition: BatteryCondition,
        cycleCount: Int,
        currentCapacitymAh: Int,
        maxCapacitymAh: Int,
        designCapacitymAh: Int,
        voltagemV: Int,
        amperageMA: Int,
        temperatureC: Double?,
        timestamp: Date = Date()
    ) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isExternalConnected = isExternalConnected
        self.isAdapterAttached = isAdapterAttached ?? isExternalConnected
        self.condition = condition
        self.cycleCount = cycleCount
        self.currentCapacitymAh = currentCapacitymAh
        self.maxCapacitymAh = maxCapacitymAh
        self.designCapacitymAh = designCapacitymAh
        self.voltagemV = voltagemV
        self.amperageMA = amperageMA
        self.temperatureC = temperatureC
        self.timestamp = timestamp
    }

    /// Health percentage = current full-charge capacity over design capacity.
    public var healthPercent: Int? {
        guard designCapacitymAh > 0, maxCapacitymAh > 0 else { return nil }
        return Int((Double(maxCapacitymAh) / Double(designCapacitymAh) * 100).rounded())
    }
}

public enum BatteryCondition: String, Codable, Sendable {
    case normal
    case serviceRecommended
    case `unknown`

    public var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .serviceRecommended: return "Service Recommended"
        case .unknown: return "Unknown"
        }
    }
}

/// A snapshot of everything the UI dashboard needs, as verified by the
/// control layer. `controlIsVerified` is only true when the last requested
/// control operation was confirmed by an actual state change — never merely
/// because a write was issued.
public struct BatteryStatusSnapshot: Codable, Equatable, Sendable {
    public var readings: BatteryReadings
    public var activePolicy: ChargingPolicy
    /// Transient override currently in force (force discharge/charge).
    public var activeOverride: PolicyOverride
    /// Active calibration session, if any.
    public var activeCalibration: CalibrationSession?
    public var controlIsVerified: Bool
    public var activeBackendID: String
    public var capabilities: BatteryCapabilities
    public var helperStatus: HelperStatus
    /// Confidence tier from the firmware compatibility library, when the
    /// daemon classified the machine (nil on older daemons).
    public var firmwareProfileTier: FirmwareProfileTier?
    public var timestamp: Date

    public init(
        readings: BatteryReadings,
        activePolicy: ChargingPolicy,
        activeOverride: PolicyOverride = .none,
        activeCalibration: CalibrationSession? = nil,
        controlIsVerified: Bool,
        activeBackendID: String,
        capabilities: BatteryCapabilities,
        helperStatus: HelperStatus,
        firmwareProfileTier: FirmwareProfileTier? = nil,
        timestamp: Date = Date()
    ) {
        self.readings = readings
        self.activePolicy = activePolicy
        self.activeOverride = activeOverride
        self.activeCalibration = activeCalibration
        self.controlIsVerified = controlIsVerified
        self.activeBackendID = activeBackendID
        self.capabilities = capabilities
        self.helperStatus = helperStatus
        self.firmwareProfileTier = firmwareProfileTier
        self.timestamp = timestamp
    }

    /// True while a force-discharge session is active.
    public var isForceDischarging: Bool {
        if case .forceDischarge = activeOverride { return true }
        return false
    }

    /// True while a force-charge override is active.
    public var isForceCharging: Bool {
        if case .forceCharge = activeOverride { return true }
        return false
    }
}
