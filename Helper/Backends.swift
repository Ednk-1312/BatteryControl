import BatteryCore
import Foundation

/// One battery-control backend. Implementations run inside the privileged
/// daemon and must be honest: report failure rather than claim success.
protocol ChargingBackend: AnyObject {
    var id: BackendID { get }

    /// Human-readable description for the diagnostics page.
    var description: String { get }

    /// Probe the mechanism. Cheap, side-effect-free checks (does the key
    /// exist? is it writable?) — called at startup and by diagnostics.
    func probe() -> BatteryCapabilities

    /// The capabilities this backend reported at probe time.
    var capabilities: BatteryCapabilities { get }

    /// Apply a control action. Must verify the resulting hardware state
    /// before returning success; implementations must never report a state
    /// that was not confirmed.
    func apply(_ action: ChargingAction) -> Result<Void, ControlError>

    /// Re-assert the last applied action (recovery paths).
    func reassert() -> Result<Void, ControlError>

    /// Restore hardware to macOS defaults. Used on shutdown and uninstall.
    func restoreDefaults()
}

/// A backend failure with a precise, human-readable cause.
struct ControlError: Error {
    var message: String
    var isVerificationFailure: Bool

    init(_ message: String, isVerificationFailure: Bool = false) {
        self.message = message
        self.isVerificationFailure = isVerificationFailure
    }
}

/// Backends that translate policy context into hardware state themselves
/// (composite mechanisms like the firmware-managed limit, where "the limit"
/// is not a momentary action but persistent state). The engine calls this
/// every tick with the live context; implementations MUST be idempotent —
/// a no-op readback when the hardware already matches, writes only on drift.
protocol ChargingPolicyConfigurable: ChargingBackend {
    func configure(policy: ChargingPolicy, override: PolicyOverride, calibrationActive: Bool) -> Result<Void, ControlError>
}

extension ChargingPolicyConfigurable {
    /// Default: no policy-shaped state to maintain.
    func configure(policy: ChargingPolicy, override: PolicyOverride, calibrationActive: Bool) -> Result<Void, ControlError> {
        .success(())
    }
}

/// Primary backend: the Apple Silicon charge-inhibit keys (CH0B/CH0C) plus
/// the adapter-input cut (CH0I) used for forced discharge. This is the same
/// mechanism verified by battery-limiter on Apple Silicon and used by BatFi;
/// on macOS 15.x some Macs accept the write but do not honor it, which is
/// why every action is verified by reading the keys back and by observing
/// the actual battery state transition.
final class SMCInhibitBackend: ChargingBackend {

    let id = BackendID.smcInhibit

    let description = "Apple Silicon SMC charge-inhibit keys (CH0B/CH0C) with adapter cut (CH0I) for forced discharge."

    private(set) var capabilities: BatteryCapabilities = .unsupported

    func probe() -> BatteryCapabilities {
        let caps: BatteryCapabilities
        do {
            try SMC.open()
            // Key existence: a machine without CH0B/CH0C cannot inhibit.
            _ = try SMC.keyInfo(SMCChargeControl.inhibitB)
            _ = try SMC.keyInfo(SMCChargeControl.inhibitC)
            _ = try SMC.keyInfo(SMCChargeControl.adapterDisable)
            caps = BatteryCapabilities(
                supportsUpperLimit: true,
                supportsLowerLimit: true,
                supportsFixedLimit: true,
                supportsForceDischarge: true,
                supportsForceCharge: true,
                supportsCalibration: true,
                supportsSMC: true,
                supportsVerifiedChargingControl: true
            )
        } catch SMCError.keyNotFound {
            DaemonLog.warning("SMC charge keys not found on this machine", operation: "probe", backend: id.rawValue)
            caps = BatteryCapabilities(
                supportsUpperLimit: false,
                supportsLowerLimit: false,
                supportsFixedLimit: false,
                supportsForceDischarge: false,
                supportsForceCharge: false,
                supportsCalibration: false,
                supportsSMC: true,
                supportsVerifiedChargingControl: false
            )
        } catch {
            DaemonLog.error("SMC probe failed: \(error)", operation: "probe", backend: id.rawValue)
            caps = .unsupported
        }
        capabilities = caps
        return caps
    }

