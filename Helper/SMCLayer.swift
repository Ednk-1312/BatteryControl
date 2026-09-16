import Foundation

#if canImport(IOKit)
import IOKit
#endif

// Minimal Apple SMC (System Management Controller) client.
//
// Adapted from SMCKit (MIT License, github.com/beltex/SMCKit), via the
// battery-limiter project (MIT, github.com/MlayKlayer/battery-limiter),
// trimmed to the single-byte read/write path needed for the charge-control
// keys on Apple Silicon. Writing requires the calling process to be root.
// See ATTRIBUTION.md for license text.

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

enum SMCError: Error, Equatable {
    case driverNotFound
    case failedToOpen
    case keyNotFound
    case notPrivileged
    case invalidDataSize(key: FourCharCode, expected: Int, actual: Int)
    case unknown(kIOReturn: kern_return_t, smcResult: UInt8)
}

extension FourCharCode {
    init(fromStaticString str: StaticString) {
        precondition(str.utf8CodeUnitCount == 4)
        self = str.withUTF8Buffer { buffer in
            (UInt32(buffer[0]) << 24) | (UInt32(buffer[1]) << 16) | (UInt32(buffer[2]) << 8) | UInt32(buffer[3])
        }
    }

    /// Runtime variant for probe sweeps: accepts any 4-character ASCII name.
    init?(fromString str: String) {
        let utf8 = Array(str.utf8)
        guard utf8.count == 4, utf8.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        self = (UInt32(utf8[0]) << 24) | (UInt32(utf8[1]) << 16) | (UInt32(utf8[2]) << 8) | UInt32(utf8[3])
    }
}

private struct SMCParamStruct {
    enum Selector: UInt8 {
        case kSMCHandleYPCEvent = 2
        case kSMCReadKey = 5
        case kSMCWriteKey = 6
        case kSMCGetKeyFromIndex = 8
    }

    enum Result: UInt8 {
        case kSMCSuccess = 0
        case kSMCKeyNotFound = 132
    }

    struct SMCVersion {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

/// Talks to the AppleSMC IOKit user client. The connection is long-lived;
/// a stale handle is recovered by reopening on the next call.
enum SMC {
    /// Serializes ALL user-client access. The connection handle is a single
    /// shared resource used from the engine queue, XPC handler threads, and
    /// probe paths; concurrent IOConnectCallStructMethod calls on one handle
    /// — or a close() racing a call — can crash the process mid-write.
    /// Every public operation holds the lock for its full duration; internal
    /// `...Locked` helpers assume it is already held.
    private static let lock = NSLock()
    private static var connection: io_connect_t = 0
    private static var opened = false

    static func open() throws {
        lock.lock()
        defer { lock.unlock() }
        try openLocked()
    }

    static func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    private static func openLocked() throws {
        guard !opened else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.driverNotFound }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { throw SMCError.failedToOpen }
        opened = true
    }

    private static func closeLocked() {
        if opened {
            _ = IOServiceClose(connection)
            connection = 0
            opened = false
        }
    }

    static func readBytes(_ key: FourCharCode) throws -> SMCBytes {
        lock.lock()
        defer { lock.unlock() }
        try openIfNeededLocked()
        return try readBytesLocked(key)
    }

    private static func readBytesLocked(_ key: FourCharCode) throws -> SMCBytes {
        var input = SMCParamStruct()
        input.key = key
        input.data8 = SMCParamStruct.Selector.kSMCReadKey.rawValue
        input.keyInfo.dataSize = 32
        let output = try callLocked(&input)
        return output.bytes
    }

    static func keyInfo(_ key: FourCharCode) throws -> (dataSize: UInt32, dataType: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        try openIfNeededLocked()
        return try keyInfoLocked(key)
    }

    private static func keyInfoLocked(_ key: FourCharCode) throws -> (dataSize: UInt32, dataType: UInt32) {
        var input = SMCParamStruct()
        input.key = key
        input.data8 = SMCParamStruct.Selector.kSMCReadKey.rawValue
        input.keyInfo.dataSize = 32
        let output = try callLocked(&input)
        return (output.keyInfo.dataSize, output.keyInfo.dataType)
    }

