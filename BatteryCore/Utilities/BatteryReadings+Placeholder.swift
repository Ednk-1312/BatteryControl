import Foundation

extension BatteryReadings {
    /// A neutral reading for empty UI states and tests.
    public static let placeholder = BatteryReadings(
        percentage: 0,
        isCharging: false,
        isExternalConnected: false,
        condition: .unknown,
        cycleCount: 0,
        currentCapacitymAh: 0,
        maxCapacitymAh: 0,
        designCapacitymAh: 0,
        voltagemV: 0,
        amperageMA: 0,
        temperatureC: nil
    )
}
