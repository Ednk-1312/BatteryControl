import Foundation

/// Guided battery-gauge calibration stages.
///
/// The cycle (in order):
/// 1. `prepare` — confirm the charger is connected
/// 2. `dischargeToLow` — controlled discharge down to 20%
/// 3. `chargeToFull` — uninterrupted charge to 100%
/// 4. `holdAtFull` — sit at 100% for 3 hours so the gauge records a true
///    full-charge reference
/// 5. `dischargeToLimit` — controlled drop from 100% down to the charge
///    limit (80% by default)
/// 6. `finish` — the normal policy resumes: the battery rests at the limit
///    while the Mac runs off wall power
///
/// Calibration re-trains the gauge's full-charge-capacity estimate; it does
/// NOT repair physical battery health.
public enum CalibrationStage: String, Codable, Sendable, CaseIterable {
    case idle
    case prepare
    case dischargeToLow
    case chargeToFull
    case holdAtFull
    case dischargeToLimit
    case finish

    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .prepare: return "Prepare"
        case .dischargeToLow: return "Discharge to 20%"
        case .chargeToFull: return "Charge to 100%"
        case .holdAtFull: return "Hold at 100% (3 hours)"
        case .dischargeToLimit: return "Drop to charge limit"
        case .finish: return "Finished"
        }
    }

    public var detailText: String {
        switch self {
        case .idle:
            return "Calibration has not been started."
        case .prepare:
            return "Plug in the charger. The cycle will first discharge the battery to 20%, charge back to 100%, hold there for 3 hours, then drop to your charge limit."
        case .dischargeToLow:
            return "Adapter input is cut so the Mac runs on battery down to 20%. Use the Mac normally but avoid demanding tasks. Do not plug in until prompted."
        case .chargeToFull:
            return "Charging from 20% to 100% without interruption so the gauge can record a true full charge. Keep the Mac plugged in."
        case .holdAtFull:
            return "Sitting at 100% for 3 hours. This gives the gauge time to settle on a true full-charge reference. Keep the Mac plugged in."
        case .dischargeToLimit:
            return "Controlled drop from 100% down to your charge limit. The Mac runs off the battery with adapter input cut until it reaches the limit."
        case .finish:
            return "Calibration complete. Your normal charging policy is active again: the battery rests at the limit while the Mac runs off wall power. Note: calibration refreshes the battery gauge's capacity estimate — it does not repair physical battery health."
        }
    }

    /// Stages shown as progress steps in the UI (idle excluded).
    public static let progressOrder: [CalibrationStage] = [
        .prepare,
        .dischargeToLow,
        .chargeToFull,
        .holdAtFull,
        .dischargeToLimit,
        .finish,
    ]
}

/// Serializable calibration session state (owned by the helper so it survives
/// the app closing).
public struct CalibrationSession: Codable, Equatable, Sendable {
    public var stage: CalibrationStage
    /// Low point of the cycle (20%).
    public var lowPercent: Int
    /// The charge limit the cycle ends at (the user's upper limit, e.g. 80%).
    public var limitPercent: Int
    public var startedAt: Date?
    public var stageEnteredAt: Date?
    /// Set when a safety condition forced the calibration to stop.
    public var abortReason: String?

    public init(
        stage: CalibrationStage = .idle,
        lowPercent: Int = CalibrationDecisions.Limits.calibrationLowPercent,
        limitPercent: Int = 80
    ) {
        self.stage = stage
        self.lowPercent = lowPercent
        self.limitPercent = limitPercent
        self.startedAt = nil
        self.stageEnteredAt = nil
        self.abortReason = nil
    }

    public var isActive: Bool {
        switch stage {
        case .idle, .finish: return false
        default: return true
        }
    }

    /// Advance to the next stage, stamping the transition time.
    public mutating func advance(to newStage: CalibrationStage, at date: Date = Date()) {
        stage = newStage
        stageEnteredAt = date
        if startedAt == nil {
            startedAt = date
        }
    }

    public mutating func abort(_ reason: String, at date: Date = Date()) {
        abortReason = reason
        stageEnteredAt = date
    }
}

/// Pure decision logic for the calibration state machine. Driven by current
/// readings so it is fully unit-testable.
public enum CalibrationDecisions {