    /// Typed uint32 read: decodes big-endian (the conventional SMC ui32
    /// representation). The declared width is enforced only when the firmware
    /// populates key metadata; on firmware with unpopulated metadata (size 0
    /// for existing keys) the read itself decides.
    static func readUInt32(_ key: FourCharCode) throws -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        try openIfNeededLocked()
        let info = try? keyInfoLocked(key)
        if let info, info.dataSize != 0, info.dataSize != 4 {
            throw SMCError.invalidDataSize(key: key, expected: 4, actual: Int(info.dataSize))
        }
        let bytes = try readBytesLocked(key)
        return UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16
            | UInt32(bytes.2) << 8 | UInt32(bytes.3)
    }

    /// Little-endian uint32 read (used by the firmware-limit keys, which
    /// store percentages in the non-conventional byte order).
    static func readUInt32LE(_ key: FourCharCode) throws -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        try openIfNeededLocked()
        let info = try? keyInfoLocked(key)
        if let info, info.dataSize != 0, info.dataSize != 4 {
            throw SMCError.invalidDataSize(key: key, expected: 4, actual: Int(info.dataSize))
        }
        let bytes = try readBytesLocked(key)
        return UInt32(bytes.3) << 24 | UInt32(bytes.2) << 16
            | UInt32(bytes.1) << 8 | UInt32(bytes.0)
    }

    /// Typed uint32 write (big-endian). Width is enforced only when the
    /// firmware populates key metadata; the SMC itself validates on write.
    static func writeUInt32(_ key: FourCharCode, value: UInt32) throws {
        lock.lock()
        defer { lock.unlock() }
        try openIfNeededLocked()
        let info = try? keyInfoLocked(key)
        if let info, info.dataSize != 0, info.dataSize != 4 {
            throw SMCError.invalidDataSize(key: key, expected: 4, actual: Int(info.dataSize))
        }
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = 4
        input.data8 = SMCParamStruct.Selector.kSMCWriteKey.rawValue
        input.bytes.0 = UInt8((value >> 24) & 0xFF)
        input.bytes.1 = UInt8((value >> 16) & 0xFF)
        input.bytes.2 = UInt8((value >> 8) & 0xFF)
        input.bytes.3 = UInt8(value & 0xFF)
        _ = try callLocked(&input)
    }

    /// Little-endian uint32 write (firmware-limit keys).
    static func writeUInt32LE(_ key: FourCharCode, value: UInt32) throws {
        lock.lock()
        defer { lock.unlock() }
        try openIfNeededLocked()
        let info = try? keyInfoLocked(key)
        if let info, info.dataSize != 0, info.dataSize != 4 {
            throw SMCError.invalidDataSize(key: key, expected: 4, actual: Int(info.dataSize))
        }
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = 4
        input.data8 = SMCParamStruct.Selector.kSMCWriteKey.rawValue
        input.bytes.0 = UInt8(value & 0xFF)
        input.bytes.1 = UInt8((value >> 8) & 0xFF)
        input.bytes.2 = UInt8((value >> 16) & 0xFF)
        input.bytes.3 = UInt8((value >> 24) & 0xFF)
        _ = try callLocked(&input)
    }

    static func writeUInt8(_ key: FourCharCode, value: UInt8) throws {
        lock.lock()
        defer { lock.unlock() }
        try openIfNeededLocked()
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = 1
        input.data8 = SMCParamStruct.Selector.kSMCWriteKey.rawValue
        input.bytes.0 = value
        _ = try callLocked(&input)
    }

    /// Total number of keys the SMC exposes. Reads the special "#KEY" key.
    static func keyCount() throws -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        try openIfNeededLocked()
        var input = SMCParamStruct()
        input.key = FourCharCode(fromStaticString: "#KEY")
        input.data8 = SMCParamStruct.Selector.kSMCReadKey.rawValue
        input.keyInfo.dataSize = 4
        let output = try callLocked(&input)
        return UInt32(output.bytes.0) << 24 | UInt32(output.bytes.1) << 16
            | UInt32(output.bytes.2) << 8 | UInt32(output.bytes.3)
    }

    /// Key at a table index (kSMCGetKeyFromIndex). Used for full-key-table
    /// enumeration in the diagnostics probe.
    static func key(atIndex index: UInt32) throws -> (key: FourCharCode, dataSize: UInt32, dataType: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        try openIfNeededLocked()
        var input = SMCParamStruct()
        input.data8 = SMCParamStruct.Selector.kSMCGetKeyFromIndex.rawValue
        input.data32 = index
        let output = try callLocked(&input)
        return (output.key, output.keyInfo.dataSize, output.keyInfo.dataType)
    }

    private static func openIfNeededLocked() throws {
        do {
            try openLocked()
        } catch {
            // Retry once from a cold connection.
            closeLocked()
            try openLocked()
        }
    }

    @discardableResult
    private static func callLocked(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        assert(MemoryLayout<SMCParamStruct>.stride == 80, "SMCParamStruct size is != 80")
        var output = SMCParamStruct()
        let inSize = MemoryLayout<SMCParamStruct>.stride
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection,
            UInt32(SMCParamStruct.Selector.kSMCHandleYPCEvent.rawValue),
            &input, inSize,
            &output, &outSize
        )
        switch (result, output.result) {
        case (kIOReturnSuccess, SMCParamStruct.Result.kSMCSuccess.rawValue):
            return output
        case (kIOReturnSuccess, SMCParamStruct.Result.kSMCKeyNotFound.rawValue):
            throw SMCError.keyNotFound
        case (kIOReturnNotPrivileged, _):
            closeLocked()
            throw SMCError.notPrivileged
        default:
            throw SMCError.unknown(kIOReturn: result, smcResult: output.result)
        }
    }
}

