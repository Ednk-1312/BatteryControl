import Foundation

/// Pure decision engine mapping (readings, policy, override) → ChargingAction.
/// Stateless and unit-testable; the helper evaluates it every control tick.
public enum ChargingPolicyEngine {

    /// Minimum safe discharge floor unless hardware explicitly supports a
    /// safer mechanism. Forced discharge never goes below this WITHOUT the
    /// user's explicit below-floor consent.
    public static let minimumDischargeFloor = 20

    /// Absolute floor for a consented below-floor discharge. The Mac's own
    /// hardware shutdown occurs before a displayed 0%, so 1% is the lowest
    /// meaningful stop point BatteryControl will program.
    public static let absoluteDischargeFloor = 1

    /// Clamp a user-requested discharge target/floor into the safe range.
    /// Values below `minimumDischargeFloor` are preserved here (clamped to
    /// `absoluteDischargeFloor`); whether such a floor is *allowed* is a
    /// consent decision enforced at the request boundary (UI + XPC handler),
    /// not silently re-clamped here.
    public static func sanitizedDischargeFloor(_ requested: Int) -> Int {
        min(max(requested, absoluteDischargeFloor), 100)
    }

    /// Resolve the effective floor for a force-discharge session: at or above
    /// the safety floor unless an explicit below-floor consent produced a
    /// lower (already-validated) value.
    public static func effectiveDischargeFloor(requested: Int) -> Int {
        max(absoluteDischargeFloor, sanitizedDischargeFloor(requested))
    }

    /// Whether a resolved floor represents a below-safety-floor session that
    /// may only exist with the user's explicit degradation consent.
    public static func requiresBelowFloorConsent(floor: Int) -> Bool {
        floor < minimumDischargeFloor
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
    ///
    /// A force-discharge floor below the safety floor is only honored when
    /// `belowFloorConsent` is true — the daemon re-checks this every tick so
    /// a hand-edited policy file cannot bypass the consent requirement.
    public static func decide(
        readings: BatteryReadings,
        policy: ChargingPolicy,
        override: PolicyOverride,
        belowFloorConsent: Bool = false
    ) -> ChargingAction {
        // Hard safety: if anything is nonsense, fail toward the least
        // destructive action (normal charging) rather than draining or
        // inhibiting.
        if ControlModeHelpers.validate(policy) != nil {
            return .normal
        }

        switch override {
        case .forceDischarge(let target, let requestedFloor, _):
            let floor = effectiveDischargeFloor(requested: requestedFloor)
            // A below-safety-floor floor without recorded consent is an
            // integrity failure: clamp the session back to the safety floor
            // rather than aborting it entirely (which would silently cancel
            // a legitimate session across a restart).
            if requiresBelowFloorConsent(floor: floor), !belowFloorConsent {
                return continueOrStop(
                    readings: readings,
                    target: max(target, minimumDischargeFloor)
                )
            }
            // Discharge stops at the user's target — unless that target itself
            // sits below the safety floor, in which case the floor wins.
            let stopPoint = max(target, floor)
            // Safety conditions that must stop forced discharge immediately:
            // reached the stop point, or the user pulled the plug (on battery
            // power there is nothing to discharge against).
            return continueOrStop(readings: readings, target: stopPoint)

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

    /// Force-discharge termination conditions shared by the consented and
    /// consent-clamped paths.
    private static func continueOrStop(readings: BatteryReadings, target: Int) -> ChargingAction {
        if readings.percentage <= target {
            return .normal
        }
        if !readings.isExternalConnected {
            return .normal
        }
        return .forceDischarge
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
