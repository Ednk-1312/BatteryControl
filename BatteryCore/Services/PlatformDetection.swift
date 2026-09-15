import Foundation

#if canImport(IOKit)
import IOKit
import IOKit.ps
#endif

/// Detects the machine identity and enforces the M1–M4 + macOS 15 scope.
/// The pure `evaluate` function is unit-tested; `detect()` is the live path.
public enum PlatformDetector {

    /// Collects live platform identity from the OS.
    public static func detect() -> PlatformIdentity {
        let modelIdentifier = sysctlString("hw.model") ?? "Unknown"
        var chipRaw: String?

        #if arch(arm64)
        let isAppleSilicon = true
        // On Apple Silicon, hw.model is like "Mac14,2" and does not name the
        // chip. MachineID/machine info is the practical way to find it.
        if let cpuBrand = sysctlString("machdep.cpu.brand_string") {
            chipRaw = cpuBrand
        }
        #else
        let isAppleSilicon = false
        chipRaw = sysctlString("machdep.cpu.brand_string")
        #endif

        let chip = chipRaw.flatMap { ChipGeneration.parse(fromRawString: $0) }
            ?? ChipGeneration.parse(fromRawString: modelIdentifier)

        let processInfo = ProcessInfo.processInfo
        let build = sysctlString("kern.osbuildversion") ?? readOSBuildIdentifier() ?? "unknown"

        let systemFirmwareBuild = readBootFirmwareBuild()

        return PlatformIdentity(
            chipGeneration: chip,
            isAppleSilicon: isAppleSilicon,
            macModelIdentifier: modelIdentifier,
            marketingModelName: modelIdentifier.isEmpty ? "Unknown" : marketingModelName(modelIdentifier: modelIdentifier),
            osMajor: processInfo.operatingSystemVersion.majorVersion,
            osMinor: processInfo.operatingSystemVersion.minorVersion,
            osPatch: processInfo.operatingSystemVersion.patchVersion,
            osBuild: build,
            systemFirmwareBuild: systemFirmwareBuild
        )
    }

    /// System (boot) firmware build from the device tree, e.g.
    /// "mBoot-20457.1.29". The property lives on a child node of
    /// /chosen, so the lookup recurses. Nil when unavailable —
    /// classification then falls back to compatible-by-capability.
    static func readBootFirmwareBuild() -> String? {
        #if canImport(IOKit) && os(macOS)
        return readDeviceTreeString("system-firmware-version")
            .flatMap { FirmwareProfileLibrary.parseBootBuild(from: $0) }
        #else
        return nil
        #endif
    }

    /// The macOS build identifier (e.g. "24H23") from `sysctl kern.osversion`.
    public static func readOSBuildIdentifier() -> String? {
        #if canImport(IOKit) && os(macOS)
        return sysctlString("kern.osversion")
        #else
        return nil
        #endif
    }

