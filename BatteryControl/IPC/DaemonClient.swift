import BatteryCore
import Foundation
import os

/// App-side XPC client. One connection is reused; XPC replies resume the
/// awaiting task exactly once. Every mutating call sends a validated request
/// object — the daemon re-validates it at the boundary.
final class DaemonClient {

    static let shared = DaemonClient()

    private let queue = DispatchQueue(label: "com.batterycontrol.app.xpc")
    private var connection: NSXPCConnection?

    private func remoteObject() -> BatteryDaemonProtocol? {
        let current: NSXPCConnection
        if let connection {
            current = connection
        } else {
            current = NSXPCConnection(machServiceName: BatteryXPC.machServiceName, options: [])
            current.remoteObjectInterface = NSXPCInterface(with: BatteryDaemonProtocol.self)
            current.invalidationHandler = { [weak self] in
                self?.connection = nil
            }
            current.resume()
            connection = current
        }
        return current.remoteObjectProxyWithErrorHandler { error in
            DaemonAppLog.ipc.error("XPC error: \(error.localizedDescription)")
        } as? BatteryDaemonProtocol
    }

    // MARK: - Status

    func getStatus() async -> XPCStatusResponse? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let proxy = self?.remoteObject() else {
                    continuation.resume(returning: nil)
                    return
                }
                proxy.getStatus { envelope in
                    let response = envelope?.decode(
                        XPCStatusResponse.self,
                        expectingKind: XPCEnvelope.kindStatus
                    )
                    continuation.resume(returning: response)
                }
            }
        }
    }

    // MARK: - Control operations

    func applyPolicy(_ policy: ChargingPolicy) async -> OperationAck? {
        let request = ApplyPolicyRequest(policy: policy, reason: .userRequest)
        return await sendAck(request, kind: XPCEnvelope.kindApplyPolicy) { proxy, envelope, reply in
            proxy.applyPolicy(envelope, withReply: reply)
        }
    }

    func startForceDischarge(targetPercent: Int, floorPercent: Int) async -> OperationAck? {
        let request = StartForceDischargeRequest(targetPercent: targetPercent, floorPercent: floorPercent)
        return await sendAck(request, kind: XPCEnvelope.kindForceDischarge) { proxy, envelope, reply in
            proxy.startForceDischarge(envelope, withReply: reply)
        }
    }

    func startForceCharge(targetPercent: Int) async -> OperationAck? {
        let request = StartForceChargeRequest(targetPercent: targetPercent)
        return await sendAck(request, kind: XPCEnvelope.kindForceCharge) { proxy, envelope, reply in
            proxy.startForceCharge(envelope, withReply: reply)
        }
    }

    func cancelOverrides() async -> OperationAck? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let proxy = self?.remoteObject() else {
                    continuation.resume(returning: nil)
                    return
                }
                proxy.cancelOverrides { envelope in
                    let ack = self?.decodeAck(envelope)
                    continuation.resume(returning: ack)
                }
            }
        }
    }

    func beginCalibration() async -> OperationAck? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let proxy = self?.remoteObject() else {
                    continuation.resume(returning: nil)
                    return
                }
                proxy.beginCalibration { envelope in
                    let ack = self?.decodeAck(envelope)
                    continuation.resume(returning: ack)
                }
            }
        }
    }

    func cancelCalibration() async -> OperationAck? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let proxy = self?.remoteObject() else {
                    continuation.resume(returning: nil)
                    return
                }
                proxy.cancelCalibration { envelope in
                    let ack = self?.decodeAck(envelope)
                    continuation.resume(returning: ack)
                }
            }
        }
    }

    // MARK: - Diagnostics

    func runDiagnostics() async -> DiagnosticsReport? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let proxy = self?.remoteObject() else {
                    continuation.resume(returning: nil)
                    return
                }
                proxy.runDiagnostics { envelope in
                    let report = envelope?.decode(
                        DiagnosticsReport.self,
                        expectingKind: XPCEnvelope.kindDiagnostics
                    )
                    continuation.resume(returning: report)
                }
            }
        }
    }

    // MARK: - Sync helpers (used by the installer)

    func pingSync() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BoolBox()
        queue.async { [weak self] in
            guard let proxy = self?.remoteObject() else {
                semaphore.signal()
                return
            }
            proxy.getStatus { _ in
                box.value = true
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 3)
        return box.value
    }

    func cancelOverridesSync() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BoolBox()
        queue.async { [weak self] in
            guard let proxy = self?.remoteObject() else {
                semaphore.signal()
                return
            }
            proxy.cancelOverrides { _ in
                box.value = true
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 3)
        return box.value
    }

    // MARK: - Plumbing

    private func sendAck<T: Encodable>(
        _ payload: T,
        kind: String,
        invoke: @escaping (BatteryDaemonProtocol, XPCEnvelope, @escaping (XPCEnvelope?) -> Void) -> Void
    ) async -> OperationAck? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self,
                      let proxy = self.remoteObject(),
                      let envelope = XPCEnvelope.encode(payload, kind: kind)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                invoke(proxy, envelope) { replyEnvelope in
                    let ack = self.decodeAck(replyEnvelope)
                    continuation.resume(returning: ack)
                }
            }
        }
    }

    private func decodeAck(_ envelope: XPCEnvelope?) -> OperationAck? {
        envelope?.decode(OperationAck.self, expectingKind: XPCEnvelope.kindAck)
    }
}

/// Thread-safe boolean for semaphore-based sync helpers.
private final class BoolBox {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}