/// Apple Silicon charge-control keys. CH0B/CH0C set to 2 stop charging
/// without discharging; 0 restores normal charging (semantics derived from
/// the MIT-licensed BatFi implementation, as documented by battery-limiter).
/// CH0I set to 1 cuts adapter input so the Mac runs off the battery even
/// while plugged in; 0 restores it. Writing requires root.
///
/// Every write must be verified by reading the key back — an accepted write
/// is not proof the firmware honored it (some firmware applies writes
/// asynchronously, per smctl's field notes).
enum SMCChargeControl {

    static let inhibitB = FourCharCode(fromStaticString: "CH0B")
    static let inhibitC = FourCharCode(fromStaticString: "CH0C")
    static let adapterDisable = FourCharCode(fromStaticString: "CH0I")
    /// Tahoe-era charging key (ui32): first byte 0x01 = inhibit, 0x00 = normal.
    static let inhibitT = FourCharCode(fromStaticString: "CHTE")
    /// Newer adapter-cut key (same 0/1 semantics as CH0I).
    static let adapterJ = FourCharCode(fromStaticString: "CH0J")
    /// Tahoe-era adapter key: cut value is 0x08, not 0x01 (per the batt
    /// project's documented adapter semantics — behavior reference only).
    static let adapterE = FourCharCode(fromStaticString: "CHIE")

    enum InhibitValue {
        static let normal: UInt8 = 0
        static let inhibit: UInt8 = 2
    }

    enum AdapterValue {
        static let normal: UInt8 = 0
        static let cut: UInt8 = 1
        /// CHIE's cut value differs from CH0I/CH0J.
        static let cutForCHIE: UInt8 = 8
    }

    /// Which SMC key family this machine exposes for charging control.
    /// Detected from key presence at probe time (with placeholder keys —
    /// size 0 — treated as absent), never from the OS version.
    enum Family: Equatable {
        /// CH0B + CH0C inhibit, CH0I adapter cut (classic Apple Silicon).
        case legacy
        /// CHTE inhibit (ui32), CHIE adapter cut (Tahoe-era firmware).
        case legacyTahoe
        /// bfF0/bfD0/bfE0 firmware-managed limit (modern firmware).
        case firmwareLimit
        /// Nothing usable.
        case none
    }

    /// A key exists and is usable. Some firmware (validated on M3 / 15.8)
    /// reports size-0 metadata from keyInfo for keys that are fully
    /// readable, so metadata alone cannot decide presence: a keyNotFound
    /// error means absent, while a successful direct read confirms the key
    /// even when its metadata is unpopulated.
    static func keyUsable(_ key: FourCharCode) -> Bool {
        do {
            let info = try SMC.keyInfo(key)
            if info.dataSize > 0 { return true }
            // Metadata unpopulated (size 0): decide by attempting a read.
            _ = try SMC.readBytes(key)
            return true
        } catch SMCError.keyNotFound {
            return false
        } catch {
            // keyInfo failed outright; fall back to a direct read.
            return (try? SMC.readBytes(key)) != nil
        }
    }

