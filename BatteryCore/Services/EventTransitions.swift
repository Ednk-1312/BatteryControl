import Foundation

/// Converts two authoritative daemon snapshots into factual transition
/// events. Equal snapshots produce no events, so a 20-second poll cannot
/// create duplicate history entries.
public enum EventTransitions {
    public static func events(from old: BatteryStatusSnapshot?, to new: BatteryStatusSnapshot) -> [BatteryControlEvent] {
        guard let old else { return [] }
        var result: [BatteryControlEvent] = []
        if old.activePolicy != new.activePolicy {
            let kind = new.activePolicy.mode == .passthrough ? "charge-limit disabled" : "charge-limit changed"
            result.append(BatteryControlEvent(kind: kind, detail: new.activePolicy.summary, timestamp: new.timestamp))
        }
        if old.activeOverride != new.activeOverride {
            switch new.activeOverride {
            case .none:
                if old.isForceCharging { result.append(BatteryControlEvent(kind: "temporary override ended", detail: "charge target reached or cancelled", timestamp: new.timestamp)) }
                if old.isForceDischarging { result.append(BatteryControlEvent(kind: "controlled discharge ended", detail: "normal charging policy restored", timestamp: new.timestamp)) }
            case .forceCharge(let target):
                result.append(BatteryControlEvent(kind: "temporary override started", detail: "charging to \(target)%", timestamp: new.timestamp))
            case .forceDischarge(let target, let floor, _):
                result.append(BatteryControlEvent(kind: "controlled discharge started", detail: "target \(target)%, floor \(floor)%", timestamp: new.timestamp))
            }
        }
        if old.readings.isAdapterAttached != new.readings.isAdapterAttached {
            result.append(BatteryControlEvent(
                kind: new.readings.isAdapterAttached ? "charger connected" : "charger disconnected",
                detail: "Battery telemetry changed",
                timestamp: new.timestamp
            ))
        }
        if !old.controlIsVerified && new.controlIsVerified {
            result.append(BatteryControlEvent(kind: "hardware verification succeeded", detail: new.activeBackendID, timestamp: new.timestamp))
        } else if old.controlIsVerified && !new.controlIsVerified {
            result.append(BatteryControlEvent(kind: "hardware verification failed", detail: new.activeBackendID, timestamp: new.timestamp))
        }
        if old.activeBackendID != new.activeBackendID {
            result.append(BatteryControlEvent(kind: "hardware capability changed", detail: new.activeBackendID, timestamp: new.timestamp))
        }
        return result
    }
}
