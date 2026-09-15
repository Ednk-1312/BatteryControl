import Foundation
import os

/// Shared XPC client for the BatteryControl daemon: used by both the GUI app
/// and the `batterycontrol` CLI. One connection is reused; XPC replies resume
/// the awaiting task exactly once. Every mutating call sends a validated
/// request object — the daemon re-validates it at the boundary. Clients never
/// touch hardware directly; the daemon is the security boundary.
///
/// `@unchecked Sendable`: all mutable state (`connection`) is confined to the
/// private serial `queue`. Every round-trip is guarded by a timeout so a
/// wedged or silently-rejecting daemon yields `nil` instead of hanging the
/// client forever.
public final class DaemonXPCClient: @unchecked Sendable {

    public static let shared = DaemonXPCClient()

    private let queue = DispatchQueue(label: "com.batterycontrol.client.xpc")
    private var connection: NSXPCConnection?

    public init() {}

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
            Logger(subsystem: "com.batterycontrol", category: "ipc")
                .error("XPC error: \(error.localizedDescription)")
        } as? BatteryDaemonProtocol
    }

    // MARK: - Timeout guard

    /// Guards every XPC round-trip: if the daemon never replies (wedged, or
    /// rejected the connection without an error callback), the caller gets
    /// `fallback` after `seconds` instead of hanging forever. The reply path
    /// and the timeout both call `OnceDelivery.deliver`; whichever lands
    /// first wins and the continuation is resumed exactly once.
    private func race<T: Sendable>(
        _ once: OnceDelivery<T>,
        seconds: TimeInterval = 5,
        start: @escaping @Sendable () -> Void
    ) async -> T {
        await withCheckedContinuation { continuation in
            once.setContinuation(continuation)
            start()
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.deliverFallback()
            }
        }
    }

    /// Exactly-once delivery: the first deliver* call wins and resumes the
    /// awaiting continuation; later calls are no-ops (no leaked or double-
    /// resumed continuations).
    private final class OnceDelivery<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var delivered = false
        private var continuation: CheckedContinuation<T, Never>?
        private let fallback: T

        init(default fallback: T) {
            self.fallback = fallback
        }

        func setContinuation(_ continuation: CheckedContinuation<T, Never>) {
            lock.lock()
            // Defensive: if something already delivered, resume immediately.
            if delivered {
                lock.unlock()
                continuation.resume(returning: fallback)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func deliver(_ value: T) {
            lock.lock()
            if delivered {
                lock.unlock()
                return
            }
            delivered = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }

        func deliverFallback() {
            deliver(fallback)
        }
    }

    // MARK: - Status

    public func getStatus() async -> XPCStatusResponse? {
        let once = OnceDelivery<XPCStatusResponse?>(default: nil)
        return await race(once) {
            self.queue.async { [weak self] in
                guard let self, let proxy = self.remoteObject() else {
                    once.deliver(nil)
                    return
                }
                proxy.getStatus { envelope in
                    once.deliver(envelope?.decode(
                        XPCStatusResponse.self,
                        expectingKind: XPCEnvelope.kindStatus
                    ))
                }
            }
        }
    }

    // MARK: - Control operations

    public func applyPolicy(_ policy: ChargingPolicy) async -> OperationAck? {
        let request = ApplyPolicyRequest(policy: policy, reason: .userRequest)
        return await sendAck(request, kind: XPCEnvelope.kindApplyPolicy) { proxy, envelope, reply in
            proxy.applyPolicy(envelope, withReply: reply)
        }
    }

    public func startForceDischarge(
        targetPercent: Int,
        floorPercent: Int,
        belowFloorConsent: Bool = false
    ) async -> OperationAck? {
        let request = StartForceDischargeRequest(
            targetPercent: targetPercent,
            floorPercent: floorPercent,
            belowFloorConsent: belowFloorConsent
        )
        return await sendAck(request, kind: XPCEnvelope.kindForceDischarge) { proxy, envelope, reply in
            proxy.startForceDischarge(envelope, withReply: reply)
        }
    }

    public func startForceCharge(targetPercent: Int) async -> OperationAck? {
        let request = StartForceChargeRequest(targetPercent: targetPercent)
        return await sendAck(request, kind: XPCEnvelope.kindForceCharge) { proxy, envelope, reply in
            proxy.startForceCharge(envelope, withReply: reply)
        }
    }

    public func cancelOverrides() async -> OperationAck? {
        let once = OnceDelivery<OperationAck?>(default: nil)
        return await race(once) {
            self.queue.async { [weak self] in
                guard let self, let proxy = self.remoteObject() else {
                    once.deliver(nil)
                    return
                }
                proxy.cancelOverrides { envelope in
                    once.deliver(envelope?.decode(
                        OperationAck.self,
                        expectingKind: XPCEnvelope.kindAck
                    ))
                }
            }
        }
    }

    public func beginCalibration() async -> OperationAck? {
        let once = OnceDelivery<OperationAck?>(default: nil)
        return await race(once) {
            self.queue.async { [weak self] in
                guard let self, let proxy = self.remoteObject() else {
                    once.deliver(nil)
                    return
                }
                proxy.beginCalibration { envelope in
                    once.deliver(envelope?.decode(
                        OperationAck.self,
                        expectingKind: XPCEnvelope.kindAck
                    ))
                }
            }
        }
    }

    public func cancelCalibration() async -> OperationAck? {
        let once = OnceDelivery<OperationAck?>(default: nil)
        return await race(once) {
            self.queue.async { [weak self] in
                guard let self, let proxy = self.remoteObject() else {
                    once.deliver(nil)
                    return
                }
                proxy.cancelCalibration { envelope in
                    once.deliver(envelope?.decode(
                        OperationAck.self,
                        expectingKind: XPCEnvelope.kindAck
                    ))
                }
            }
        }
    }

    // MARK: - Diagnostics

    public func runDiagnostics() async -> DiagnosticsReport? {
        let once = OnceDelivery<DiagnosticsReport?>(default: nil)
        return await race(once) {
            self.queue.async { [weak self] in
                guard let self, let proxy = self.remoteObject() else {
                    once.deliver(nil)
                    return
                }
                proxy.runDiagnostics { envelope in
                    once.deliver(envelope?.decode(
                        DiagnosticsReport.self,
                        expectingKind: XPCEnvelope.kindDiagnostics
                    ))
                }
            }
        }
    }

    // MARK: - Private

    private func sendAck<T: Codable & Sendable>(
        _ request: T,
        kind: String,
        perform: @escaping @Sendable (BatteryDaemonProtocol, XPCEnvelope, @escaping (XPCEnvelope?) -> Void) -> Void
    ) async -> OperationAck? {
        guard let envelope = XPCEnvelope.encode(request, kind: kind) else { return nil }
        let once = OnceDelivery<OperationAck?>(default: nil)
        return await race(once) {
            self.queue.async { [weak self] in
                guard let self, let proxy = self.remoteObject() else {
                    once.deliver(nil)
                    return
                }
                perform(proxy, envelope) { reply in
                    once.deliver(reply?.decode(
                        OperationAck.self,
                        expectingKind: XPCEnvelope.kindAck
                    ))
                }
            }
        }
    }
}