    /// Safety and timing thresholds.
    public enum Limits {
        /// The cycle's low point: the battery discharges down to this level.
        public static let calibrationLowPercent = 20
        /// The cycle never rides below this, even if the gauge sticks just
        /// above the low point. Crossing it aborts the session.
        public static let hardFloorPercent = 15
        /// How long to sit at 100% before dropping to the limit.
        public static let holdMinutesAtFull = 180
        /// A discharge stage making no progress for this long aborts the
        /// session (stuck gauge or a control path that stopped working).
        public static let maxDischargeStageMinutes = 720
    }

    /// Decide the next calibration transition from the current state.
    /// Returns the stage to move to, or nil to stay.
    public static func nextStage(
        current: CalibrationStage,
        readings: BatteryReadings,
        session: CalibrationSession,
        now: Date = Date()
    ) -> CalibrationStage? {
        switch current {
        case .idle:
            return readings.isExternalConnected ? .prepare : nil

        case .prepare:
            return .dischargeToLow

        case .dischargeToLow:
            if readings.percentage <= session.lowPercent {
                return .chargeToFull
            }
            return nil

        case .chargeToFull:
            if readings.percentage >= 100 {
                return .holdAtFull
            }
            return nil

        case .holdAtFull:
            if let entered = session.stageEnteredAt,
               now.timeIntervalSince(entered) >= TimeInterval(Limits.holdMinutesAtFull * 60) {
                return .dischargeToLimit
            }
            return nil

        case .dischargeToLimit:
            if readings.percentage <= session.limitPercent {
                return .finish
            }
            return nil

        case .finish:
            return nil
        }
    }

    /// Whether a calibration session ended between the previous and current
    /// tick (cancel, safety abort, or natural finish). The engine uses this
    /// falling edge to give back everything the session took: the user's
    /// firmware limit is re-programmed, and any adapter cut the discharge
    /// stages latched is released — without it, macOS keeps reporting the
    /// physically attached charger as absent after a mid-discharge cancel.
    public static func sessionJustEnded(
        previousActive: Bool,
        currentActive: Bool
    ) -> Bool {
        previousActive && !currentActive
    }

    /// Which charging action the calibration stage requires right now.
    /// Both discharge stages cut adapter input while on AC; charging stages
    /// restore normal charging.
    public static func requiredAction(
        stage: CalibrationStage,
        readings: BatteryReadings
    ) -> ChargingAction {
        switch stage {
        case .dischargeToLow, .dischargeToLimit:
            return readings.isExternalConnected ? .forceDischarge : .normal
        case .prepare, .chargeToFull, .holdAtFull, .idle, .finish:
            return .normal
        }
    }

    /// Safety gate evaluated every tick. Returns an abort reason when the
    /// session must stop, nil when it is safe to continue.
    public static func safetyAbortReason(
        readings: BatteryReadings,
        session: CalibrationSession,
        now: Date = Date()
    ) -> String? {
        // Stop any active session when battery health reporting flags a fault.
        if readings.condition == .serviceRecommended {
            return "Battery reports 'Service Recommended'. Calibration paused — have the battery checked first."
        }

        switch session.stage {
        case .dischargeToLow:
            // Never ride below the hard floor even if the gauge sticks just
            // above the low point.
            if readings.percentage < Limits.hardFloorPercent {
                return "Battery fell below the safe floor (\(Limits.hardFloorPercent)%). Discharge stopped to protect the battery."
            }
            // Stuck-gauge guard: no reaching 20% in 12 hours means the
            // discharge path is not working; abort instead of waiting.
            if let entered = session.stageEnteredAt,
               now.timeIntervalSince(entered) > TimeInterval(Limits.maxDischargeStageMinutes * 60),
               readings.percentage > session.lowPercent {
                return "Discharge to 20% made no progress for 12 hours. Calibration stopped — check Diagnostics."
            }
            return nil

        case .dischargeToLimit:
            if let entered = session.stageEnteredAt,
               now.timeIntervalSince(entered) > TimeInterval(Limits.maxDischargeStageMinutes * 60),
               readings.percentage > session.limitPercent {
                return "Discharge to the limit made no progress for 12 hours. Calibration stopped — check Diagnostics."
            }
            return nil

        default:
            return nil
        }
    }
}
