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

    /// Guards `connection` against the `invalidationHandler`, which runs on
    /// an XPC-internal queue — it must neither race the serial-queue access
    /// nor deadlock against it (invalidation can fire synchronously inside
    /// `remoteObjectProxyWithErrorHandler` during connection teardown).
    private let connectionLock = NSLock()

    public init() {}

    private func remoteObject() -> BatteryDaemonProtocol? {
        let current: NSXPCConnection
        connectionLock.lock()
        if let connection {
            current = connection
            connectionLock.unlock()
        } else {
            connectionLock.unlock()
            let fresh = NSXPCConnection(machServiceName: BatteryXPC.machServiceName, options: [])
            fresh.remoteObjectInterface = NSXPCInterface(with: BatteryDaemonProtocol.self)
            fresh.invalidationHandler = { [weak self] in
                // Never touch `queue` here: invalidation can arrive while a
                // queue block is mid-teardown, and the handler must not
                // deadlock waiting for it. `connectionLock` is a different,
                // never-held-across-XPC-calls lock, so clearing here stays
                // race-free without deadlock risk.
                self?.setConnection(nil)
            }
            fresh.resume()
            connectionLock.lock()
            if connection == nil {
                connection = fresh
                connectionLock.unlock()
                current = fresh
            } else {
                // Another caller won the create race; retire ours. The
                // handler is cleared first so this teardown cannot clear
                // the winner's stored connection.
                fresh.invalidationHandler = nil
                fresh.invalidate()
                current = connection!
                connectionLock.unlock()
            }
        }
        return current.remoteObjectProxyWithErrorHandler { error in
            Logger(subsystem: "com.batterycontrol", category: "ipc")
                .error("XPC error: \(error.localizedDescription)")
        } as? BatteryDaemonProtocol
    }

    private func setConnection(_ new: NSXPCConnection?) {
        connectionLock.lock()
        connection = new
        connectionLock.unlock()
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

    public func startForceCharge(targetPercent: Int, durationSeconds: TimeInterval? = nil) async -> OperationAck? {
        let request = StartForceChargeRequest(targetPercent: targetPercent, durationSeconds: durationSeconds)
        return await sendAck(request, kind: XPCEnvelope.kindForceCharge) { proxy, envelope, reply in
            proxy.startForceCharge(envelope, withReply: reply)
        }
    }

    public func uninstallPrivilegedComponents(removeCLI: Bool = true) async -> OperationAck? {
        let request = UninstallRequest(removeCLI: removeCLI)
        return await sendAck(request, kind: XPCEnvelope.kindUninstall) { proxy, envelope, reply in
            proxy.uninstall(envelope, withReply: reply)
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

    // MARK: - Compatibility report / database

    /// Request the machine-evidence compatibility report from the daemon.
    /// Read-only on the daemon side; safe on any machine.
    public func exportCompatibilityReport() async -> CompatibilityReport? {
        let once = OnceDelivery<CompatibilityReport?>(default: nil)
        return await race(once) {
            self.queue.async { [weak self] in
                guard let self, let proxy = self.remoteObject() else {
                    once.deliver(nil)
                    return
                }
                proxy.exportCompatibilityReport { envelope in
                    once.deliver(envelope?.decode(
                        CompatibilityReport.self,
                        expectingKind: XPCEnvelope.kindCompatibilityReport
                    ))
                }
            }
        }
    }

    /// Install a community compatibility database through the daemon (the
    /// only writer of the root-owned file). Returns nil on transport
    /// failure; use `installCompatibilityDatabaseWithRejection` when the
    /// caller must distinguish a daemon-side rejection from a failure.
    public func installCompatibilityDatabase(
        _ payload: FirmwareProfileLibrary.DatabasePayload
    ) async -> DatabaseInstallResult? {
        await installCompatibilityDatabaseWithRejection(payload)?.result
    }

    /// Same round-trip, surfacing a daemon-side rejection (accepted=false)
    /// separately from a transport failure (nil).
    public func installCompatibilityDatabaseWithRejection(
        _ payload: FirmwareProfileLibrary.DatabasePayload
    ) async -> (result: DatabaseInstallResult?, rejectedMessage: String?)? {
        guard let envelope = XPCEnvelope.encode(
            InstallDatabaseRequest(schemaVersion: payload.schemaVersion, profiles: payload.profiles),
            kind: XPCEnvelope.kindDatabaseInstall
        ) else { return nil }
        let once = OnceDelivery<(DatabaseInstallResult?, String?)?>(default: nil)
        let outcome = await race(once) {
            self.queue.async { [weak self] in
                guard let self, let proxy = self.remoteObject() else {
                    once.deliver(nil)
                    return
                }
                proxy.installCompatibilityDatabase(envelope) { reply in
                    if let result = reply?.decode(
                        DatabaseInstallResult.self,
                        expectingKind: XPCEnvelope.kindCompatibilityReport
                    ) {
                        once.deliver((result, nil))
                    } else if let ack = reply?.decode(
                        OperationAck.self,
                        expectingKind: XPCEnvelope.kindAck
                    ), !ack.accepted {
                        once.deliver((nil, ack.message))
                    } else {
                        once.deliver((nil, nil))
                    }
                }
            }
        }
        return outcome
    }

    // MARK: - Synchronous helpers (installer / teardown paths)

    /// Blocking status probe with a bounded wait. Never blocks longer than
    /// `timeout`; returns false when the daemon did not answer in time.
    /// Call only from a background queue — this waits on the caller thread.
    public func pingSync(timeout: TimeInterval = 3) -> Bool {
        let state = SyncWaitBox()
        queue.async { [weak self] in
            guard let self, let proxy = self.remoteObject() else {
                state.signal(false)
                return
            }
            proxy.getStatus { _ in state.signal(true) }
        }
        return state.wait(seconds: timeout)
    }

    /// Request the daemon-owned safe restore and privileged removal. The
    /// daemon replies only after it has verified normal charging; removal
    /// itself then happens asynchronously so launchd can stop the process.
    public func uninstallPrivilegedComponentsSync(timeout: TimeInterval = 5, removeCLI: Bool = true) -> Bool {
        let request = UninstallRequest(removeCLI: removeCLI)
        guard let envelope = XPCEnvelope.encode(request, kind: XPCEnvelope.kindUninstall) else { return false }
        let state = SyncWaitBox()
        queue.async { [weak self] in
            guard let self, let proxy = self.remoteObject() else {
                state.signal(false)
                return
            }
            proxy.uninstall(envelope) { reply in
                let accepted = reply?.decode(OperationAck.self, expectingKind: XPCEnvelope.kindAck)?.accepted == true
                state.signal(accepted)
            }
        }
        return state.wait(seconds: timeout)
    }

    /// Best-effort blocking override cancellation used before helper
    /// uninstall. True when the daemon answered at all (even with a
    /// rejection); false means the restore could not be confirmed and the
    /// uninstall flow reports that honestly.
    public func cancelOverridesSync(timeout: TimeInterval = 3) -> Bool {
        let state = SyncWaitBox()
        queue.async { [weak self] in
            guard let self, let proxy = self.remoteObject() else {
                state.signal(false)
                return
            }
            proxy.cancelOverrides { _ in state.signal(true) }
        }
        return state.wait(seconds: timeout)
    }

    /// One-shot bounded wait for a background operation. `wait` returns true
    /// only when signaled SUCCESSFULLY within the timeout; a timed-out wait
    /// returns false even if the signal lands a moment later (conservative,
    /// honest false rather than an unconfirmed true).
    private final class SyncWaitBox: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var success = false

        func signal(_ ok: Bool) {
            lock.lock()
            success = ok
            lock.unlock()
            semaphore.signal()
        }

        func wait(seconds: TimeInterval) -> Bool {
            let signaled = semaphore.wait(timeout: .now() + seconds) == .success
            lock.lock()
            let ok = success
            lock.unlock()
            return signaled && ok
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
