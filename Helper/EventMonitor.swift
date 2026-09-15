import BatteryCore
import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

// IOKit power-management message constants. The C macros in IOMessage.h
// are not exposed to Swift, so they are reproduced here from the SDK
// definition iokit_common_msg(m) = sys_iokit | sub_iokit_common | m
// (sys_iokit = err_system(0x38), sub_iokit_common = err_sub(0)).
private enum IOPMMessage {
    // err_system(0x38) = 0x38 << 26 = 0x1000_0000; err_sub(0) = 0.
    private static let base: UInt32 = 0x1000_0000

    static let canSystemSleep = base | 0x270
    static let systemWillSleep = base | 0x280
    static let systemWillNotSleep = base | 0x290
    static let systemWillPowerOn = base | 0x320
    static let systemHasPoweredOn = base | 0x300
}

/// Registers IOKit notifications for sleep, wake, and power-source changes,
/// routing them into the control engine. Recovery after these transitions is
/// a core requirement — a charge limit that evaporates at the first sleep is
/// worse than none.
final class EventMonitor {

    private let engine: ControlEngine
    private var powerSourceRunloopSource: CFRunLoopSource?
    private var rootPowerService: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?

    init(engine: ControlEngine) {
        self.engine = engine
    }

    func start() {
        registerSystemPower()
        registerPowerSource()
    }

    // MARK: Sleep / wake (IORegisterForSystemPower)

    private func registerSystemPower() {
        var port: IONotificationPortRef?
        var iterator: io_iterator_t = 0

        rootPowerService = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &port,
            { (ref, service, messageType, messageArgument) in
                let monitor = Unmanaged<EventMonitor>.fromOpaque(ref!).takeUnretainedValue()
                monitor.handlePowerMessage(type: messageType, argument: messageArgument)
            },
            &iterator
        )

        guard rootPowerService != 0, let port else {
            DaemonLog.warning(
                "Could not register for system power notifications; relying on the periodic tick.",
                operation: "startup"
            )
            return
        }
        notificationPort = port
        // The notification port needs a run loop to deliver on.
        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        // Drain the iterator once to arm the notification.
        let toArm = iterator
        while IOIteratorNext(toArm) != 0 {}
        IOObjectRelease(iterator)
        DaemonLog.info("Sleep/wake notifications registered.", operation: "startup")
    }

    fileprivate func handlePowerMessage(type: natural_t, argument: UnsafeMutableRawPointer?) {
        // The notification ID arrives in the pointer-sized messageArgument.
        let notificationID = argument.map { Int(bitPattern: $0) } ?? 0
        switch type {
        case IOPMMessage.canSystemSleep:
            // Allow idle sleep; normal charging policy resumes on wake.
            IOAllowPowerChange(rootPowerService, notificationID)
        case IOPMMessage.systemWillSleep:
            // Nothing runs while asleep. The adapter cut (CH0I) must never
            // survive sleep unattended — release it before sleeping.
            engine.sleeping()
            IOAllowPowerChange(rootPowerService, notificationID)
        case IOPMMessage.systemWillPowerOn:
            break // hardware not ready yet; act on SystemHasPoweredOn
        case IOPMMessage.systemHasPoweredOn:
            engine.woke()
        default:
            break
        }
    }

    // MARK: Power source (AC connect/disconnect)

    private func registerPowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ref in
            let monitor = Unmanaged<EventMonitor>.fromOpaque(ref!).takeUnretainedValue()
            monitor.engine.powerSourceChanged()
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            powerSourceRunloopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            DaemonLog.info("Power-source notifications registered.", operation: "startup")
        }
    }
}

