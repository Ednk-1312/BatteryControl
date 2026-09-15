import BatteryCore
import Foundation

// BatteryControl privileged daemon.
//
// Runs as root under launchd. Enforces the user's charging policy forever —
// the app is just one client of this daemon; closing the app must never stop
// charge control.
//
// One-shot CLI modes (root required for SMC access):
//   --version                 print version
//   --probe-smc               read-only: check the SMC charge keys exist and
//                             print their current values. Never writes.
//   --test-inhibit            apply the charge inhibit, verify read-back and
//                             the observed battery state, then restore normal
//                             charging. For hardware validation.
//   --set-policy MODE U [L]   persist a policy to the root-owned store and
//                             exit. MODE: off | fixed | band.

let daemonLog = DaemonLog.self

setvbuf(stdout, nil, _IOLBF, 0)
umask(0o022)

private let usage = """
BatteryControl daemon \(BatteryXPC.expectedHelperVersion)
Usage:
  com.batterycontrol.daemon              run as the launchd service (default)
  com.batterycontrol.daemon --probe-smc  read-only SMC charge-key probe
  com.batterycontrol.daemon --test-inhibit
                                         apply + verify + restore the legacy charge
                                         inhibit (CH0B/CH0C — fails honestly on
                                         firmware without those keys)
  com.batterycontrol.daemon --test-pm   hardware-validate the power-assertion backend
  com.batterycontrol.daemon --hold-charge-inhibit N
                                         hold a ChargeInhibit assertion for N seconds (diagnostics)
  com.batterycontrol.daemon --hold-disable-inflow N
                                         hold a DisableInflow assertion for N seconds (diagnostics)
  com.batterycontrol.daemon --set-policy MODE UPPER [LOWER]
                                         persist a policy (off | fixed | band) and exit

Read-only firmware-limit diagnostics (root required to open the SMC):
  com.batterycontrol.daemon --diag-smc   report which control families this
                                         firmware exposes + current state
  com.batterycontrol.daemon --export-compat-report [path]
                                         write a privacy-safe JSON compatibility
                                         report (default /tmp/bc-compat-report.json)
  com.batterycontrol.daemon --read-firmware-limit
                                         print the bfF0/bfD0/bfE0 state

Firmware-limit write tests (change real hardware state, verify by readback):
  com.batterycontrol.daemon --program-firmware-limit U L [--experimental]
                                         program the firmware limit (U > L,
                                         both 5...100), verify, keep it.
                                         Blocked unless the machine's tier is
                                         verified/probable; --experimental
                                         overrides for supervised verification
                                         sessions only
  com.batterycontrol.daemon --disable-firmware-limit
                                         deactivate the firmware limit and
                                         restore normal charging
"""