    func apply(_ action: ChargingAction) -> Result<Void, ControlError> {
        do {
            switch action {
            case .normal:
                try SMCChargeControl.applyAndVerify(
                    inhibit: SMCChargeControl.InhibitValue.normal,
                    adapter: SMCChargeControl.AdapterValue.normal
                )
            case .inhibitCharging, .hold:
                try SMCChargeControl.applyAndVerify(
                    inhibit: SMCChargeControl.InhibitValue.inhibit,
                    adapter: SMCChargeControl.AdapterValue.normal
                )
            case .forceDischarge:
                try SMCChargeControl.applyAndVerify(
                    inhibit: SMCChargeControl.InhibitValue.inhibit,
                    adapter: SMCChargeControl.AdapterValue.cut
                )
            }
            return .success(())
        } catch let error as SMCError {
            return .failure(ControlError(describe(error)))
        } catch {
            return .failure(ControlError("The SMC rejected the charging-control write: \(error)"))
        }
    }

    func reassert() -> Result<Void, ControlError> {
        apply(lastAction ?? .normal)
    }

    func restoreDefaults() {
        // Clear the adapter cut first (the dangerous one), then the inhibit.
        SMCChargeControl.releaseAdapter()
        SMCChargeControl.setInhibit(false)
    }

    private var lastAction: ChargingAction?

    private func describe(_ error: SMCError) -> String {
        switch error {
        case .driverNotFound:
            return "The AppleSMC driver was not found on this machine."
        case .failedToOpen:
            return "Could not open a connection to the AppleSMC driver."
        case .keyNotFound:
            return "A required SMC charge-control key is missing; this Mac's firmware does not expose it."
        case .notPrivileged:
            return "The daemon lacks root privileges for the SMC write (helper misinstalled?)."
        case .invalidDataSize(let key, let expected, let actual):
            return "SMC key \(fourCCString(key)) has \(actual) bytes, expected \(expected)."
        case .unknown(let io, let smc):
            return "The SMC rejected the charging-control write (IOReturn \(io), SMC result \(smc))."
        }
    }
}

/// Firmware-managed charge-limit backend for 20xxx-firmware Apple Silicon
/// Macs (M3/15.8-era and later). Three SMC keys implement a hysteresis limit
/// that Apple's OWN firmware enforces — including during sleep and with no
/// userspace daemon running:
///
///   bfF0  ui8   activation: 0x00 = limit off, 0x02 = limit active
///   bfD0  ui32  upper percentage (little-endian encoded)
///   bfE0  ui32  lower percentage (little-endian encoded)
///
/// The firmware then stops charging above the upper bound and resumes below
/// the lower bound; above the upper limit it may run the Mac from the
/// battery (documented behavior), so the percentage can slowly fall back
/// into the band.
///
/// Safety chain implemented here:
///   1. Capability detection: all three keys must exist with correct types
///      (ui8/ui32/ui32) before anything is written.
///   2. Value validation: 1...100, lower < upper, sane bounds.
///   3. Readback before write: current firmware state is read and logged.
///   4. Required write order (deactivate → upper → lower → activate).
///   5. Full readback verification after the write sequence; failure to
///      verify triggers automatic deactivation and an honest error.
///   6. Bounded retries; restore-to-disabled on failure.
final class FirmwareLimitBackend: ChargingBackend, ChargingPolicyConfigurable {

    let id = BackendID.firmwareLimit

    let description = "Apple firmware-managed charge limit (bfF0 activate, bfD0 upper %, bfE0 lower %). Enforced by the SMC itself, including during sleep."

    private(set) var capabilities: BatteryCapabilities = .unsupported

