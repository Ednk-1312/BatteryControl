import BatteryCore
import Foundation

/// The daemon's control engine. Runs a periodic enforcement loop that
/// decides the desired action (calibration → override → policy precedence),
/// applies it through the active backend, and verifies the result by
/// observing the battery state — retrying a bounded number of times before
/// reporting an unverified state honestly.
final class ControlEngine {

    // MARK: State

    private let store: PolicyStore
    private var backends: [BackendID: ChargingBackend] = [:]
    private(set) var activeBackend: ChargingBackend
    private(set) var capabilities: BatteryCapabilities = .unsupported
    private(set) var lastReadings: BatteryReadings = .placeholder
    private(set) var lastAttempt: ControlAttemptResult?
    private(set) var lastError: DiagnosticEntry?
    private(set) var controlIsVerified = false
    private(set) var desiredAction: ChargingAction = .normal
    private(set) var isPlatformSupported = true

    /// The last calibration state seen by the tick loop; a falling edge
    /// (active → ended) triggers a restore of the user's firmware limit.
    private var calibrationWasActive = false

    /// Memo for steady-state firmware-limit maintenance: the policy context
    /// of the last successful hardware-verified configure() and when it was
    /// confirmed. Lets unchanged ticks skip redundant SMC read-triples while
    /// a periodic re-confirm (reassertIntervalSeconds) keeps proving drift
    /// hasn't occurred. Invalidated on any failure or context change.
    private var lastFirmwareContext: FirmwareMaintContext?
    private var lastFirmwareConfirmAt: Date?

    /// Firmware compatibility tier for this exact machine/firmware build,
    /// classified from the runtime-detected SMC family + profile library.
    private(set) var firmwareProfileTier: FirmwareProfileTier = .untested
    private(set) var firmwareProfileSummary: String = ""
    /// Runtime-detected SMC control family (recorded at hardware init so
    /// report generation never needs to re-probe the SMC).
    private(set) var detectedSMCFamily: FirmwareProfileLibrary.DetectedFamily = .none

    /// Live state of Apple's built-in Charge Limit (macOS 26.4+), observed
    /// from the IOKit battery registry each tick. Feeds the ownership
    /// model: there is one authoritative controller at a time, and when
    /// no BatteryControl policy is set, the UI/CLI can say who IS limiting
    /// charging. Read-only observation — BatteryControl never writes
    /// Apple's setting.
    private(set) var nativeChargeLimit = NativeChargeLimitState.unknown
    private(set) var platformIdentity: PlatformIdentity?

    // Bookkeeping for bounded retries.
    private var attemptNumber = 0
    /// The last discharge session seen by the tick loop; a falling edge
    /// (active → ended) releases any manual adapter cut we still hold so
    /// the charger re-engages immediately instead of waiting for the next
    /// `.normal` decision.
    private var dischargeWasActive = false
    private var lastReassert = Date()
    private var startInstant = Date()

    let engineQueue = DispatchQueue(label: "com.batterycontrol.daemon.engine")