private func fourCCToString(_ code: UInt32) -> String {
    let bytes = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

/// Read-only SMC probe. Never writes anything. Checks the primary charge-
/// control keys, then sweeps a list of candidate keys used by various
/// charge-control mechanisms across Apple Silicon generations so the report
/// shows what this firmware actually exposes.
private func runProbe() -> Int32 {
    print("Machine: \(PlatformDetector.detect().summaryLine)")
    do {
        try SMC.open()
    } catch {
        print("SMC: OPEN FAILED — \(error)")
        if case SMCError.notPrivileged = error {
            print("Hint: the probe must run as root (sudo) to talk to the SMC.")
        }
        return 1
    }
    defer { SMC.close() }
    print("SMC: connected")

    print("— Primary charge-control keys (SMC inhibit mechanism) —")
    let primaryKeys: [(FourCharCode, String)] = [
        (SMCChargeControl.inhibitB, "CH0B"),
        (SMCChargeControl.inhibitC, "CH0C"),
        (SMCChargeControl.adapterDisable, "CH0I"),
    ]
    var allPresent = true
    for (code, name) in primaryKeys {
        do {
            let info = try SMC.keyInfo(code)
            let value = try SMC.readBytes(code).0
            print("\(name): present, size=\(info.dataSize), type=\(fourCCToString(info.dataType)), value=\(value)")
        } catch SMCError.keyNotFound {
            allPresent = false
            print("\(name): MISSING (this firmware does not expose the key)")
        } catch {
            allPresent = false
            print("\(name): read error — \(error)")
        }
    }

    print("— Candidate key sweep (read-only; names used by charge-limit tools) —")
    let candidates = [
        "CH0A", "CH0D", "CH0E", "CH0F", "CH0H", "CH0J", "CH0K", "CH0L", "CH0M", "CH0N", "CH0P", "CH0S",
        "CHWA", "CHTE", "CHTC", "BCLM", "BFCL", "B0Ac", "ACEN", "ACLC", "ACFP", "ACID",
        "BSI ", "TB0T", "B0CT",
    ]
    var found: [String] = []
    for name in candidates {
        guard let code = FourCharCode(fromString: name) else { continue }
        if let info = try? SMC.keyInfo(code), info.dataSize > 0 {
            let value = (try? SMC.readBytes(code))?.0 ?? 0
            found.append(name)
            print("\(name): present, size=\(info.dataSize), type=\(fourCCToString(info.dataType)), firstByte=\(value)")
        }
    }
    if found.isEmpty {
        print("(none of the candidate keys responded)")
    }

    print("— Full key-table enumeration (read-only) —")
    if let count = try? SMC.keyCount() {
        print("SMC reports \(count) keys; enumerating…")
        var names: [(String, UInt32, UInt32)] = []
        for i in 0..<count {
            if let entry = try? SMC.key(atIndex: i) {
                names.append((fourCCToString(entry.key), entry.dataSize, entry.dataType))
            }
        }
        print("Enumerated \(names.count) keys.")
        // Charge-related families worth eyeballing in the dump.
        let interesting = names.filter { name, _, _ in
            name.hasPrefix("CH") || name.hasPrefix("AC") || name.hasPrefix("BC") || name.hasPrefix("BF")
                || name.contains("Adapt") || name.contains("CHRG") || name.contains("Chg")
        }
        print("— Charge/adapter-related keys —")
        if interesting.isEmpty {
            print("(none matched the charge/adapter heuristics)")
        } else {
            for (name, size, type) in interesting {
                var valueDesc = ""
                if let code = FourCharCode(fromString: name),
                   let bytes = try? SMC.readBytes(code) {
                    let list = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7]
                    valueDesc = " value=" + list.map { String(format: "%02x", $0) }.joined()
                }
                print("\(name): size=\(size), type=\(fourCCToString(type))\(valueDesc)")
            }
        }
        // Persist the full dump for offline analysis.
        let dumpPath = "/tmp/bc_smc_keydump.txt"
        let lines = names.map { "\($0.0)\tsize=\($0.1)\ttype=\(fourCCToString($0.2))" }.sorted()
        try? lines.joined(separator: "\n").write(toFile: dumpPath, atomically: true, encoding: .utf8)
        print("Full key list written to \(dumpPath) (\(lines.count) keys).")
    } else {
        print("Key-table enumeration not available on this SMC (#KEY read failed).")
    }

    if let readings = PlatformDetector.readBatteryFromIOKit() {
        print("Battery: \(readings.percentage)% charging=\(readings.isCharging) externalPower=\(readings.isExternalConnected) amperage=\(readings.amperageMA)mA cycleCount=\(readings.cycleCount)")
    } else {
        print("Battery: no internal battery detected")
    }
    print(allPresent ? "Result: all primary charge-control keys present." : "Result: primary keys missing — the SMC inhibit backend cannot work on this firmware; see the sweep above for alternatives.")
    return allPresent ? 0 : 2
}

