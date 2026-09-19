import Foundation

/// Backend identifier. Exposed as a plain String so new backends can be
/// swapped in without touching the UI.
public struct BackendID: Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static let pmAssertion = BackendID("pm-assertion")
    public static let firmwareLimit = BackendID("firmware-limit")
    public static let smcInhibit = BackendID("smc-inhibit")
    public static let smcCHWA = BackendID("smc-chwa")
    public static let bclmLegacy = BackendID("bclm-legacy")
    public static let fallback = BackendID("fallback")

    public var displayName: String {
        switch rawValue {
        case BackendID.pmAssertion.rawValue: return "Power assertions (ChargeInhibit / DisableInflow)"
        case BackendID.firmwareLimit.rawValue: return "Firmware-managed charge limit"
        case BackendID.smcInhibit.rawValue: return "SMC (charge inhibit)"
        case BackendID.smcCHWA.rawValue: return "SMC (CHWA limit)"
        case BackendID.bclmLegacy.rawValue: return "BCLM (legacy)"
        case BackendID.fallback.rawValue: return "Observation only"
        default: return rawValue
        }
    }

    /// Compact name for space-constrained status cells (dashboard tiles).
    /// The full `displayName` stays available for detail views.
    public var shortName: String {
        switch rawValue {
        case BackendID.pmAssertion.rawValue: return "Power assertions"
        case BackendID.firmwareLimit.rawValue: return "Firmware limit"
        case BackendID.smcInhibit.rawValue: return "SMC inhibit"
        case BackendID.smcCHWA.rawValue: return "SMC CHWA"
        case BackendID.bclmLegacy.rawValue: return "BCLM"
        case BackendID.fallback.rawValue: return "Observation"
        default: return rawValue
        }
    }
}

/// Selection logic: pick the best backend given what capability probing
/// found. Pure and unit-testable.
public enum BackendSelector {

    /// Candidate backends in preference order for a modern Apple Silicon Mac.
    /// The firmware-managed limit (bfF0/bfD0/bfE0, present on 20xxx-firmware
    /// Macs) is first: it is enforced by Apple's own firmware, keeps working
    /// during sleep and daemon downtime, and carries no key-collision risk
    /// with the removed legacy keys. The power-assertion and SMC-key backends
    /// remain as fallbacks for other firmware generations.
    public static let preferredOrder: [BackendID] = [
        .firmwareLimit,
        .pmAssertion,
        .smcInhibit,
        .smcCHWA,
        .bclmLegacy,
        .fallback,
    ]

    /// Select a backend from a capability set. Prefers the first backend in
    /// `preferredOrder` whose capabilities include verified charging control;
    /// otherwise falls back to the best available control backend that can
    /// at least ATTEMPT actions (the engine still verifies every action by
    /// observing the battery state and reports honestly), and finally to the
    /// observation-only backend.
    public static func select(capabilities: [BackendID: BatteryCapabilities]) -> BackendID {
        for candidate in preferredOrder {
            if let caps = capabilities[candidate],
               caps.supportsVerifiedChargingControl {
                return candidate
            }
        }
        // No verified mechanism. Still prefer a backend that can attempt
        // actions over pure observation: the engine verifies outcomes and
        // will report failure honestly rather than claim success.
        for candidate in preferredOrder {
            if let caps = capabilities[candidate],
               candidate != .fallback,
               caps.supportsUpperLimit || caps.supportsForceDischarge {
                return candidate
            }
        }
        return .fallback
    }
}

/// Decides whether an observed battery state confirms that a requested
/// charging action actually took effect. This is the heart of "never report
/// success just because a write was attempted".
///
/// The battery gauge on Apple Silicon refreshes roughly once a minute, so
/// verification is state-transition-based, not instantaneous.
public enum VerificationLogic {

    public enum Verdict: Equatable {
        case verified
        case pending
        case failed(reason: String)
    }

    /// Verify a normal policy action against fresh readings.
    public static func verify(
        action: ChargingAction,
        readings: BatteryReadings,
        policy: ChargingPolicy
    ) -> Verdict {
        switch action {
        case .normal:
            // Charging allowed again. If the pack is low enough, the system
            // should actually be charging.
            if readings.isExternalConnected, !readings.isCharging, readings.percentage < policy.upperLimit - 2 {
                return .failed(reason: "Charging was re-enabled but the battery is not charging (on AC, below limit).")
            }
            return .verified

        case .inhibitCharging:
            // At 100% macOS stops charging on its own; that is not proof our
            // inhibit works. Check it before the generic case.
            if readings.isExternalConnected, readings.percentage >= 100 {
                return .pending
            }
            // The observable proof of an inhibit is the charging flag going
            // false. With the charger attached the firmware limit reports it
            // directly; above the limit the firmware instead cuts adapter
            // input, which macOS reports as ExternalConnected = No even
            // though the charger is physically attached. Both are the
            // inhibit holding — not-charging is the requirement.
            if !readings.isCharging {
                return .verified
            }
            return .pending

        case .forceDischarge:
            // Proof of a real adapter cut: macOS reports external power as
            // disconnected even though the charger is physically attached,
            // and the pack loses charge.
            if !readings.isExternalConnected, !readings.isCharging {
                return .verified
            }
            if readings.amperageMA < 0 {
                return .verified
            }
            return .pending

        case .hold:
            return .verified
        }
    }