    /// Guards ALL mutable engine state. The serial `engineQueue` alone is
    /// not enough: XPC handler threads call the command methods (and read
    /// snapshot state) directly on their own queues, and the retry timer
    /// re-enters verification from `asyncAfter`. Everything that touches
    /// engine fields runs under this lock; it is recursive because the
    /// call graph nests (tick → apply → verify) on one thread. Lock order
    /// is always engineLock → (store | log | SMC) — never the reverse —
    /// so no cycle is possible.
    private let engineLock = NSRecursiveLock()

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        engineLock.lock()
        defer { engineLock.unlock() }
        return try body()
    }

    var daemonVersion: String { BatteryXPC.expectedHelperVersion }
    var uptime: TimeInterval { Date().timeIntervalSince(startInstant) }

    /// The last non-hold action we applied; `.hold` keeps this in effect.
    private var lastHeldAction: ChargingAction?

    // MARK: Init

    /// The real initializer. Deliberately CHEAP: no hardware probing, no
    /// SMC access. The SMC user-client is a synchronous, unbounded kernel
    /// interface — if it wedges (observed after SIGKILL of a live daemon:
    /// subsequent SMC opens hang in the kernel), an init that probes SMC
    /// here would hang the daemon BEFORE the XPC listener starts, leaving
    /// no way for clients to even see an honest status. Hardware init runs
    /// later via `beginHardwareInit()` on the engine queue.
    init(store: PolicyStore, skipHardwareInit: Bool = false) {
        self.store = store

        // Cheap safe-by-default state: observation-only backend, nothing
        // verified, honest "probing" summary. If hardware init never runs
        // (or wedges and the watchdog restarts us), clients see exactly
        // that instead of stale or fabricated control state.
        activeBackend = ObservationOnlyBackend()
        firmwareProfileSummary = "Probing hardware…"

        guard !skipHardwareInit else {
            firmwareProfileTier = .unsupported
            firmwareProfileSummary = "Hardware probing skipped."
            return
        }
    }

    /// Two-phase init, phase 2: hardware probing. Runs on the engine queue
    /// AFTER the XPC listener is already accepting connections, so a wedged
    /// SMC degrades to an honest "probing hardware" state instead of a
    /// silent, unreachable daemon. A watchdog forces process exit if the
    /// probe blocks past the deadline — launchd respawns a fresh daemon.
    func beginHardwareInit() {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.locked {
                self.hardwareInitUnlocked()
            }
        }
        // Watchdog: a hung probe never recovers on its own (the kernel call
        // has no timeout), so the only self-healing path is exit-and-be-
        // respawned. launchd KeepAlive restarts the daemon. The watchdog
        // must NOT run on the engine queue (a hung probe blocks that queue
        // forever) and must not take engineLock (the hung probe holds it):
        // it lives on a global queue and reads a dedicated flag.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.hardwareInitDeadline) { [weak self] in
            guard let self else { return }
            if !self.hardwareInitComplete {
                DaemonLog.error(
                    "Hardware init did not complete within \(Int(Self.hardwareInitDeadline))s; exiting so launchd can restart the daemon.",
                    operation: "startup"
                )
                exit(3)
            }
        }
    }

    /// Deadline for the hardware-init phase. Generous: normal probing is
    /// sub-second, but after an SMC wedge the first respawn may hang again;
    /// each watchdog exit forces a fresh process (fresh mach ports) until
    /// the kernel path recovers.
    static let hardwareInitDeadline: TimeInterval = 45

    /// Init-completion flag with its own lock (read by the watchdog, which
    /// cannot take engineLock — the hung probe holds it). Lock order is
    /// always engineLock → watchdogLock, never the reverse.
    private let watchdogLock = NSLock()
    private var _hardwareInitComplete = false
    private var hardwareInitComplete: Bool {
        get { watchdogLock.lock(); defer { watchdogLock.unlock() }; return _hardwareInitComplete }
        set { watchdogLock.lock(); _hardwareInitComplete = newValue; watchdogLock.unlock() }
    }

    /// Must run under `engineLock` on the engine queue.
    private func hardwareInitUnlocked() {
        guard !hardwareInitComplete else { return }

        let all: [ChargingBackend] = [
            FirmwareLimitBackend(), PMAssertionBackend(), SMCInhibitBackend(), CHWABackend(), ObservationOnlyBackend(),
        ]
        var map: [BackendID: ChargingBackend] = [:]
        var capabilityMap: [BackendID: BatteryCapabilities] = [:]
        for backend in all {
            let caps = backend.probe()
            map[backend.id] = backend
            capabilityMap[backend.id] = caps
            DaemonLog.info(
                "Backend \(backend.id.rawValue) probe: verifiedControl=\(caps.supportsVerifiedChargingControl)",
                operation: "probe",
                backend: backend.id.rawValue
            )
        }
        backends = map

        let selected = BackendSelector.select(capabilities: capabilityMap)
        activeBackend = map[selected] ?? ObservationOnlyBackend()
        capabilities = activeBackend.capabilities

        DaemonLog.info(
            "Selected backend \(selected.rawValue)",
            operation: "startup",
            backend: selected.rawValue
        )

        // Firmware compatibility classification. Runtime key detection is
        // the source of truth for capability; the profile library adds the
        // evidence tier for this exact firmware build. An untested signature
        // is reported honestly — capability probing still gates every write.
        let identity = PlatformDetector.detect()
        let detectedFamily: FirmwareProfileLibrary.DetectedFamily
        switch SMCChargeControl.detectFamily() {
        case .firmwareLimit: detectedFamily = .firmwareLimit
        case .legacy: detectedFamily = .legacy
        case .legacyTahoe: detectedFamily = .legacyTahoe
        case .none: detectedFamily = .none
        }
        detectedSMCFamily = detectedFamily
        firmwareProfileTier = FirmwareProfileLibrary.classify(
            identity: identity,
            detectedFamily: detectedFamily,
            systemFirmwareBuild: identity.systemFirmwareBuild
        )
        firmwareProfileSummary = FirmwareProfileLibrary.summary(
            for: firmwareProfileTier,
            identity: identity,
            detectedFamily: detectedFamily
        )
        DaemonLog.info(
            "Firmware profile [\(firmwareProfileTier.rawValue)]: \(firmwareProfileSummary)",
            operation: "startup"
        )

        // SAFE-BY-DEFAULT GATE: unknown firmware combinations never receive
        // unverified SMC writes. If the compatibility tier is untested or
        // unsupported, force the observation-only backend regardless of what
        // capability probing found — the machine stays in read-only
        // diagnostics mode until the profile library grows evidence.
        if !FirmwareProfileLibrary.shouldAllowControlWrites(firmwareProfileTier) {
            if let observation = map[BackendID.fallback] {
                activeBackend = observation
                capabilities = observation.capabilities
                DaemonLog.warning(
                    "Control writes disabled for tier \(firmwareProfileTier.rawValue): forcing observation-only mode (read-only diagnostics).",
                    operation: "startup",
                    backend: BackendID.fallback.rawValue
                )
            }
        }

        // Loud consistency check: a backend that claims verified charging
        // control but cannot receive policies would silently ignore the
        // user's charge limit — the worst kind of failure (control appears
        // configured in the UI while hardware state never changes).
        if capabilities.supportsVerifiedChargingControl, !(activeBackend is ChargingPolicyConfigurable) {
            DaemonLog.error(
                "Backend \(activeBackend.id.rawValue) has verified control but does not support policy configuration; charge limits will NOT be enforced by it.",
                operation: "startup",
                backend: activeBackend.id.rawValue
            )
        }

        // Recovery after boot or daemon crash: clear any adapter cut a dead
        // process (or an older third-party tool) may have left behind, then
        // re-apply the persisted policy. (Releasing a cut is always the
        // safe direction.)
        _ = SMCChargeControl.releaseAllAdaptersIfNeeded()
        // Hardware init is done: cancel the watchdog's concern and start
        // the enforcement loop. (tickNow is async — no re-entrancy here.)
        hardwareInitComplete = true
        engineQueue.async { [weak self] in
            self?.tickNow(reason: .bootRecovery)
        }
    }

    /// Unsupported-platform engine: never probes hardware, never selects a
    /// control backend, and refuses every control command.
    static func unsupportedPlatform(store: PolicyStore, platform: PlatformIdentity) -> ControlEngine {
        let engine = ControlEngine(store: store, skipHardwareInit: true)
        engine.isPlatformSupported = false
        engine.capabilities = engine.activeBackend.capabilities
        engine.firmwareProfileTier = .unsupported
        engine.firmwareProfileSummary = platform.unsupportedReason ?? FirmwareProfileLibrary.summary(for: .unsupported, identity: platform, detectedFamily: .none)
        DaemonLog.error(
            "Running in observation-only mode: \(platform.summaryLine)",
            operation: "startup"
        )
        return engine
    }

    // MARK: Tick loop

    /// One enforcement tick. Called by the timer and by recovery events.
    func tick(reason: ControlRequestReason) {
        engineQueue.async { [weak self] in
            self?.tickNow(reason: reason)
        }
    }

    private func tickNow(reason: ControlRequestReason) {
        locked { tickNowUnserialized(reason: reason) }
    }

    /// Must run under `engineLock`.
    private func tickNowUnserialized(reason: ControlRequestReason) {
        // Two-phase startup: the periodic tick timer is live before hardware
        // probing finishes. Ticking with the placeholder observation backend
        // would silently mis-report state; probing's final act is the boot-
        // recovery tick, so pre-init ticks are a pure no-op.
        guard hardwareInitComplete else { return }
        guard let readings = PlatformDetector.readBatteryFromIOKit() else {
            DaemonLog.warning("No internal battery detected; nothing to control.", operation: "tick")
            return
        }
        lastReadings = readings

        // Observe Apple's native Charge Limit (macOS 26.4+) read-only, so
        // ownership can be reported honestly when no BatteryControl policy
        // is active. Never a control input — policy application is driven
        // entirely by the user's policy + override + calibration.
        let identity = platformIdentity ?? PlatformDetector.detect()
        platformIdentity = identity
        nativeChargeLimit = OwnershipDecisions.nativeState(
            fromSmartBattery: PlatformDetector.readAppleSmartBattery(),
            osMajor: identity.osMajor,
            osMinor: identity.osMinor
        )

        let state = store.state
        var override = state.override

        // Expiration is evaluated by the daemon's existing 20-second tick,
        // never by the GUI. An expired override is ended before deciding any
        // hardware action, so a restart cannot silently extend it.
        if TemporaryOverrideDecisions.shouldExpire(
            override: override,
            expiresAt: state.overrideExpiresAt,
            now: Date()
        ) {
            DaemonLog.info("Temporary force-charge override expired; restoring the saved policy.", operation: "forceCharge")
            override = .none
            store.update {
                $0.override = .none
                if let previous = $0.overridePreviousPolicy { $0.policy = previous }
                $0.overrideExpiresAt = nil
                $0.overridePreviousPolicy = nil
            }
        }

        let calibrationActive = state.calibration?.isActive ?? false

        let action = decideAction(readings: readings, state: state, override: &override)
        desiredAction = action

        // Composite backends (firmware-managed limit) maintain persistent
        // hardware state from policy context. Reconfiguring every tick is
        // redundant when the context is unchanged and the hardware was just
        // verified: the SMC holds the state, and the periodic re-confirm
        // below catches drift. Decision logic is in BatteryCore (unit-
        // tested); the SMC itself still read-verifies before any write.
        let context = FirmwareMaintContext(
            policy: state.policy,
            override: override,
            calibrationActive: calibrationActive
        )
        let now = Date()
        let shouldReconfigure = RecoveryDecisions.shouldReconfigureFirmwareLimit(
            policy: state.policy,
            override: override,
            calibrationActive: calibrationActive,
            lastContext: lastFirmwareContext,
            lastConfirmedAt: lastFirmwareConfirmAt,
            confirmed: controlIsVerified,
            now: now,
            confirmInterval: RecoveryDecisions.reassertIntervalSeconds,
            forceReconfigure: reason != .policyTick && reason != .calibration
        )
        if let configurable = activeBackend as? ChargingPolicyConfigurable {
            if shouldReconfigure {
                let result = configurable.configure(
                    policy: state.policy,
                    override: override,
                    calibrationActive: calibrationActive
                )
                switch result {
                case .success:
                    // configure() returning success means it confirmed the
                    // programmed state by SMC readback (it read-verifies
                    // internally). The periodic re-confirm keeps that proof
                    // fresh without per-tick hardware traffic.
                    lastFirmwareContext = context
                    lastFirmwareConfirmAt = now
                case .failure(let error):
                    // Invalidate the memo: a failed configure must not be
                    // treated as confirmed; retry next tick.
                    lastFirmwareContext = nil
                    lastFirmwareConfirmAt = nil
                    controlIsVerified = false
                    record(errorText: "Firmware-limit maintenance failed: \(error.message)", attempt: ControlAttemptResult(
                        action: action,
                        backendID: activeBackend.id.rawValue,
                        verified: false,
                        verificationDetail: "configure() failed",
                        errorText: error.message,
                        attemptNumber: attemptNumber
                    ))
                }
            }
        }

        // Falling edge of a calibration session (cancel, dismissed safety
        // abort, or natural finish): give back everything the session took.
        // Re-program the user's firmware limit (it was deactivated for the
        // full-range session) AND release any adapter cut the discharge
        // stages latched. While the cut is held, macOS reports the
        // physically attached charger as absent, so a cancelled calibration
        // would leave the Mac "not detecting" its charger until the battery
        // drifted below the resume threshold. Releasing is always the safe
        // direction: it only restores power the Mac already has.
        if CalibrationDecisions.sessionJustEnded(previousActive: calibrationWasActive, currentActive: calibrationActive) {
            SMCChargeControl.releaseAllAdaptersIfNeeded()
            if let configurable = activeBackend as? ChargingPolicyConfigurable {
                _ = configurable.configure(
                    policy: state.policy,
                    override: override,
                    calibrationActive: false
                )
            }
            controlIsVerified = false
            lastFirmwareContext = nil
            lastFirmwareConfirmAt = nil
        }
        calibrationWasActive = calibrationActive

        // Persist the override if the engine resolved it away (target
        // reached, adapter unplugged, force charge finished).
        if override != state.override {
            store.update {
                $0.override = override
                if override == .none {
                    if let previous = $0.overridePreviousPolicy { $0.policy = previous }
                    $0.overrideExpiresAt = nil
                    $0.overridePreviousPolicy = nil
                }
            }
        }

        // A normal-charge decision must never fight a latched adapter cut:
        // firmware can keep a stale cut (e.g. left by an older tool) even
        // though charging should run. Releasing a cut is always the safe
        // direction, so clear any present cut whenever charging is desired.
        if action == .normal {
            SMCChargeControl.releaseAllAdaptersIfNeeded()
        }

        applyIfNeeded(action: action, readings: readings, reason: reason)

        // Periodic reassert: even when nothing changed, periodically prove
        // the hardware still honors the policy (firmware can reset state).
        if Date().timeIntervalSince(lastReassert) > RecoveryDecisions.reassertIntervalSeconds,
           action != .normal,
           controlIsVerified {
            lastReassert = Date()
            DaemonLog.info("Periodic re-assert of \(action.rawValue)", operation: "reassert")
            verifyNow(action: action, readings: readings, attemptNumber: 0)
        }
    }

    /// Decide the desired action for this tick. Mutates `override` when the
    /// engine resolves it away (targets reached, safety stops).
    private func decideAction(
        readings: BatteryReadings,
        state: PolicyStore.StoredState,
        override: inout PolicyOverride
    ) -> ChargingAction {
        // Calibration takes absolute precedence while active.
        if var session = state.calibration, session.isActive {
            if let abort = CalibrationDecisions.safetyAbortReason(readings: readings, session: session) {
                session.abort(abort)
                store.update { $0.calibration = session }
                DaemonLog.warning("Calibration aborted: \(abort)", operation: "calibration")
                _ = activeBackend.apply(.normal)
                return .normal
            }
            if let next = CalibrationDecisions.nextStage(current: session.stage, readings: readings, session: session) {
                DaemonLog.info("Calibration stage → \(next.rawValue)", operation: "calibration")
                session.advance(to: next)
                store.update { $0.calibration = session }
            }
            return ChargingPolicyEngine.decideForCalibration(readings: readings, session: session)
        }

        // Falling edge of a force-discharge session: release any manual
        // adapter cut we still hold. Above the limit the firmware limit will
        // re-cut on its own if it should; releasing here only removes OUR
        // latch so the charger re-attaches without waiting a tick.
        if dischargeWasActive {
            if case .forceDischarge = override {
            } else {
                SMCChargeControl.releaseAllAdaptersIfNeeded()
                DaemonLog.info("Force discharge ended; released any latched adapter cut.", operation: "forceDischarge")
            }
        }
        dischargeWasActive = false
        if case .forceDischarge = override {
            dischargeWasActive = true
        }

        // Force-discharge session bookkeeping.
        if case .forceDischarge(let target, let floor, _) = override {
            let stopPoint = max(target, ChargingPolicyEngine.effectiveDischargeFloor(requested: floor))
            if readings.percentage <= stopPoint {
                DaemonLog.info(
                    "Force discharge reached \(readings.percentage)% (stop at \(stopPoint)%); restoring normal charging.",
                    operation: "forceDischarge"
                )
                override = .none
                appendEvent(kind: "controlled discharge ended", detail: "target or floor reached")
                controlIsVerified = false
                return .normal
            }
            // NOTE: there is deliberately NO unplug abort here. While our
            // adapter cut is latched, macOS reports ExternalConnected = No
            // and drops the adapter object entirely (USB-C PD de-negotiation)
            // — telemetry cannot distinguish our own cut from a physical
            // unplug. A latched cut with no adapter present is simply a
            // no-op; the session still ends at the target/floor, when the
            // user stops it, or before sleep.
        }

        // Force-charge session bookkeeping.
        if case .forceCharge(let target) = override {
            if readings.percentage >= target {
                DaemonLog.info(
                    "Force charge reached \(target)%; restoring the normal policy.",
                    operation: "forceCharge"
                )
                override = .none
                appendEvent(kind: "temporary override target reached", detail: "normal policy restored")
                controlIsVerified = false
            }
        }

        // Consent travels with the persisted override so the safety floor
        // stays removed across daemon restarts for the active session only.
        var belowFloorConsent = false
        if case .forceDischarge(_, _, let consent) = override {
            belowFloorConsent = consent
        }
        return ChargingPolicyEngine.decide(
            readings: readings,
            policy: state.policy,
            override: override,
            belowFloorConsent: belowFloorConsent
        )
    }

    // MARK: Apply + verify

    /// Consecutive write attempts for the currently held action. Bounded so
    /// an action that never verifies is not rewritten forever.
    private var writeAttemptsForCurrentAction = 0

    private func applyIfNeeded(action: ChargingAction, readings: BatteryReadings, reason: ControlRequestReason) {
        // `.hold` means "keep whatever is applied" — nothing to do unless the
        // previous attempt is unverified. A `.hold` after a just-resolved
        // override must never re-apply the override's action (a cancelled
        // discharge would re-latch its adapter cut); resolve to the policy's
        // natural action instead.
        if action == .hold {
            if controlIsVerified { return }
            let resolved: ChargingAction
            if let lastHeldAction, lastHeldAction != .forceDischarge {
                resolved = lastHeldAction
            } else {
                resolved = RecoveryDecisions.resolvedHoldAction(
                    lastHeld: lastHeldAction,
                    policy: store.state.policy,
                    connected: readings.isExternalConnected
                )
            }
            runVerifiedApply(action: resolved, readings: readings, reason: reason)
            return
        }

        // User and recovery events always get a fresh write attempt.
        let isRepeatingTick = (reason == .policyTick || reason == .calibration)
        if !isRepeatingTick {
            writeAttemptsForCurrentAction = 0
            runVerifiedApply(action: action, readings: readings, reason: reason)
            return
        }

        // Same action, already verified: skip redundant SMC writes; the
        // periodic reassert handles drift.
        if action == lastHeldAction, controlIsVerified {
            return
        }

        // Same action, not yet verified: allow a bounded number of rewrite
        // attempts, then back off. The state stays reported as unverified
        // (the UI shows it honestly) instead of hammering the SMC forever.
        if action == lastHeldAction {
            writeAttemptsForCurrentAction += 1
            if writeAttemptsForCurrentAction > VerificationLogic.maxAttempts {
                return
            }
        } else {
            writeAttemptsForCurrentAction = 0
        }

        runVerifiedApply(action: action, readings: readings, reason: reason)
    }

    private func runVerifiedApply(action: ChargingAction, readings: BatteryReadings, reason: ControlRequestReason) {
        lastHeldAction = action
        attemptNumber += 1

        let result = activeBackend.apply(action)

        if case .failure(let error) = result {
            controlIsVerified = false
            let attempt = ControlAttemptResult(
                action: action,
                backendID: activeBackend.id.rawValue,
                verified: false,
                verificationDetail: "Backend reported failure",
                errorText: error.message,
                attemptNumber: attemptNumber
            )
            lastAttempt = attempt
            record(errorText: error.message, attempt: attempt)
            finishOrRetry(action: action, readings: readings, reason: reason)
            return
        }

        verifyNow(action: action, readings: readings, attemptNumber: attemptNumber, reason: reason)
    }

    /// Observe the battery state to confirm the requested transition.
    /// Runs under `engineLock` (also re-entered from the retry timer).
    private func verifyNow(
        action: ChargingAction,
        readings: BatteryReadings,
        attemptNumber attempt: Int,
        reason: ControlRequestReason = .policyTick
    ) {
        locked { verifyNowUnserialized(action: action, readings: readings, attemptNumber: attempt, reason: reason) }
    }

    /// Must run under `engineLock`.
    private func verifyNowUnserialized(
        action: ChargingAction,
        readings: BatteryReadings,
        attemptNumber attempt: Int,
        reason: ControlRequestReason = .policyTick
    ) {
        // The gauge lags; refresh readings before judging.
        let fresh = PlatformDetector.readBatteryFromIOKit() ?? readings
        let verdict = VerificationLogic.verify(action: action, readings: fresh, policy: store.state.policy)

        switch verdict {
        case .verified:
            controlIsVerified = true
            // A later confirmed state supersedes a transient failed/pending
            // attempt. Keep the raw diagnostic log for forensics, but do not
            // expose an old error as the current recovery state in status or
            // the GUI after hardware verification has succeeded.
            lastError = nil
            attemptNumber = 0
            writeAttemptsForCurrentAction = 0
            lastAttempt = ControlAttemptResult(
                action: action,
                backendID: activeBackend.id.rawValue,
                verified: true,
                verificationDetail: "State transition confirmed",
                attemptNumber: attempt
            )
            DaemonLog.info(
                "\(action.displayName) verified via \(activeBackend.id.rawValue)",
                operation: "apply",
                backend: activeBackend.id.rawValue
            )
            appendEvent(kind: "hardware verification succeeded", detail: action.displayName)

        case .pending:
            controlIsVerified = false
            lastAttempt = ControlAttemptResult(
                action: action,
                backendID: activeBackend.id.rawValue,
                verified: false,
                verificationDetail: "Waiting for the battery state to confirm the change (attempt \(attempt)/\(VerificationLogic.maxAttempts))",
                attemptNumber: attempt
            )
            finishOrRetry(action: action, readings: fresh, reason: reason)

        case .failed(let reasonText):
            controlIsVerified = false
            lastAttempt = ControlAttemptResult(
                action: action,
                backendID: activeBackend.id.rawValue,
                verified: false,
                verificationDetail: reasonText,
                attemptNumber: attempt
            )
            record(errorText: reasonText, attempt: lastAttempt!)
            finishOrRetry(action: action, readings: fresh, reason: reason)
        }
    }

    /// Bounded retry: schedule one more verification pass or give up
    /// honestly. No endless retry loops.
    private func finishOrRetry(action: ChargingAction, readings: BatteryReadings, reason: ControlRequestReason) {
        guard attemptNumber < VerificationLogic.maxAttempts else {
            attemptNumber = 0
            DaemonLog.error(
                "Giving up after \(VerificationLogic.maxAttempts) attempts to apply \(action.displayName); the control state is NOT verified.",
                operation: "verify",
                backend: activeBackend.id.rawValue
            )
            lastError = DiagnosticEntry(
                severity: .error,
                operation: action.displayName,
                backendID: activeBackend.id.rawValue,
                message: "The control state could not be verified after \(VerificationLogic.maxAttempts) attempts."
            )
            return
        }

        engineQueue.asyncAfter(deadline: .now() + VerificationLogic.attemptDelaySeconds) { [weak self] in
            guard let self else { return }
            // Re-read and re-verify without re-writing (the write already
            // happened; we are waiting for the state transition to show).
            self.verifyNow(action: action, readings: readings, attemptNumber: self.attemptNumber, reason: reason)
        }
    }

    private func appendEvent(kind: String, detail: String) {
        let event = BatteryControlEvent(kind: kind, detail: detail)
        store.update { state in
            guard state.events.last?.kind != event.kind || state.events.last?.detail != event.detail else { return }
            state.events.append(event)
            if state.events.count > 500 { state.events.removeFirst(state.events.count - 500) }
        }
    }

    private func record(errorText: String, attempt: ControlAttemptResult) {
        DaemonLog.error(errorText, operation: attempt.action.displayName, backend: attempt.backendID)
        lastError = DiagnosticEntry(
            severity: .error,
            operation: attempt.action.displayName,
            backendID: attempt.backendID,
            message: errorText
        )
    }

    // MARK: Recovery

    func powerSourceChanged() {
        DaemonLog.info("Power source changed; re-evaluating policy.", operation: "recovery")
        tick(reason: .powerSourceChange)
    }

    func woke() {
        locked {
            DaemonLog.info("Wake: re-applying charging policy.", operation: "recovery")
            // The SMC state may have been reset across sleep; re-apply and verify.
            controlIsVerified = false
            tick(reason: .sleepWakeRecovery)
        }
    }

    func sleeping() {
        DaemonLog.info("Sleep: releasing adapter cut so discharge cannot continue unattended.", operation: "recovery")
        // Nothing runs while asleep; an adapter cut must not survive it —
        // on any adapter key this firmware exposes.
        SMCChargeControl.releaseAllAdaptersIfNeeded()
    }

    // MARK: Snapshot

    func snapshot(helperStatus: HelperStatus) -> BatteryStatusSnapshot {
        locked {
            BatteryStatusSnapshot(
                readings: lastReadings,
                activePolicy: store.state.policy,
                activeOverride: store.state.override,
                activeCalibration: store.state.calibration,
                controlIsVerified: controlIsVerified,
                activeBackendID: activeBackend.id.rawValue,
                capabilities: capabilities,
                helperStatus: helperStatus,
                firmwareProfileTier: firmwareProfileTier,
                nativeChargeLimit: nativeChargeLimit,
            )
        }
    }

    /// One locked read of the full status payload for the XPC handler
    /// (which runs on a connection queue, not the engine queue).
    func statusPayload(helperStatus: HelperStatus) -> (snapshot: BatteryStatusSnapshot, lastAttempt: ControlAttemptResult?, lastError: DiagnosticEntry?) {
        locked {
            (snapshot(helperStatus: helperStatus), lastAttempt, lastError)
        }
    }

    // MARK: Commands from XPC (validated upstream)

    func applyPolicy(_ policy: ChargingPolicy) -> Bool {
        locked {
            guard isPlatformSupported else { return false }
            guard ControlModeHelpers.validate(policy) == nil else { return false }
            store.update {
                $0.policy = policy
                // A policy change made during an override is the new policy
                // the user wants restored, not a stale pre-override value.
                if $0.override.isChargeOverride { $0.overridePreviousPolicy = policy }
            }
            appendEvent(kind: policy.mode == .passthrough ? "charge-limit disabled" : "charge-limit changed", detail: policy.summary)
            tickNow(reason: .userRequest)
            return true
        }
    }

    func startForceDischarge(targetPercent: Int, floorPercent: Int, belowFloorConsent: Bool = false) -> Bool {
        locked {
            guard isPlatformSupported else { return false }
            guard (1...100).contains(targetPercent),
                  (1...100).contains(floorPercent) else { return false }
            let floor = ChargingPolicyEngine.effectiveDischargeFloor(requested: floorPercent)
            let target = targetPercent
            // Never discharge toward a target below the floor.
            guard target >= floor else { return false }
            // Below-safety-floor sessions require explicit user consent; without
            // it the floor is clamped back up to the safety floor.
            let consented = ChargingPolicyEngine.requiresBelowFloorConsent(floor: floor) && belowFloorConsent
            let effectiveFloor = consented ? floor : max(floor, ChargingPolicyEngine.minimumDischargeFloor)
            store.update {
                $0.override = .forceDischarge(
                    targetPercent: target,
                    floorPercent: effectiveFloor,
                    belowFloorConsent: consented
                )
            }
            appendEvent(kind: "controlled discharge started", detail: "target \(target)%, floor \(effectiveFloor)%")
            if consented {
                DaemonLog.warning(
                    "Force discharge below the safety floor (floor \(effectiveFloor)%, target \(target)%): user accepted accelerated battery degradation.",
                    operation: "forceDischarge"
                )
            }
            tickNow(reason: .userRequest)
            return true
        }
    }

    func startForceCharge(targetPercent: Int, durationSeconds: TimeInterval? = nil) -> Bool {
        locked {
            guard isPlatformSupported else { return false }
            guard TemporaryOverrideDecisions.isValidDuration(durationSeconds),
                  (1...100).contains(targetPercent) else { return false }
            let target = targetPercent
            let duration = TemporaryOverrideDecisions.acceptedDuration(durationSeconds)
            let current = store.state
            store.update {
                $0.overridePreviousPolicy = current.policy
                $0.overrideExpiresAt = duration.map { Date().addingTimeInterval($0) }
                $0.override = .forceCharge(targetPercent: target)
            }
            appendEvent(kind: "temporary override started", detail: "target \(target)%")
            tickNow(reason: .userRequest)
            return true
        }
    }

    /// Restore macOS/default charging before privileged removal. This is
    /// deliberately daemon-owned so uninstall cannot leave bfF0 active or
    /// leave an adapter cut latched behind.
    func prepareForUninstall() -> Bool {
        locked {
            store.update {
                $0.calibration = nil
                $0.override = .none
                if let previous = $0.overridePreviousPolicy { $0.policy = previous }
                $0.overrideExpiresAt = nil
                $0.overridePreviousPolicy = nil
                $0.policy = .passthrough()
            }
            // Configure the selected backend directly so a firmware limit is
            // deactivated and read back before the daemon is removed. Do not
            // require the battery gauge to begin charging immediately: at a
            // high state of charge macOS may legitimately remain not-charging
            // even after the control is safely released.
            let hardwareResult: Result<Void, ControlError>
            if let configurable = activeBackend as? ChargingPolicyConfigurable {
                hardwareResult = configurable.configure(
                    policy: .passthrough(), override: .none, calibrationActive: false
                )
            } else {
                hardwareResult = activeBackend.apply(.normal)
            }
            if case .success = hardwareResult {
                activeBackend.restoreDefaults()
            }
            let restored = if case .success = hardwareResult { true } else { false }
            controlIsVerified = restored
            appendEvent(
                kind: restored ? "uninstall safe state restored" : "uninstall restoration failed",
                detail: restored ? "macOS/default charging verified" : "charging state could not be verified"
            )
            return restored
        }
    }

    func cancelOverrides() -> Bool {
        locked {
            let previous = store.state.overridePreviousPolicy
            let expectedPolicy = previous ?? store.state.policy
            store.update {
                $0.override = .none
                if let previous = $0.overridePreviousPolicy { $0.policy = previous }
                $0.overrideExpiresAt = nil
                $0.overridePreviousPolicy = nil
            }
            let restored = store.state.override == .none && store.state.policy == expectedPolicy
            appendEvent(
                kind: restored ? "temporary override cancelled" : "restoration failed",
                detail: restored ? "previous policy restored" : "the saved policy could not be restored"
            )
            guard restored else { return false }
            controlIsVerified = false
            tickNow(reason: .userRequest)
            return true
        }
    }

    func beginCalibration() -> Bool {
        locked {
            guard isPlatformSupported else { return false }
            guard capabilities.supportsCalibration else { return false }
            // The cycle ends at the user's charge limit (e.g. 80%), so the
            // battery finishes resting at the limit on wall power.
            let limit = min(max(store.state.policy.upperLimit, 1), 100)
            var session = CalibrationSession(
                lowPercent: CalibrationDecisions.Limits.calibrationLowPercent,
                limitPercent: limit
            )
            session.advance(to: .prepare)
            store.update { $0.calibration = session }
            tickNow(reason: .calibration)
            return true
        }
    }

    func cancelCalibration() {
        locked {
            store.update { $0.calibration = nil }
            // Cancel must hand the charger back immediately: a discharge
            // stage may have latched an adapter cut, and while the cut is
            // held macOS reports the attached charger as absent. Release
            // before the tick so the user sees the charger return right
            // away; the tick then re-programs the user's policy as usual.
            SMCChargeControl.releaseAllAdaptersIfNeeded()
            tickNow(reason: .userRequest)
        }
    }

    /// Validate and install a new compatibility database, atomically and
    /// in-process. Called only from the daemon's XPC handler (the file is
    /// root-owned; this is its only writer). On any validation failure
    /// nothing is written and the error is reported to the caller verbatim.
    func installCompatibilityDatabase(
        _ payload: FirmwareProfileLibrary.DatabasePayload
    ) throws -> CompatibilityDatabaseInstaller.InstallResult {
        try locked {
            let result = try CompatibilityDatabaseInstaller.install(
                payload,
                toPath: BatteryXPC.compatibilityDatabasePath
            )
            // The new profiles change classification inputs (tier can move
            // between verified/compatibleByCapability). Re-classify now so
            // status reads never disagree with the just-installed evidence.
            if let identity = platformIdentity {
                firmwareProfileTier = FirmwareProfileLibrary.classify(
                    identity: identity,
                    detectedFamily: detectedSMCFamily,
                    systemFirmwareBuild: identity.systemFirmwareBuild
                )
                firmwareProfileSummary = FirmwareProfileLibrary.summary(
                    for: firmwareProfileTier,
                    identity: identity,
                    detectedFamily: detectedSMCFamily
                )
            }
            DaemonLog.info(
                "Compatibility database installed: \(result.acceptedProfiles) profile(s), \(result.totalProfiles) total active.",
                operation: "database"
            )
            return result
        }
    }

    func diagnostics() -> DiagnosticsReport {
        locked {
            DiagnosticsReport(
                platform: PlatformDetector.detect(),
                backendID: activeBackend.id.rawValue,
                backendDescription: activeBackend.description,
                capabilities: capabilities,
                currentAction: lastHeldAction ?? .normal,
                requestedAction: desiredAction,
                verified: controlIsVerified,
                lastAttempt: lastAttempt,
                lastError: lastError,
                daemonVersion: daemonVersion,
                helperUptimeSeconds: uptime,
                recentLogEntries: DaemonLog.recentEntries(),
                recentEvents: store.state.events,
                firmwareProfileTier: firmwareProfileTier.rawValue,
                firmwareProfileSummary: firmwareProfileSummary,
                nativeChargeLimit: nativeChargeLimit
            )
        }
    }
}