/// Apply the charge inhibit, verify it at the SMC level and by observing the
/// battery state, then restore normal charging. Writes only CH0B/CH0C; the
/// adapter cut is never engaged by this test.
private func runInhibitTest() -> Int32 {
    print("Machine: \(PlatformDetector.detect().summaryLine)")
    guard let before = PlatformDetector.readBatteryFromIOKit() else {
        print("No internal battery detected — nothing to test.")
        return 1
    }
    print("Before: \(before.percentage)% charging=\(before.isCharging) externalPower=\(before.isExternalConnected)")

    print("Applying charge inhibit (CH0B/CH0C = 2)…")
    do {
        try SMCChargeControl.applyAndVerify(
            inhibit: SMCChargeControl.InhibitValue.inhibit,
            adapter: SMCChargeControl.AdapterValue.normal
        )
        print("SMC write verified: read-back matches the inhibit state.")
    } catch {
        print("FAILED: the SMC did not accept/verify the inhibit write — \(error)")
        _ = SMCChargeControl.releaseAdapter()
        _ = SMCChargeControl.setInhibit(false)
        return 1
    }

    // Give macOS a moment to reflect the change, then observe.
    print("Observing the battery state for ~15 seconds…")
    for _ in 0..<5 {
        Thread.sleep(forTimeInterval: 3)
        if let r = PlatformDetector.readBatteryFromIOKit() {
            print("  \(r.percentage)% charging=\(r.isCharging) externalPower=\(r.isExternalConnected) amperage=\(r.amperageMA)mA")
        }
    }

    print("Restoring normal charging…")
    let adapterOK = SMCChargeControl.releaseAdapter()
    let inhibitOK = SMCChargeControl.setInhibit(false)
    if let after = PlatformDetector.readBatteryFromIOKit() {
        print("After: \(after.percentage)% charging=\(after.isCharging) externalPower=\(after.isExternalConnected)")
    }
    let restored = adapterOK && inhibitOK
    print(restored ? "Restored: normal charging is active again." : "WARNING: restore path reported failure — check `--probe-smc` values are 0.")
    return restored ? 0 : 1
}

/// Hardware validation for the power-assertion backend: hold a ChargeInhibit
/// assertion while the adapter is connected and observe that the battery
/// stops charging, then release it and observe charging resume. Never holds
/// DisableInflow (no battery drain); the forced-discharge path is validated
/// by the engine's own verification during normal operation.
private func runPMAssertionTest() -> Int32 {
    print("Machine: \(PlatformDetector.detect().summaryLine)")
    guard let before = PlatformDetector.readBatteryFromIOKit() else {
        print("No internal battery detected — nothing to test.")
        return 1
    }
    print("Before: \(before.percentage)% charging=\(before.isCharging) externalPower=\(before.isExternalConnected)")
    guard before.isExternalConnected else {
        print("The Mac is on battery power. Connect the charger and re-run: the ChargeInhibit effect is only observable while AC power is connected.")
        return 1
    }
    guard !before.isCharging || before.percentage < 100 else {
        print("The battery is full and not charging; there is no charging activity to inhibit. Discharge a little below 100% and re-run.")
        return 1
    }

    let backend = PMAssertionBackend()
    print("Probing the power-assertion backend…")
    let caps = backend.probe()
    guard caps.supportsVerifiedChargingControl else {
        print("FAILED: the power-assertion backend reported no verified control on this machine (see probe output).")
        return 1
    }
    print("Probe OK: powerd accepts and releases ChargeInhibit assertions.")

    print("Holding ChargeInhibit (charging paused, system stays on AC power)…")
    guard case .success = backend.apply(.inhibitCharging) else {
        print("FAILED: could not apply the ChargeInhibit assertion.")
        backend.restoreDefaults()
        return 1
    }

    print("Observing the battery state for ~20 seconds…")
    var sawNotCharging = false
    for _ in 0..<5 {
        Thread.sleep(forTimeInterval: 4)
        if let r = PlatformDetector.readBatteryFromIOKit() {
            print("  \(r.percentage)% charging=\(r.isCharging) externalPower=\(r.isExternalConnected) amperage=\(r.amperageMA)mA")
            if r.isExternalConnected && !r.isCharging { sawNotCharging = true }
        }
    }

    print("Releasing the assertion (normal charging resumes)…")
    backend.restoreDefaults()

    print("Observing the resumed state for ~12 seconds…")
    var sawResumed = false
    for _ in 0..<3 {
        Thread.sleep(forTimeInterval: 4)
        if let r = PlatformDetector.readBatteryFromIOKit() {
            print("  \(r.percentage)% charging=\(r.isCharging) externalPower=\(r.isExternalConnected) amperage=\(r.amperageMA)mA")
            if r.isCharging || r.percentage >= 100 { sawResumed = true }
        }
    }

    if sawNotCharging && sawResumed {
        print("Result: SUCCESS — charging paused while the assertion was held and resumed after release.")
        return 0
    }
    if !sawNotCharging {
        print("Result: UNVERIFIED — the battery kept charging while the ChargeInhibit assertion was held. The gauge can lag; re-run before drawing conclusions, and check `pmset -g assertions` for the assertion while it is held.")
    } else {
        print("Result: PARTIAL — charging paused correctly but the resumed state was not observed (battery may be near full, which is benign).")
        return 0
    }
    return 1
}