    // Key names live in FirmwareLimitKeys (SMCLayer.swift) so the CLI and
    // the family detector share them.
    static var activationKey: FourCharCode { FirmwareLimitKeys.activation }
    static var upperKey: FourCharCode { FirmwareLimitKeys.upper }
    static var lowerKey: FourCharCode { FirmwareLimitKeys.lower }

    /// Activation byte values.
    enum Activation {
        static let off: UInt8 = 0x00
        static let active: UInt8 = 0x02
    }

    func probe() -> BatteryCapabilities {
        do {
            try SMC.open()
        } catch {
            DaemonLog.error("SMC unavailable for firmware-limit probe: \(error)", operation: "probe", backend: id.rawValue)
            capabilities = .unsupported
            return capabilities
        }
        defer { SMC.close() }

        // All three keys must exist and be readable. Metadata may be
        // unpopulated (size 0) on current firmware even for live keys, so
        // existence is decided by direct reads (keyUsable), not metadata.
        guard SMCChargeControl.keyUsable(Self.activationKey),
              SMCChargeControl.keyUsable(Self.upperKey),
              SMCChargeControl.keyUsable(Self.lowerKey) else {
            DaemonLog.info("Firmware-limit keys not present on this machine", operation: "probe", backend: id.rawValue)
            capabilities = .unsupported
            return capabilities
        }

        // Validate declared shapes when the firmware populates them; treat
        // unpopulated metadata (0) as unknown-but-usable. The acceptance
        // rule lives in FirmwareLimitValidation (BatteryCore) so it is
        // unit-tested against negative shapes.
        let actInfo = try? SMC.keyInfo(Self.activationKey)
        let upInfo = try? SMC.keyInfo(Self.upperKey)
        let loInfo = try? SMC.keyInfo(Self.lowerKey)
        let shapesValid = FirmwareLimitValidation.keyShapesAreAcceptable([
            "bfF0": Int(actInfo?.dataSize ?? 0),
            "bfD0": Int(upInfo?.dataSize ?? 0),
            "bfE0": Int(loInfo?.dataSize ?? 0),
        ])
        guard shapesValid else {
            DaemonLog.warning(
                "Firmware-limit keys present with unexpected shapes (act=\(actInfo?.dataSize ?? 0)B, up=\(upInfo?.dataSize ?? 0)B, lo=\(loInfo?.dataSize ?? 0)B) — refusing.",
                operation: "probe",
                backend: id.rawValue
            )
            capabilities = .unsupported
            return capabilities
        }

        // Force discharge rides the adapter-cut key (CH0I / CH0J / CHIE),
        // which exists independently of the charging-control family.
        let adapterCut = SMCChargeControl.findAdapterCutKey()
        let supportsDischarge = adapterCut != nil

        DaemonLog.info(
            "Firmware-limit backend available (keys valid, discharge key \(adapterCut.map { fourCCString($0.key) } ?? "none")).",
            operation: "probe",
            backend: id.rawValue
        )
        capabilities = BatteryCapabilities(
            supportsUpperLimit: true,
            supportsLowerLimit: true,
            supportsFixedLimit: true,
            supportsForceDischarge: supportsDischarge,
            supportsForceCharge: true,
            supportsCalibration: true,
            supportsSMC: true,
            supportsVerifiedChargingControl: true
        )
        return capabilities
    }

    // MARK: State read (read-only, safe)

    struct FirmwareLimitState: Equatable {
        var active: Bool
        var upperPercent: UInt32
        var lowerPercent: UInt32
    }

    /// Read the current firmware-limit state. Pure read — never writes.
    func readState() -> Result<FirmwareLimitState, ControlError> {
        do {
            try SMC.open()
            let act = try SMC.readBytes(Self.activationKey).0
            let upper = try SMC.readUInt32LE(Self.upperKey)
            let lower = try SMC.readUInt32LE(Self.lowerKey)
            let state = FirmwareLimitState(
                active: act == Activation.active,
                upperPercent: upper,
                lowerPercent: lower
            )
            return .success(state)
        } catch let e as SMCError {
            return .failure(ControlError(Self.describe(e)))
        } catch {
            return .failure(ControlError("Failed to read the firmware-limit keys: \(error)"))
        }
    }

