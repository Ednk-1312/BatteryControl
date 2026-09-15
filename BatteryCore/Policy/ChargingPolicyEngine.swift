import Foundation

/// Pure decision engine mapping (readings, policy, override) → ChargingAction.
/// Stateless and unit-testable; the helper evaluates it every control tick.
public enum ChargingPolicyEngine {

    /// Minimum safe discharge floor unless hardware explicitly supports a
    /// safer mechanism. Forced discharge never goes below this.
    public static let minimumDischargeFloor = 20

    /// Clamp a user-requested discharge target/floor into the safe range.
    public static func sanitizedDischargeFloor(_ requested: Int) -> Int {
        max(min(max(requested, 5), 100), minimumDischargeFloor)
    }

    /// Resolve the effective floor for a force-discharge session: never below
    /// the safety floor.
    public static func effectiveDischargeFloor(requested: Int) -> Int {
        max(minimumDischargeFloor, sanitizedDischargeFloor(requested))
    }

    /// Clamp any user-entered percentage into 1...100.
    public static func clampPercent(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }

    /// Decide the action for a normal (non-calibration) control tick.
    ///
    /// Order of precedence:
    /// 1. Fail toward normal charging if the policy itself is invalid.
    /// 2. Force-discharge session (stop at target/floor, abort on safety).
    /// 3. Force-charge override (charge regardless of the upper limit).
    /// 4. Base policy (hysteresis / fixed target / passthrough).
    public static func decide(
        readings: BatteryReadings,
        policy: ChargingPolicy,
        override: PolicyOverride
    ) -> ChargingAction {
        // Hard safety: if anything is nonsense, fail toward the least
        // destructive action (normal charging) rather than draining or
        // inhibiting.
        if ControlModeHelpers.validate(policy) != nil {
            return .normal
        }

        switch override {
        case .forceDischarge(let target, let requestedFloor):
            let floor = effectiveDischargeFloor(requested: requestedFloor)
            // Discharge stops at the user's target — unless that target itself
            // sits below the safety floor, in which case the floor wins.
            let stopPoint = max(target, floor)
            // Safety conditions that must stop forced discharge immediately:
            // reached the stop point, or the user pulled the plug (on battery
            // power there is nothing to discharge against).
            if readings.percentage <= stopPoint {
                return .normal
            }
            if !readings.isExternalConnected {
                return .normal
            }
            return .forceDischarge

        case .forceCharge(let target):
            if readings.percentage >= target {
                return .normal
            }
            return .normal

        case .none:
            switch policy.mode {
            case .passthrough:
                return .normal
            case .hysteresis:
                if readings.percentage >= policy.upperLimit {
                    return .inhibitCharging
                }
                if readings.percentage <= policy.lowerLimit {
                    return .normal
                }
                // Inside the band: let charging run so the battery sits AT
                // the limit, not coasting in the middle of the band. The
                // backend (firmware band or charge inhibit) stops the charge
                // at the upper limit; below the limit it charges. Neither
                // state flaps: at-or-above the limit holds a stable inhibit,
                // below it holds a stable charge-toward-limit.
                return .normal
            case .fixedTarget:
                let lower = max(1, policy.upperLimit - ChargingPolicy.fixedTargetBand)
                if readings.percentage >= policy.upperLimit {
                    return .inhibitCharging
                }
                if readings.isExternalConnected && readings.percentage <= lower {
                    return .normal
                }
                return .hold
            }
        }
    }

    /// Decide the action while a calibration session is active. Calibration
    /// actions always take precedence over the user policy.
    public static func decideForCalibration(
        readings: BatteryReadings,
        session: CalibrationSession
    ) -> ChargingAction {
        guard session.isActive else { return .normal }
        if CalibrationDecisions.safetyAbortReason(readings: readings, session: session) != nil {
            return .normal
        }
        return CalibrationDecisions.requiredAction(stage: session.stage, readings: readings)
    }
}