/// Persist a policy to the root-owned store and exit. Lets the policy be
/// seeded before the service starts, and doubles as a CLI for scripting.
private func runSetPolicy(_ args: [String]) -> Int32 {
    // `off` needs no numeric arguments; band/fixed require an upper value.
    guard let mode = args.first else {
        print(usage)
        return 2
    }
    let policy: ChargingPolicy
    switch mode {
    case "off":
        policy = .passthrough()
    case "fixed":
        guard args.count >= 2, let upper = Int(args[1]) else {
            print(usage)
            return 2
        }
        policy = ChargingPolicy(mode: .fixedTarget, upperLimit: upper, lowerLimit: 0)
    case "band":
        guard args.count >= 3, let upper = Int(args[1]), let lower = Int(args[2]) else {
            print(usage)
            return 2
        }
        policy = ChargingPolicy.sanitized(upper: upper, lower: lower)
    default:
        print(usage)
        return 2
    }
    if let problem = ControlModeHelpers.validate(policy) {
        print("Rejected: \(problem)")
        return 2
    }
    let store = PolicyStore()
    store.update { $0.policy = policy }
    print("Policy persisted: \(policy.summary)")
    print("The running daemon picks it up within one tick (\(Int(RecoveryDecisions.tickIntervalSeconds))s); restart the service to apply immediately.")
    return 0
}