    /// Read a string property from the device tree, recursing into children
    /// when the property is not on the node itself. Device-tree strings are
    /// NUL-padded; the padding is stripped here.
    private static func readDeviceTreeString(_ key: String, fromPath: String = "IODeviceTree:/chosen") -> String? {
        #if canImport(IOKit) && os(macOS)
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, fromPath)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntrySearchCFProperty(
            entry,
            "IODeviceTree",
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) else { return nil }
        let raw = (value as? String) ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
        return raw?.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \n\r\t"))
        #else
        return nil
        #endif
    }

    /// Pure scope evaluation against a known identity — unit tested.
    public static func evaluate(_ identity: PlatformIdentity) -> (supported: Bool, reason: String?) {
        (identity.isSupportedPlatform, identity.unsupportedReason)
    }

    /// Best-effort friendly model name from the identifier.
    /// A small table covering the common M1–M4 machines; falls back to the
    /// raw identifier when unknown. Adapted from public Apple model data.
    public static func marketingModelName(modelIdentifier: String) -> String {
        let known: [String: String] = [
            "MacBookAir10,1": "MacBook Air (M1, 2020)",
            "MacBookAir9,1": "MacBook Air (Intel, 2020)",
            "MacBookPro17,1": "MacBook Pro 13\" (M1, 2020)",
            "MacBookPro18,1": "MacBook Pro 16\" (M1 Pro/Max, 2021)",
            "MacBookPro18,2": "MacBook Pro 16\" (M1 Pro/Max, 2021)",
            "MacBookPro18,3": "MacBook Pro 14\" (M1 Pro/Max, 2021)",
            "MacBookPro18,4": "MacBook Pro 14\" (M1 Pro/Max, 2021)",
            "Mac14,2": "MacBook Air 13\" (M2, 2022)",
            "Mac14,15": "MacBook Air 15\" (M2, 2023)",
            "Mac14,7": "MacBook Pro 13\" (M2, 2022)",
            "Mac14,5": "MacBook Pro 16\" (M2 Pro/Max, 2023)",
            "Mac14,6": "MacBook Pro 16\" (M2 Pro/Max, 2023)",
            "Mac14,9": "MacBook Pro 14\" (M2 Pro/Max, 2023)",
            "Mac14,10": "MacBook Pro 14\" (M2 Pro/Max, 2023)",
            "Mac15,3": "MacBook Air 13\" (M3, 2024)",
            "Mac15,6": "MacBook Air 15\" (M3, 2024)",
            "Mac15,7": "MacBook Pro 14\" (M3, 2023)",
            "Mac15,8": "MacBook Pro 14\" (M3 Pro/Max, 2023)",
            "Mac15,9": "MacBook Pro 16\" (M3 Pro/Max, 2023)",
            "Mac15,10": "MacBook Pro 16\" (M3 Pro/Max, 2023)",
            // Verified against Apple's support and Common Criteria
            // publications: the 2024 M3 MacBook Airs are Mac15,12 (13") and
            // Mac15,13 (15") — NOT MacBook Pros.
            "Mac15,12": "MacBook Air 13\" (M3, 2024)",
            "Mac15,13": "MacBook Air 15\" (M3, 2024)",
            "Mac16,1": "MacBook Pro 14\" (M4, 2024)",
            "Mac16,5": "MacBook Pro 14\" (M4 Pro/Max, 2024)",
            "Mac16,6": "MacBook Pro 16\" (M4 Pro/Max, 2024)",
            "Mac16,7": "MacBook Pro 16\" (M4, 2024)",
            "Mac16,8": "MacBook Pro 16\" (M4 Pro/Max, 2024)",
            "Mac16,12": "MacBook Air 13\" (M4, 2025)",
            "Mac16,13": "MacBook Air 15\" (M4, 2025)",
        ]
        return known[modelIdentifier] ?? modelIdentifier
    }

    /// Live battery readings from IOKit power sources. On non-macOS builds
    /// (tests on other platforms) this returns a neutral snapshot.
    public static func readBatteryFromIOKit(now: Date = Date()) -> BatteryReadings? {
        #if canImport(IOKit) && os(macOS)
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let type = desc[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType
            else { continue }

            let percentage = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let state = desc[kIOPSPowerSourceStateKey] as? String ?? ""
            let onAC = (state == kIOPSACPowerValue)

            // Detailed values come from the AppleSmartBattery registry.
            let smart = readAppleSmartBattery()
            return BatteryReadings(
                percentage: percentage,
                isCharging: charging,
                isExternalConnected: onAC || (smart["ExternalConnected"] as? Bool ?? false),
                condition: condition(fromDescription: desc),
                cycleCount: smart["CycleCount"] as? Int ?? 0,
            // Real capacity values (mAh). On Apple Silicon the top-level
            // "MaxCapacity" is a percent-like gauge value (100), NOT mAh —
            // dividing it by DesignCapacity produces nonsense health. The
            // true capacities live in NominalChargeCapacity (the gauge's
            // learned full-charge capacity, which Apple's own "Maximum
            // Capacity" uses) and the AppleRaw* keys.
            currentCapacitymAh: smart["AppleRawCurrentCapacity"] as? Int
                ?? smart["CurrentCapacity"] as? Int ?? 0,
            maxCapacitymAh: smart["NominalChargeCapacity"] as? Int
                ?? smart["AppleRawMaxCapacity"] as? Int ?? 0,
            designCapacitymAh: smart["DesignCapacity"] as? Int ?? 0,
                voltagemV: smart["Voltage"] as? Int ?? 0,
                amperageMA: smart["Amperage"] as? Int ?? 0,
                temperatureC: (smart["Temperature"] as? Int).map { Double($0) / 100.0 },
                timestamp: now
            )
        }
        return nil
        #else
        return nil
        #endif
    }

    private static func condition(fromDescription desc: [String: Any]) -> BatteryCondition {
        guard let health = desc[kIOPSBatteryHealthConditionKey] as? String else { return .unknown }
        // Apple Silicon reports the healthy value as "Normal" (what
        // system_profiler shows); the legacy IOKit constants use "Good".
        // Anything else is a genuine degradation signal — never infer a
        // service condition from capacity math alone.
        switch health {
        case "Normal", kIOPSGoodValue:
            return .normal
        case "Service Recommended", "Check Battery", kIOPSFairValue, kIOPSPoorValue:
            return .serviceRecommended
        default:
            return .unknown
        }
    }

    /// Reads the raw AppleSmartBattery IOKit registry for detailed stats.
    public static func readAppleSmartBattery() -> [String: Any] {
        #if canImport(IOKit) && os(macOS)
        var iterator: io_iterator_t = 0
        let match = IOServiceMatching("AppleSmartBattery")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var result: [String: Any] = [:]
        let service = IOIteratorNext(iterator)
        if service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                result = dict
            }
        }
        return result
        #else
        return [:]
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