    /// Detect which control family this firmware exposes. Firmware limit
    /// wins over legacy keys when both are present (the firmware mechanism
    /// is enforced by the SMC itself and is strictly more capable).
    static func detectFamily() -> Family {
        if keyUsable(FirmwareLimitKeys.activation),
           keyUsable(FirmwareLimitKeys.upper),
           keyUsable(FirmwareLimitKeys.lower) {
            return .firmwareLimit
        }
        if keyUsable(inhibitB) && keyUsable(inhibitC) && keyUsable(adapterDisable) {
            return .legacy
        }
        if keyUsable(inhibitT) && keyUsable(adapterE) {
            return .legacyTahoe
        }
        return .none
    }

    /// The adapter-cut key for a family, with its cut value.
    static func adapterKey(for family: Family) -> (key: FourCharCode, cut: UInt8)? {
        switch family {
        case .legacy: return (adapterDisable, AdapterValue.cut)
        case .legacyTahoe: return (adapterE, AdapterValue.cutForCHIE)
        case .firmwareLimit, .none: return findAdapterCutKey()
        }
    }

    /// Adapter-cut key discovery independent of the charging family: the
    /// modern firmware-limit Macs still expose an adapter-cut key (CH0I,
    /// CH0J, or CHIE) even though the inhibit keys are gone. Preference:
    /// CHIE (Tahoe-era, cut = 0x08), then CH0J, then CH0I (cut = 0x01).
    static func findAdapterCutKey() -> (key: FourCharCode, cut: UInt8)? {
        if keyUsable(adapterE) { return (adapterE, AdapterValue.cutForCHIE) }
        if keyUsable(adapterJ) { return (adapterJ, AdapterValue.cut) }
        if keyUsable(adapterDisable) { return (adapterDisable, AdapterValue.cut) }
        return nil
    }

    /// Apply inhibit + adapter state through a specific family, then verify
    /// by reading the keys back. Throws when the write did not stick.
    static func applyAndVerify(family: Family, inhibit: Bool, cutAdapter: Bool) throws {
        try SMC.open()
        switch family {
        case .legacy:
            try applyAndVerify(
                inhibit: inhibit ? InhibitValue.inhibit : InhibitValue.normal,
                adapter: cutAdapter ? AdapterValue.cut : AdapterValue.normal
            )
        case .legacyTahoe:
            try writeCHTE(inhibited: inhibit)
            guard writeAdapter(adapterE, value: cutAdapter ? AdapterValue.cutForCHIE : AdapterValue.normal) else {
                throw SMCError.unknown(kIOReturn: -3, smcResult: 0)
            }
            try verifyCHTEFamily(inhibited: inhibit, adapterCut: cutAdapter)
        case .firmwareLimit:
            // The firmware limit family has no raw inhibit; charging control
            // is expressed through bfD0/bfE0 by the dedicated backend.
            if cutAdapter {
                _ = writeAdapter(adapterE, value: AdapterValue.cutForCHIE)
            } else if keyUsable(adapterE) {
                _ = writeAdapter(adapterE, value: AdapterValue.normal)
            }
        case .none:
            throw SMCError.keyNotFound
        }
    }

    // MARK: CHTE (ui32) inhibit

    private static func writeCHTE(inhibited: Bool) throws {
        let value: UInt32 = inhibited ? 0x0100_0000 : 0 // first byte 0x01, big-endian
        try SMC.writeUInt32(inhibitT, value: value)
    }