/// Read-only capability + state report: which SMC control families this
/// firmware exposes, which adapter-cut keys exist, and the current
/// firmware-limit values. Never writes.
private func runSMCDiagnostics() -> Int32 {
    print("Machine: \(PlatformDetector.detect().summaryLine)")
    do {
        try SMC.open()
    } catch {
        print("SMC: OPEN FAILED — \(error)")
        if case SMCError.notPrivileged = error {
            print("Hint: the probe must run as root (sudo) to talk to the SMC.")
        }
        return 1
    }
    defer { SMC.close() }
    print("SMC: connected")

    func line(_ name: String, _ key: FourCharCode, kind: String) {
        // Existence via direct read: metadata (keyInfo) is unpopulated
        // (size 0) on current firmware even for live keys.
        if SMCChargeControl.keyUsable(key) {
            let info = try? SMC.keyInfo(key)
            let bytes = (try? SMC.readBytes(key)) ?? (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            let list = [bytes.0, bytes.1, bytes.2, bytes.3].map { String(format: "%02x", $0) }.joined(separator: " ")
            let typeDesc = (info?.dataSize ?? 0) > 0 ? "size=\(info!.dataSize), type=\(fourCCToString(info!.dataType))" : "size=<unpopulated>"
            print("  \(name) [\(kind)]: present, \(typeDesc), value=\(list)")
        } else {
            print("  \(name) [\(kind)]: absent")
        }
    }

    let family = SMCChargeControl.detectFamily()
    print("— Charging-control keys —")
    line("CH0B", SMCChargeControl.inhibitB, kind: "legacy inhibit")
    line("CH0C", SMCChargeControl.inhibitC, kind: "legacy inhibit")
    line("CHTE", SMCChargeControl.inhibitT, kind: "Tahoe inhibit (ui32)")
    line("CH0I", SMCChargeControl.adapterDisable, kind: "legacy adapter cut")
    line("CH0J", SMCChargeControl.adapterJ, kind: "adapter cut")
    line("CHIE", SMCChargeControl.adapterE, kind: "Tahoe adapter cut")
    print("— Firmware-managed charge limit —")
    line("bfF0", FirmwareLimitKeys.activation, kind: "activate (ui8)")
    line("bfD0", FirmwareLimitKeys.upper, kind: "upper % (ui32 LE)")
    line("bfE0", FirmwareLimitKeys.lower, kind: "lower % (ui32 LE)")

    print("— Detected control family: \(String(describing: family))")
    switch family {
    case .firmwareLimit:
        print("  → firmware-managed limit backend available; adapter cut via \(SMCChargeControl.adapterKey(for: family).map { fourCCString($0.key) } ?? "none")")
    case .legacy:
        print("  → SMC inhibit backend (CH0B/CH0C + CH0I) available")
    case .legacyTahoe:
        print("  → SMC inhibit backend (CHTE + CHIE) available")
    case .none:
        print("  → no charging-control mechanism detected on this firmware")
    }

    // Confidence tier from the firmware compatibility library.
    let identity = PlatformDetector.detect()
    let detected: FirmwareProfileLibrary.DetectedFamily
    switch family {
    case .firmwareLimit: detected = .firmwareLimit
    case .legacy: detected = .legacy
    case .legacyTahoe: detected = .legacyTahoe
    case .none: detected = .none
    }
    let tier = FirmwareProfileLibrary.classify(
        identity: identity,
        detectedFamily: detected,
        systemFirmwareBuild: identity.systemFirmwareBuild
    )
    print("— Firmware profile tier: \(tier.rawValue)")
    print("  \(FirmwareProfileLibrary.summary(for: tier, identity: identity, detectedFamily: detected))")
    if let fw = identity.systemFirmwareBuild {
        print("  System firmware: mBoot-\(fw)")
    }

    if let readings = PlatformDetector.readBatteryFromIOKit() {
        print("Battery: \(readings.percentage)% charging=\(readings.isCharging) externalPower=\(readings.isExternalConnected) amperage=\(readings.amperageMA)mA cycleCount=\(readings.cycleCount)")
    }
    return family == .none ? 2 : 0
}

/// Privacy-safe compatibility-research export. Contains hardware identity,
/// firmware builds, and the runtime SMC capability signature — NO serial
/// numbers, hardware UUIDs, user names, or paths. Read-only: never writes
/// to the SMC.
private func runExportCompatReport(_ args: [String]) -> Int32 {
    struct CompatReport: Codable {
        var reportVersion: Int
        var generatedAt: String
        var hardware: [String: String]
        var smcCapabilitySignature: [String: String]
        var detectedControlFamily: String
        var firmwareProfileTier: String
        var profileNotes: [String]
    }

    print("Machine: \(PlatformDetector.detect().summaryLine)")
    do {
        try SMC.open()
    } catch {
        print("SMC: OPEN FAILED — \(error)")
        return 1
    }
    defer { SMC.close() }

    let identity = PlatformDetector.detect()
    func keyLine(_ name: String, _ key: FourCharCode) -> String {
        if SMCChargeControl.keyUsable(key) {
            let bytes = (try? SMC.readBytes(key)) ?? (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            let hex = [bytes.0, bytes.1, bytes.2, bytes.3].map { String(format: "%02x", $0) }.joined()
            return "present:\(hex)"
            // Note: the raw 4 bytes of battery-TELEMETRY keys are not
            // identifiers; the exported keys are control keys only, and the
            // hex is included only to show live vs zero state.
        }
        return "absent"
    }
    let signature: [String: String] = [
        "CH0B": keyLine("CH0B", SMCChargeControl.inhibitB),
        "CH0C": keyLine("CH0C", SMCChargeControl.inhibitC),
        "CHTE": keyLine("CHTE", SMCChargeControl.inhibitT),
        "CH0I": keyLine("CH0I", SMCChargeControl.adapterDisable),
        "CH0J": keyLine("CH0J", SMCChargeControl.adapterJ),
        "CHIE": keyLine("CHIE", SMCChargeControl.adapterE),
        "bfF0": keyLine("bfF0", FirmwareLimitKeys.activation),
        "bfD0": keyLine("bfD0", FirmwareLimitKeys.upper),
        "bfE0": keyLine("bfE0", FirmwareLimitKeys.lower),
    ]

    let detected: FirmwareProfileLibrary.DetectedFamily
    switch SMCChargeControl.detectFamily() {
    case .firmwareLimit: detected = .firmwareLimit
    case .legacy: detected = .legacy
    case .legacyTahoe: detected = .legacyTahoe
    case .none: detected = .none
    }
    let tier = FirmwareProfileLibrary.classify(
        identity: identity,
        detectedFamily: detected,
        systemFirmwareBuild: identity.systemFirmwareBuild
    )
    let detectedFamilyName: String
    switch detected {
    case .firmwareLimit: detectedFamilyName = "firmwareLimit"
    case .legacy: detectedFamilyName = "legacy"
    case .legacyTahoe: detectedFamilyName = "legacyTahoe"
    case .none: detectedFamilyName = "none"
    }

    let report = CompatReport(
        reportVersion: 1,
        generatedAt: ISO8601DateFormatter().string(from: Date()),
        hardware: [
            "chip": identity.chipGeneration?.rawValue ?? "unknown",
            "modelIdentifier": identity.macModelIdentifier,
            "osVersion": "\(identity.osMajor).\(identity.osMinor).\(identity.osPatch)",
            "osBuild": identity.osBuild,
            "systemFirmwareBuild": identity.systemFirmwareBuild ?? "unknown",
        ],
        smcCapabilitySignature: signature,
        detectedControlFamily: String(describing: detected),
        firmwareProfileTier: tier.rawValue,
        profileNotes: FirmwareProfileLibrary.all
            .filter { $0.controlFamily == detectedFamilyName }
            .map { $0.id },
    )

    // Serialize with sorted keys for diffability.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(report) else {
        print("FAILED to serialize the report.")
        return 1
    }
    let path = args.first ?? "/tmp/bc-compat-report.json"
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("Compatibility report written to \(path)")
        print(String(data: data, encoding: .utf8) ?? "")
        return 0
    } catch {
        print("FAILED to write \(path): \(error)")
        return 1
    }
}