    /// Decide whether to retry after an unverified attempt.
    public static func shouldRetry(
        attemptNumber: Int,
        verdict: Verdict,
        now: Date,
        lastAttemptTime: Date?
    ) -> Bool {
        guard case .pending = verdict else { return false }
        return attemptNumber < maxAttempts
    }

    /// Total attempts before reporting failure. Bounded on purpose: no
    /// endless retry loops.
    ///
    /// The budget must cover real hardware latency, not just SMC latency:
    /// when the firmware pauses an ACTIVE charge it tapers current to zero
    /// over up to ~2 minutes before IsCharging drops (measured on the
    /// project's physically verified profile: a 60/50 cut at ~1900 mA took
    /// well over 60s to settle). 8 attempts × 20s = 160s of observation
    /// before an honest failure. Verification still succeeds on the first
    /// attempt whenever the transition is instant, so a larger budget costs
    /// nothing in the common case — it only prevents false alarms.
    public static let maxAttempts = 8
    /// Delay between attempts, in seconds. The gauge refreshes about once a
    /// minute, so short waits would only re-read stale state.
    public static let attemptDelaySeconds: TimeInterval = 20

    /// The verification window (attempts × delay) must be long enough to
    /// observe a real firmware taper. Pinned so tuning one constant cannot
    /// silently reintroduce the false "NOT verified" alarms this fixed.
    public static var minimumObservationWindowSeconds: TimeInterval { 120 }

    /// Is this battery level change meaningful progress for discharge
    /// verification?
    public static func dischargeIsProgressing(current: BatteryReadings, previous: BatteryReadings) -> Bool {
        current.percentage < previous.percentage
    }
}

/// Pure helper for the daemon's recovery heuristics.
public enum RecoveryDecisions {

    /// Should the engine reconfigure the firmware-limit backend this tick?
    ///
    /// Reconfiguration is a hardware operation (3 SMC reads; writes only if
    /// state differs). When the controlling context is unchanged AND the
    /// last configuration was hardware-verified, re-doing it every 20s tick
    /// adds no enforcement — the SMC itself holds the state, and a periodic
    /// re-confirm (every `reassertIntervalSeconds`) catches hardware drift.
    /// This decision is the gate: reconfigure on any context change or
    /// unverified state, otherwise only when the confirm interval elapsed.
    ///
    /// Safety equivalence: unverified, override/calibration transitions,
    /// and policy changes always reconfigure; nothing that would previously
    /// write is skipped — only redundant READ-confirmed maintenance is
    /// spaced out. `configure()` still read-verifies before every write.
    public static func shouldReconfigureFirmwareLimit(
        policy: ChargingPolicy,
        override: PolicyOverride,
        calibrationActive: Bool,
        lastContext: FirmwareMaintContext?,
        lastConfirmedAt: Date?,
        confirmed: Bool,
        now: Date,
        confirmInterval: TimeInterval,
        forceReconfigure: Bool = false
    ) -> Bool {
        // User/recovery events (explicit command, wake, boot recovery) always
        // reconfigure: the user (or a lifecycle event) is asking for the
        // hardware state to be (re)established and verified right now.
        if forceReconfigure { return true }
        // No valid memo (never configured, or invalidated after a failure):
        // hardware state cannot be attributed to the CURRENT policy, so it
        // must be reconfigured even if a confirm timestamp exists.
        guard let lastContext else { return true }
        let contextChanged = lastContext.policy != policy
            || lastContext.override != override
            || lastContext.calibrationActive != calibrationActive
        if contextChanged { return true }
        if !confirmed { return true }
        guard let lastConfirmedAt else { return true }
        return now.timeIntervalSince(lastConfirmedAt) >= confirmInterval
    }

    /// Should a policy re-apply be attempted after the given transition?
    public static func shouldReapplyAfterWake(
        readings: BatteryReadings,
        policy: ChargingPolicy,
        override: PolicyOverride
    ) -> Bool {
        guard policy.mode != .passthrough || override.isDischarge || override.isChargeOverride else {
            return false
        }
        return true
    }

    /// The daemon's fast tick interval in seconds (background enforcement).
    public static let tickIntervalSeconds: TimeInterval = 20
    /// How often the daemon re-asserts the policy even if nothing changed.
    public static let reassertIntervalSeconds: TimeInterval = 300

    /// Resolve the action to write after the engine resolved an override
    /// away at the boundary of a tick. A `.hold` decision must never be
    /// resolved as a previous override action: `.hold` means "keep whatever
    /// is applied", and applying a just-cancelled discharge would re-latch
    /// the adapter cut the engine had just released. Falling back to the
    /// policy's natural action is always safe.
    public static func resolvedHoldAction(
        lastHeld: ChargingAction?,
        policy: ChargingPolicy,
        connected: Bool
    ) -> ChargingAction {
        guard lastHeld == nil || lastHeld == .forceDischarge else { return .hold }
        switch policy.mode {
        case .passthrough:
            return .normal
        case .hysteresis:
            return .normal
        case .fixedTarget:
            return connected ? .normal : .hold
        }
    }
}