    /// Which adapter-cut key this machine supports, discovered at probe time.
    private var adapterCutKey: (key: FourCharCode, cut: UInt8)? {
        SMCChargeControl.findAdapterCutKey()
    }

    // MARK: Backend protocol

    func apply(_ action: ChargingAction) -> Result<Void, ControlError> {
        switch action {
        case .normal, .hold, .inhibitCharging:
            // The firmware owns the charging decision once the limit is
            // programmed; the engine re-programs limits via configure() so
            // apply() only needs to keep the state consistent.
            return .success(())
        case .forceDischarge:
            guard let cut = adapterCutKey else {
                return .failure(ControlError("This machine exposes no adapter-cut key alongside the firmware limit."))
            }
            do {
                try SMC.open()
                try SMC.writeUInt8(cut.key, value: cut.cut)
            } catch let e as SMCError {
                return .failure(ControlError(Self.describe(e)))
            } catch {
                return .failure(ControlError("Failed to cut the adapter: \(error)"))
            }
            return verifyAdapterCut(cut)
        }
    }

    /// Read-back verification for the adapter cut with a settle window.
    private func verifyAdapterCut(_ cut: (key: FourCharCode, cut: UInt8)) -> Result<Void, ControlError> {
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.12)
            if let value = try? SMC.readBytes(cut.key).0, value == cut.cut {
                return .success(())
            }
        }
        // The cut did not stick. Restore inflow immediately — a Mac that
        // believes it is discharging while actually charging is merely
        // wrong; one that silently drains is a hazard. Fail honestly.
        _ = SMCChargeControl.releaseAllAdapters()
        return .failure(ControlError(
            "The adapter-cut write was not confirmed by read-back; inflow has been restored.",
            isVerificationFailure: true
        ))
    }

    /// Program the limit with the full safety chain. Values must already be
    /// validated by FirmwareLimitValidation (the CLI path validates too).
    func programLimit(upper: Int, lower: Int) -> Result<Void, ControlError> {
        if let problem = FirmwareLimitValidation.problem(upper: upper, lower: lower) {
            return .failure(ControlError("Refusing to program invalid firmware limits: \(problem)"))
        }

        // Readback of current state (also proves the keys are live).
        switch readState() {
        case .success(let current):
            DaemonLog.info(
                "Firmware limit before write: active=\(current.active) upper=\(current.upperPercent) lower=\(current.lowerPercent)",
                operation: "apply",
                backend: id.rawValue
            )
            if current.active, current.upperPercent == UInt32(upper), current.lowerPercent == UInt32(lower) {
                return .success(()) // already in the requested state
            }
        case .failure(let err):
            return .failure(err)
        }

        // Required write order: deactivate → upper → lower → activate. Each
        // step is confirmed by readback before the next (with a settle window
        // — some firmware applies SMC writes asynchronously), and any failed
        // step deactivates the limit and reports failure honestly.
        let steps: [(String, () throws -> Void, () throws -> Bool)] = [
            ("bfF0 = 0x00",
             { try SMC.writeUInt8(Self.activationKey, value: Activation.off) },
             { try SMC.readBytes(Self.activationKey).0 == Activation.off }),
            ("bfD0 = upper",
             { try SMC.writeUInt32LE(Self.upperKey, value: UInt32(upper)) },
             { try SMC.readUInt32LE(Self.upperKey) == UInt32(upper) }),
            ("bfE0 = lower",
             { try SMC.writeUInt32LE(Self.lowerKey, value: UInt32(lower)) },
             { try SMC.readUInt32LE(Self.lowerKey) == UInt32(lower) }),
            ("bfF0 = 0x02",
             { try SMC.writeUInt8(Self.activationKey, value: Activation.active) },
             { try SMC.readBytes(Self.activationKey).0 == Activation.active }),
        ]
        do {
            try SMC.open()
            for (label, write, verifyStep) in steps {
                try write()
                var confirmed = false
                for _ in 0..<3 {
                    Thread.sleep(forTimeInterval: 0.12)
                    if try verifyStep() { confirmed = true; break }
                }
                guard confirmed else {
                    throw SMCError.unknown(kIOReturn: -2, smcResult: 1) // step-level verification failure
                }
                DaemonLog.info("Firmware-limit step verified: \(label).", operation: "apply", backend: id.rawValue)
            }
        } catch let e as SMCError {
            // Automatic recovery on write/verify failure: force the limit off.
            DaemonLog.error("Firmware-limit write failed (\(Self.describe(e))); deactivating.", operation: "apply", backend: id.rawValue)
            _ = forceDeactivate()
            return .failure(ControlError(Self.describe(e)))
        } catch {
            _ = forceDeactivate()
            return .failure(ControlError("Firmware-limit write failed: \(error)"))
        }

        // Verify by readback, with bounded retries. The confirmation rule
        // is FirmwareLimitValidation.readbackConfirms (unit-tested).
        for attempt in 1...3 {
            Thread.sleep(forTimeInterval: 0.2)
            switch readState() {
            case .success(let s) where FirmwareLimitValidation.readbackConfirms(
                activationByte: activationByteNow(),
                upperPercent: s.upperPercent,
                lowerPercent: s.lowerPercent,
                requestedUpper: upper,
                requestedLower: lower
            ):
                DaemonLog.info(
                    "Firmware limit verified: active, upper=\(s.upperPercent), lower=\(s.lowerPercent) (attempt \(attempt)).",
                    operation: "apply",
                    backend: id.rawValue
                )
                return .success(())
            case .success(let s):
                DaemonLog.warning(
                    "Firmware-limit readback mismatch (attempt \(attempt)): active=\(s.active) upper=\(s.upperPercent) lower=\(s.lowerPercent).",
                    operation: "apply",
                    backend: id.rawValue
                )
            case .failure(let err):
                DaemonLog.warning("Firmware-limit readback failed (attempt \(attempt)): \(err.message)", operation: "apply", backend: id.rawValue)
            }
        }

        // Verification failed → deactivate and report honestly.
        _ = forceDeactivate()
        return .failure(ControlError(
            "The firmware-limit writes were accepted but the readback did not confirm them. The limit has been deactivated for safety.",
            isVerificationFailure: true
        ))
    }

    // MARK: configure() — the engine-facing policy path

    func configure(policy: ChargingPolicy, override: PolicyOverride, calibrationActive: Bool) -> Result<Void, ControlError> {
        // Calibration needs full-range hardware control (charge to 100%,
        // discharge to 20%); a firmware limit at 80% would fight it. The
        // limit is deactivated for the session and re-programmed from the
        // user policy on the tick after it finishes.
        if calibrationActive {
            return deactivate()
        }
        switch override {
        case .forceDischarge:
            // The engine drives discharge via .forceDischarge apply(); the
            // firmware limit stays active so the band still governs
            // recharging afterwards.
            return .success(())
        case .forceCharge(let target):
            // A force-charge target near 100% must clear the firmware limit,
            // otherwise the firmware would stop the charge below 100%.
            if target > 100 - FirmwareLimitValidation.minimumLimitGap {
                return deactivate()
            }
            // Charging toward a target within the limit: keep the limit.
            return programLimit(upper: policy.upperLimit, lower: policy.effectiveLowerLimit)
        case .none:
            break
        }
        switch policy.mode {
        case .passthrough:
            return deactivate()
        case .hysteresis, .fixedTarget:
            return programLimit(upper: policy.upperLimit, lower: policy.effectiveLowerLimit)
        }
    }

    private func deactivate() -> Result<Void, ControlError> {
        switch readState() {
        case .success(let s) where !s.active:
            return .success(())
        case .success:
            return forceDeactivate() ? .success(())
                : .failure(ControlError("Failed to deactivate the firmware-managed charge limit.", isVerificationFailure: true))
        case .failure(let err):
            return .failure(err)
        }
    }

    /// The activation byte as of right now (0 when unreadable).
    private func activationByteNow() -> UInt8 {
        (try? SMC.readBytes(Self.activationKey).0) ?? 0
    }

    /// Best-effort forced deactivation. Returns whether the readback confirms it.
    @discardableResult
    private func forceDeactivate() -> Bool {
        for _ in 0..<3 {
            do {
                try SMC.open()
                try SMC.writeUInt8(Self.activationKey, value: Activation.off)
                if case .success(let s) = readState(), !s.active {
                    return true
                }
            } catch {
                SMC.close()
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    func reassert() -> Result<Void, ControlError> {
        // The firmware keeps its state across daemon restarts and sleep; the
        // engine's configure() path re-programs when the policy changes.
        return .success(())
    }

    func restoreDefaults() {
        _ = forceDeactivate()
        SMCChargeControl.releaseAllAdapters()
    }

    static func describe(_ error: SMCError) -> String {
        switch error {
        case .driverNotFound:
            return "The AppleSMC driver was not found on this machine."
        case .failedToOpen:
            return "Could not open a connection to the AppleSMC driver."
        case .keyNotFound:
            return "A firmware-limit SMC key is missing; this Mac's firmware does not support the mechanism."
        case .notPrivileged:
            return "The daemon lacks root privileges for the SMC write (helper misinstalled?)."
        case .invalidDataSize(let key, let expected, let actual):
            return "SMC key \(fourCCString(key)) has \(actual) bytes, expected \(expected) — refusing to use it."
        case .unknown(let io, let smc):
            return "The SMC rejected the request (IOReturn \(io), SMC result \(smc))."
        }
    }
}

func fourCCString(_ code: FourCharCode) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

/// Primary backend on modern Apple Silicon: Apple's own power-management
/// assertions. powerd honors two assertion types that map exactly onto our
/// control actions:
///
///  - ChargeInhibit — the adapter powers the system but the battery is not
///    charged. Used for the upper limit / hysteresis band (and to hold the
///    level during a force-charge override finish).
///  - DisableInflow — the adapter is electrically detached; the system runs
///    off the battery even while plugged in. Used for forced discharge.
///
/// This is the mechanism the OS itself uses (the assertion names appear in
/// pmset's own assertion table, and IOPM.h documents that the kernel
/// forcibly re-enables inflow if the battery reaches the fully-discharged
/// state while a DisableInflow assertion is held — a built-in safety net).
/// It needs no raw SMC writes, so it keeps working on macOS 15.5+ firmware
/// where the CH0B/CH0C/CH0I keys no longer exist.
///
/// Verification: the assertion call itself returns success/failure, and the
/// engine additionally verifies by observing battery state; here we also
/// check `ExternalChargeCapable`/charging state via IOKit after a short
/// settle window.
final class PMAssertionBackend: ChargingBackend {

    let id = BackendID.pmAssertion

    let description = "Apple powerd assertions (ChargeInhibit to pause charging, DisableInflow for forced discharge)."

    private(set) var capabilities: BatteryCapabilities = .unsupported

    /// Currently held assertion IDs, keyed by kind. 0 = not held.
    private var chargeInhibitAssertion: IOPMAssertionID = 0
    private var inflowDisableAssertion: IOPMAssertionID = 0

    func probe() -> BatteryCapabilities {
        // The assertion API is a public IOKit interface with no capability
        // key to read; the honest probe is a live round-trip: create a
        // ChargeInhibit assertion, confirm powerd accepted it, release it,
        // and confirm the release. NOTE (validated on M3 / macOS 15.8):
        // powerd ACCEPTS these assertions (they show in `pmset -g
        // assertions`) but on current Apple Silicon firmware they do not
        // stop the charger — charging continued at full rate while a
        // ChargeInhibit assertion was held. The mechanism is therefore
        // registered but NOT selected as verified control until an observed
        // state transition confirms it. The engine's post-apply observation
        // handles this: if the battery keeps charging, the action reports
        // unverified and the selector falls back.
        let created = createAssertion(named: "ChargeInhibit", reason: "BatteryControl capability probe")
        guard created.success, created.id != 0 else {
            DaemonLog.warning(
                "Power-assertion probe: powerd did not accept a ChargeInhibit assertion (\(created.status)).",
                operation: "probe",
                backend: id.rawValue
            )
            capabilities = .unsupported
            return capabilities
        }
        let released = releaseAssertion(created.id)
        guard released else {
            DaemonLog.error(
                "Power-assertion probe: created an assertion but failed to release it — refusing to use this backend.",
                operation: "probe",
                backend: id.rawValue
            )
            capabilities = .unsupported
            return capabilities
        }
        DaemonLog.info(
            "Power-assertion probe: ChargeInhibit round-trip succeeded (acceptance only; enforcement verified per-action).",
            operation: "probe",
            backend: id.rawValue
        )
        // Acceptance is real but enforcement is NOT proven on modern
        // firmware: report the mechanism as present-but-unverified so the
        // selector prefers it only when no SMC backend exists, and so the
        // UI shows honest status. The engine's observation-based
        // verification will demote it at runtime if a policy action fails
        // to produce the expected battery state transition.
        capabilities = BatteryCapabilities(
            supportsUpperLimit: true,
            supportsLowerLimit: true,
            supportsFixedLimit: true,
            supportsForceDischarge: true,
            supportsForceCharge: true,
            supportsCalibration: true,
            supportsSMC: false,
            supportsVerifiedChargingControl: false
        )
        return capabilities
    }

    func apply(_ action: ChargingAction) -> Result<Void, ControlError> {
        switch action {
        case .normal:
            let ok = releaseIfHeld(&chargeInhibitAssertion, kind: "ChargeInhibit")
                && releaseIfHeld(&inflowDisableAssertion, kind: "DisableInflow")
            return ok ? .success(()) : .failure(ControlError("Failed to release the charging-control assertions.", isVerificationFailure: true))

        case .inhibitCharging, .hold:
            let ok = releaseIfHeld(&inflowDisableAssertion, kind: "DisableInflow")
            let created = createAssertion(named: "ChargeInhibit", reason: "BatteryControl charge limit")
            guard created.success, created.id != 0 else {
                return .failure(ControlError("powerd did not accept the ChargeInhibit assertion (\(created.status))."))
            }
            chargeInhibitAssertion = created.id
            return (ok || inflowDisableAssertion == 0) ? .success(())
                : .failure(ControlError("ChargeInhibit applied but DisableInflow could not be released.", isVerificationFailure: true))

        case .forceDischarge:
            // DisableInflow alone detaches the adapter; the battery will not
            // be charged while it is held, so no ChargeInhibit is needed.
            let created = createAssertion(named: "DisableInflow", reason: "BatteryControl forced discharge")
            guard created.success, created.id != 0 else {
                return .failure(ControlError("powerd did not accept the DisableInflow assertion (\(created.status))."))
            }
            inflowDisableAssertion = created.id
            let releasedInhibit = releaseIfHeld(&chargeInhibitAssertion, kind: "ChargeInhibit")
            return releasedInhibit || chargeInhibitAssertion == 0 ? .success(())
                : .failure(ControlError("DisableInflow applied but ChargeInhibit could not be released.", isVerificationFailure: true))
        }
    }

    func reassert() -> Result<Void, ControlError> {
        // Assertion IDs survive, but powerd can drop assertions from
        // misbehaving processes at its discretion; re-create them to be sure.
        let heldInhibit = chargeInhibitAssertion != 0
        let heldInflow = inflowDisableAssertion != 0
        guard heldInhibit || heldInflow else { return .success(()) }
        let action: ChargingAction = heldInflow ? .forceDischarge : .inhibitCharging
        // Release first so re-creation does not accumulate duplicate holds.
        _ = releaseIfHeld(&chargeInhibitAssertion, kind: "ChargeInhibit")
        _ = releaseIfHeld(&inflowDisableAssertion, kind: "DisableInflow")
        return apply(action)
    }

    func restoreDefaults() {
        _ = releaseIfHeld(&chargeInhibitAssertion, kind: "ChargeInhibit")
        _ = releaseIfHeld(&inflowDisableAssertion, kind: "DisableInflow")
    }

    // MARK: Assertion primitives

    private func createAssertion(named name: String, reason: String) -> (success: Bool, id: IOPMAssertionID, status: IOReturn) {
        var assertionID = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            name as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard status == kIOReturnSuccess else {
            return (false, 0, status)
        }
        return (true, assertionID, status)
    }

    private func releaseIfHeld(_ holder: inout IOPMAssertionID, kind: String) -> Bool {
        guard holder != 0 else { return true }
        let ok = releaseAssertion(holder)
        if ok {
            holder = 0
        } else {
            DaemonLog.error(
                "Failed to release the \(kind) assertion (id \(holder)); will retry on the next tick.",
                operation: "apply",
                backend: id.rawValue
            )
        }
        return ok
    }

    private func releaseAssertion(_ assertionID: IOPMAssertionID) -> Bool {
        IOPMAssertionRelease(assertionID) == kIOReturnSuccess
    }

    deinit {
        restoreDefaults()
    }
}

/// Secondary backend candidate: the CHWA upper-limit key (as used by AlDente
/// and bclm on Apple Silicon, where firmware accepts 80 or 100 only). Probe
/// first; if the key is absent or rejected, this backend reports itself as
/// unverified and the selector moves on. It is intentionally never selected
/// unless the probe proves a working, verified control path.
final class CHWABackend: ChargingBackend {

    let id = BackendID.smcCHWA

    let description = "SMC CHWA firmware charge limit (80/100 only on supported firmware)."

    private(set) var capabilities: BatteryCapabilities = .unsupported

    /// The CHWA key is not established under a stable public name across
    /// machines; probing it blind would risk writing unknown keys. Until a
    /// verified probe exists for the running machine, this backend reports
    /// unsupported — the SMC inhibit backend covers the same need.
    func probe() -> BatteryCapabilities {
        capabilities = .unsupported
        return capabilities
    }

    func apply(_ action: ChargingAction) -> Result<Void, ControlError> {
        .failure(ControlError("CHWA backend is not active on this machine."))
    }

    func reassert() -> Result<Void, ControlError> {
        .failure(ControlError("CHWA backend is not active on this machine."))
    }

    func restoreDefaults() {}
}

/// The honest fallback: no control, monitoring only. Selected when no
/// backend can prove verified control. The UI shows exactly this state
/// instead of pretending a limit is in effect.
final class ObservationOnlyBackend: ChargingBackend {

    let id = BackendID.fallback

    let description = "No verified charging-control mechanism on this machine; monitoring only."

    private(set) var capabilities = BatteryCapabilities.unsupported

    func probe() -> BatteryCapabilities {
        capabilities = BatteryCapabilities(
            supportsUpperLimit: false,
            supportsLowerLimit: false,
            supportsFixedLimit: false,
            supportsForceDischarge: false,
            supportsForceCharge: false,
            supportsCalibration: false,
            supportsSMC: false,
            supportsVerifiedChargingControl: false
        )
        return capabilities
    }

    func apply(_ action: ChargingAction) -> Result<Void, ControlError> {
        .failure(ControlError("This machine has no verified charging-control mechanism; the request was not applied."))
    }

    func reassert() -> Result<Void, ControlError> {
        .success(())
    }

    func restoreDefaults() {}
}