/// Read-only firmware-limit state dump.
private func runReadFirmwareLimit() -> Int32 {
    let backend = FirmwareLimitBackend()
    print("Machine: \(PlatformDetector.detect().summaryLine)")
    switch backend.readState() {
    case .success(let s):
        let activationByte = (try? SMC.open()) != nil ? ((try? SMC.readBytes(FirmwareLimitKeys.activation).0) ?? 0) : 0
        print("Firmware limit: active=\(s.active) upper=\(s.upperPercent)% lower=\(s.lowerPercent)% (activation byte=0x\(String(activationByte, radix: 16)))")
        if s.active {
            print("The firmware is enforcing this limit right now (independently of any daemon).")
        } else {
            print("The firmware limit is disabled; macOS default charging is in effect.")
        }
        return 0
    case .failure(let err):
        print("FAILED to read the firmware-limit state: \(err.message)")
        print("This usually means the bf* keys are absent on this firmware.")
        return 1
    }
}

/// Program a firmware-managed charge limit with the full safety chain:
/// validation, pre-readback, required write order, post-readback verify,
/// automatic deactivation on failure. Leaves the limit ACTIVE (that is the
/// point of the test); pair with --disable-firmware-limit to undo.
private var allowExperimental = false

private func detectedFamilyForCLI() -> FirmwareProfileLibrary.DetectedFamily {
    do { try SMC.open() } catch { return .none }
    defer { SMC.close() }
    switch SMCChargeControl.detectFamily() {
    case .firmwareLimit: return .firmwareLimit
    case .legacy: return .legacy
    case .legacyTahoe: return .legacyTahoe
    case .none: return .none
    }
}