    private static func verifyCHTEFamily(inhibited: Bool, adapterCut: Bool) throws {
        var lastError: Error = SMCError.unknown(kIOReturn: -1, smcResult: 255)
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.12)
            do {
                let t = try SMC.readUInt32(inhibitT)
                let e = try SMC.readBytes(adapterE).0
                let tOK = inhibited ? (t == 0x0100_0000) : (t == 0)
                let eOK = adapterCut ? (e == AdapterValue.cutForCHIE) : (e == AdapterValue.normal)
                if tOK && eOK { return }
                lastError = SMCError.unknown(kIOReturn: -2, smcResult: UInt8(tOK ? 1 : 0) | UInt8(eOK ? 2 : 0))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Classic path: write CH0B/CH0C + CH0I, verify read-back with settle.
    static func applyAndVerify(inhibit: UInt8, adapter: UInt8) throws {
        try SMC.open()
        try SMC.writeUInt8(inhibitB, value: inhibit)
        try SMC.writeUInt8(inhibitC, value: inhibit)
        try SMC.writeUInt8(adapterDisable, value: adapter)

        // Read-back verification with a settle window: some firmware applies
        // SMC writes asynchronously (documented by smctl's field notes), so a
        // single immediate read-back can be premature.
        var lastError: Error = SMCError.unknown(kIOReturn: -1, smcResult: 255)
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.12)
            do {
                let b = try SMC.readBytes(inhibitB)
                let c = try SMC.readBytes(inhibitC)
                let i = try SMC.readBytes(adapterDisable)
                if b.0 == inhibit, c.0 == inhibit, i.0 == adapter {
                    return
                }
                lastError = SMCError.unknown(
                    kIOReturn: -2,
                    smcResult: UInt8(b.0 == inhibit && c.0 == inhibit ? 1 : 0) | UInt8(i.0 == adapter ? 2 : 0)
                )
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Verify only (no write) — used by capability probes and re-checks.
    static func verify(inhibit: UInt8, adapter: UInt8) -> Bool {
        guard let b = try? SMC.readBytes(inhibitB),
              let c = try? SMC.readBytes(inhibitC),
              let i = try? SMC.readBytes(adapterDisable)
        else { return false }
        return b.0 == inhibit && c.0 == inhibit && i.0 == adapter
    }

    /// Clears the adapter cut on every known adapter key (CH0I, CH0J, CHIE).
    /// Used on all safety paths — a stuck adapter cut would keep draining the
    /// battery, so restoration must not depend on which key was originally
    /// written. Retries once against a fresh connection per key.
    @discardableResult
    static func releaseAllAdapters() -> Bool {
        var allOK = true
        for key in [adapterDisable, adapterJ, adapterE] {
            guard keyUsable(key) else { continue }
            if !writeAdapter(key, value: AdapterValue.normal) {
                SMC.close()
                if !writeAdapter(key, value: AdapterValue.normal) {
                    allOK = false
                }
            }
        }
        return allOK
    }

    /// Legacy adapter key only (kept for callers that target the classic
    /// family specifically).
    @discardableResult
    static func releaseAdapter() -> Bool {
        if writeAdapterDisable(AdapterValue.normal) { return true }
        SMC.close()
        return writeAdapterDisable(AdapterValue.normal)
    }

    /// Release the adapter cut on EVERY adapter key this firmware actually
    /// exposes (CH0I / CH0J / CHIE). A cut latched on CHIE (Tahoe-era
    /// firmware has no CH0I) must be released on CHIE — releasing on a key
    /// the firmware doesn't expose silently does nothing. Used by every
    /// restore-normal path so a stale cut can never outlive its purpose.
    @discardableResult
    static func releaseAllAdaptersIfNeeded() -> Bool {
        var allOK = true
        for key in [adapterDisable, adapterJ, adapterE] {
            guard keyUsable(key) else { continue }
            // Only rewrite when a cut is actually latched — avoid hammering
            // the SMC with redundant writes on every enforcement tick.
            let current = try? SMC.readBytes(key).0
            if current == nil || current != AdapterValue.normal {
                if !writeAdapter(key, value: AdapterValue.normal) {
                    SMC.close()
                    if !writeAdapter(key, value: AdapterValue.normal) {
                        allOK = false
                    }
                }
            }
        }
        return allOK
    }

    /// Sets charge inhibit only (CH0B/CH0C), leaving the adapter alone.
    @discardableResult
    static func setInhibit(_ inhibited: Bool) -> Bool {
        let value = inhibited ? InhibitValue.inhibit : InhibitValue.normal
        do {
            try SMC.open()
            try SMC.writeUInt8(inhibitB, value: value)
            try SMC.writeUInt8(inhibitC, value: value)
            return true
        } catch {
            return false
        }
    }

    private static func writeAdapterDisable(_ value: UInt8) -> Bool {
        writeAdapter(adapterDisable, value: value)
    }

    private static func writeAdapter(_ key: FourCharCode, value: UInt8) -> Bool {
        do {
            try SMC.open()
            try SMC.writeUInt8(key, value: value)
            return true
        } catch {
            return false
        }
    }
}

/// The firmware-managed charge-limit key names, shared by the backend and
/// the diagnostics CLI.
enum FirmwareLimitKeys {
    static let activation = FourCharCode(fromStaticString: "bfF0")
    static let upper = FourCharCode(fromStaticString: "bfD0")
    static let lower = FourCharCode(fromStaticString: "bfE0")
}