private func runProgramFirmwareLimit(_ args: [String]) -> Int32 {
    let positional = args.filter { !$0.hasPrefix("--") }
    allowExperimental = args.contains("--experimental")
    guard positional.count >= 2, let upper = Int(positional[0]), let lower = Int(positional[1]) else {
        print(usage)
        return 2
    }
    print("Machine: \(PlatformDetector.detect().summaryLine)")
    print("*** TEST MODE — this programs the firmware-managed charge limit for manual ***")
    print("*** verification. It is not the app's permanent configuration.             ***")
    if let problem = FirmwareLimitValidation.problem(upper: upper, lower: lower) {
        print("Rejected: \(problem)")
        return 2
    }

    // Compatibility gate: the live CLI write test is for hardware-verification
    // sessions. On tiers without evidence it stays locked behind an explicit
    // experimental flag so unknown firmware never receives speculative writes.
    let identity = PlatformDetector.detect()
    let tier = FirmwareProfileLibrary.classify(
        identity: identity,
        detectedFamily: detectedFamilyForCLI(),
        systemFirmwareBuild: identity.systemFirmwareBuild
    )
    if !FirmwareProfileLibrary.shouldAllowControlWrites(tier) && !allowExperimental {
        print("BLOCKED: this machine's firmware is classified \(tier.rawValue); control writes are disabled.")
        print("The write test runs only after a hardware-verification session adds the profile (see CONTRIBUTING.md),")
        print("or right now with --experimental to override for a supervised verification session.")
        return 3
    }
    guard let readings = PlatformDetector.readBatteryFromIOKit() else {
        print("No internal battery detected — nothing to test.")
        return 1
    }
    print("Before: \(readings.percentage)% charging=\(readings.isCharging) externalPower=\(readings.isExternalConnected)")

    let backend = FirmwareLimitBackend()
    print("Probing the firmware-limit keys…")
    let caps = backend.probe()
    guard caps.supportsVerifiedChargingControl else {
        print("FAILED: the firmware-limit backend reports no control capability on this machine (keys absent or wrong shape).")
        return 1
    }
    print("Probe OK: bfF0/bfD0/bfE0 present with correct types.")

    print("Programming firmware limit: upper=\(upper)% lower=\(lower)%…")
    switch backend.programLimit(upper: upper, lower: lower) {
    case .success:
        print("VERIFIED: the firmware accepted and confirmed the limit (upper=\(upper)%, lower=\(lower)%).")
        print("The SMC now enforces it autonomously — check charging behavior over the next charge cycle.")
        print("To undo: com.batterycontrol.daemon --disable-firmware-limit")
        return 0
    case .failure(let err):
        print("FAILED: \(err.message)")
        if err.isVerificationFailure {
            print("The write was accepted but the readback did not match; the limit was deactivated for safety.")
        }
        return 1
    }
}

/// Deactivate the firmware-managed charge limit and confirm by readback.
private func runDisableFirmwareLimit() -> Int32 {
    print("Machine: \(PlatformDetector.detect().summaryLine)")
    let backend = FirmwareLimitBackend()
    switch backend.readState() {
    case .success(let s) where !s.active:
        print("Already disabled (active=0). Nothing to do.")
        return 0
    case .failure(let err):
        print("FAILED to read the firmware-limit state: \(err.message)")
        return 1
    default:
        break
    }
    print("Deactivating the firmware limit…")
    do {
        try SMC.open()
        try SMC.writeUInt8(FirmwareLimitKeys.activation, value: 0x00)
    } catch {
        print("FAILED: \(error)")
        return 1
    }
    // Confirm by readback.
    for _ in 0..<3 {
        Thread.sleep(forTimeInterval: 0.2)
        if case .success(let s) = backend.readState(), !s.active {
            print("VERIFIED: the firmware limit is deactivated (activation byte=0x00); normal charging restored.")
            return 0
        }
    }
    print("FAILED: the deactivation write did not verify — inspect with --read-firmware-limit.")
    return 1
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())

if let flag = arguments.first {
    switch flag {
    case "--version":
        print(BatteryXPC.expectedHelperVersion)
        exit(0)
    case "--probe-smc":
        exit(runProbe())
    case "--test-inhibit":
        exit(runInhibitTest())
    case "--diag-smc":
        exit(runSMCDiagnostics())
    case "--export-compat-report":
        exit(runExportCompatReport(Array(arguments.dropFirst())))
    case "--read-firmware-limit":
        exit(runReadFirmwareLimit())
    case "--program-firmware-limit":
        DaemonLog.bootstrap()
        // Load the distributable compatibility database before any write
        // decision (missing file = built-in profiles only; a parse failure is
        // acceptable here — the engine falls back to built-in profiles).
        _ = try? FirmwareProfileLibrary.loadDatabase(atPath: BatteryXPC.compatibilityDatabasePath)
        exit(runProgramFirmwareLimit(Array(arguments.dropFirst())))
    case "--disable-firmware-limit":
        DaemonLog.bootstrap()
        exit(runDisableFirmwareLimit())
    case "--test-pm":
        exit(runPMAssertionTest())
    case "--hold-charge-inhibit", "--hold-disable-inflow":
        guard arguments.count >= 2, let seconds = TimeInterval(arguments[1]), seconds > 0, seconds <= 600 else {
            print(usage)
            exit(2)
        }
        let kind = flag == "--hold-charge-inhibit" ? "ChargeInhibit" : "DisableInflow"
        print("Holding a \(kind) assertion for \(Int(seconds))s (pid \(getpid()))…")
        var assertionID = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            kind as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "BatteryControl diagnostic hold" as CFString,
            &assertionID
        )
        guard status == kIOReturnSuccess, assertionID != 0 else {
            print("FAILED to create the assertion: IOReturn \(status)")
            exit(1)
        }
        print("Assertion id \(assertionID) created. Inspect with: pmset -g assertions | grep -i inhibit")
        Thread.sleep(forTimeInterval: seconds)
        let released = IOPMAssertionRelease(assertionID) == kIOReturnSuccess
        print(released ? "Assertion released." : "WARNING: release failed (IOReturn).")
        exit(released ? 0 : 1)
    case "--set-policy":
        DaemonLog.bootstrap()
        exit(runSetPolicy(Array(arguments.dropFirst())))
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        print(usage)
        exit(2)
    }
}

// Service mode below. Restore hardware defaults on any exit path: a stuck
// adapter cut (CH0I) would keep draining the battery after shutdown.
atexit {
    SMCChargeControl.releaseAllAdaptersIfNeeded()
    SMCChargeControl.setInhibit(false)
}

signal(SIGINT, { _ in exit(0) })   // launchd stop → run exit handlers
signal(SIGTERM, { _ in exit(0) })
signal(SIGHUP, SIG_IGN)

DaemonLog.bootstrap()
DaemonLog.info("BatteryControl daemon starting (version \(BatteryXPC.expectedHelperVersion)).", operation: "startup")

// Compatibility database: distributable JSON overriding/extending the
// built-in profiles (missing file = built-ins only; invalid entries are
// logged and skipped, never fatal — safety logic uses built-in fallbacks).
do {
    let loaded = try FirmwareProfileLibrary.loadDatabase(atPath: BatteryXPC.compatibilityDatabasePath)
    if loaded > 0 {
        DaemonLog.info("Compatibility database: \(loaded) profile(s) loaded from \(BatteryXPC.compatibilityDatabasePath).", operation: "startup")
    }
} catch {
    DaemonLog.warning("Compatibility database at \(BatteryXPC.compatibilityDatabasePath) could not be loaded (\(error)); using built-in profiles.", operation: "startup")
}

// Platform gate: refuse to touch hardware outside M1–M4 / macOS 15.
let platform = PlatformDetector.detect()
guard platform.isSupportedPlatform else {
    DaemonLog.error(
        "Unsupported platform (\(platform.summaryLine)): \(PlatformIdentity.unsupportedMessage)",
        operation: "startup"
    )
    // Keep running as observation-only so status reads work, but never
    // select a control backend.
    let store = PolicyStore()
    let engine = ControlEngine.unsupportedPlatform(store: store, platform: platform)
    let server = DaemonXPCServer(engine: engine)
    server.run()
    dispatchMain()
}

let store = PolicyStore()
let engine = ControlEngine(store: store)
let monitor = EventMonitor(engine: engine)
monitor.start()

// Primary enforcement tick.
let tickTimer = DispatchSource.makeTimerSource(queue: engine.engineQueue)
tickTimer.schedule(deadline: .now() + 1,
                   repeating: RecoveryDecisions.tickIntervalSeconds)
tickTimer.setEventHandler { engine.tick(reason: .policyTick) }
tickTimer.resume()

let server = DaemonXPCServer(engine: engine)
server.run()

DaemonLog.info("Daemon ready: \(platform.summaryLine).", operation: "startup")
dispatchMain()
