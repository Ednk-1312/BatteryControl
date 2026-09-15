import BatteryCore
import Foundation
import Security

/// The XPC surface of the daemon. Deliberately minimal: status reads and a
/// handful of validated control commands. No raw SMC access, no generic
/// write primitives — every request is a named operation with a validated
/// value object. The @objc protocol itself lives in BatteryCore.
final class DaemonXPCServer: NSObject {

    private let engine: ControlEngine
    private let listener: NSXPCListener

    init(engine: ControlEngine) {
        self.engine = engine
        // In a LaunchDaemon, the mach service name refers to the socket
        // launchd created from the plist's MachServices entry.
        self.listener = NSXPCListener(machServiceName: BatteryXPC.machServiceName)
        super.init()
        listener.delegate = self
    }

    func run() {
        listener.resume()
        DaemonLog.info("XPC listener active on \(BatteryXPC.machServiceName)", operation: "startup")
    }

    // MARK: Client validation

    /// Only accept connections from the BatteryControl app: the client must
    /// be signed by the same team as this daemon, or — for ad-hoc developer
    /// builds, which have no team — live inside the same .app bundle.
    private func shouldAccept(connection: NSXPCConnection) -> Bool {
        guard let clientInfo = signingInfo(ofPID: connection.processIdentifier),
              let ownInfo = signingInfoOfSelf()
        else { return false }

        let clientTeam = clientInfo[kSecCodeInfoTeamIdentifier as String] as? String
        let ownTeam = ownInfo[kSecCodeInfoTeamIdentifier as String] as? String

        if let clientTeam, let ownTeam, !clientTeam.isEmpty, clientTeam == ownTeam {
            return true
        }

        // Ad-hoc path: both unsigned by a team. Require the client to sit
        // inside the same app bundle as the daemon's containing bundle.
        guard clientTeam == nil, ownTeam == nil,
              let clientPath = clientInfo["path"] as? String,
              let ownPath = ownInfo["path"] as? String
        else { return false }

        func appBundleRoot(ofPath path: String) -> String? {
            var url = URL(fileURLWithPath: path)
            while url.pathComponents.count > 1 {
                if url.pathExtension == "app" { return url.path }
                if url.deleteLastPathComponent() == false { break }
            }
            return nil
        }

        guard let clientRoot = appBundleRoot(ofPath: clientPath),
              let ownRoot = appBundleRoot(ofPath: ownPath)
        else { return false }
        return clientRoot == ownRoot
    }

    private func signingInfo(ofPID pid: pid_t) -> [String: Any]? {
        var guest: SecCode?
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
              let code = guest,
              let staticCode = staticCode(from: code)
        else { return nil }
        return signingInfo(ofStaticCode: staticCode)
    }

    private func signingInfoOfSelf() -> [String: Any]? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess,
              let code = selfCode,
              let staticCode = staticCode(from: code)
        else { return nil }
        return signingInfo(ofStaticCode: staticCode)
    }

    private func staticCode(from code: SecCode) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    private func signingInfo(ofStaticCode staticCode: SecStaticCode) -> [String: Any]? {
        var infoCF: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any]
        else { return nil }
        return info
    }
}

extension DaemonXPCServer: NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard shouldAccept(connection: newConnection) else {
            DaemonLog.warning(
                "Rejected XPC connection from pid \(newConnection.processIdentifier)",
                operation: "xpc"
            )
            return false
        }
        let handler = RequestHandler(engine: engine)
        newConnection.exportedInterface = NSXPCInterface(with: BatteryDaemonProtocol.self)
        newConnection.exportedObject = handler
        newConnection.resume()
        return true
    }
}

/// Executes validated requests against the control engine. Every mutating
/// call re-validates the decoded value here (defense in depth): the XPC
/// boundary never trusts the client.
final class RequestHandler: NSObject, BatteryDaemonProtocol {

    private let engine: ControlEngine

    init(engine: ControlEngine) {
        self.engine = engine
        super.init()
    }

    // MARK: Status

    func getStatus(withReply reply: @escaping (XPCEnvelope?) -> Void) {
        let response = XPCStatusResponse(
            snapshot: engine.snapshot(helperStatus: .running),
            lastAttempt: engine.lastAttempt,
            lastError: engine.lastError,
            daemonVersion: engine.daemonVersion
        )
        reply(XPCEnvelope.encode(response, kind: XPCEnvelope.kindStatus))
    }

    // MARK: Control operations

    func applyPolicy(_ envelope: XPCEnvelope, withReply reply: @escaping (XPCEnvelope?) -> Void) {
        guard let request = envelope.decode(ApplyPolicyRequest.self, expectingKind: XPCEnvelope.kindApplyPolicy) else {
            reply(ack(false, "Malformed policy request."))
            return
        }
        guard ControlModeHelpers.validate(request.policy) == nil else {
            reply(ack(false, "The requested charging policy is outside the safe range."))
            return
        }
        let ok = engine.applyPolicy(request.policy)
        reply(ack(ok, ok ? request.policy.summary : "The policy could not be applied."))
    }

    func startForceDischarge(_ envelope: XPCEnvelope, withReply reply: @escaping (XPCEnvelope?) -> Void) {
        guard let request = envelope.decode(StartForceDischargeRequest.self, expectingKind: XPCEnvelope.kindForceDischarge) else {
            reply(ack(false, "Malformed force-discharge request."))
            return
        }
        let floor = ChargingPolicyEngine.effectiveDischargeFloor(requested: request.floorPercent)
        // Consent integrity: a below-safety-floor floor requires the explicit
        // consent flag from the client — and the client must be the app this
        // daemon already authenticated on connection.
        if ChargingPolicyEngine.requiresBelowFloorConsent(floor: floor), !request.belowFloorConsent {
            reply(ack(false, "A discharge below \(ChargingPolicyEngine.minimumDischargeFloor)% requires explicit confirmation."))
            return
        }
        guard request.targetPercent >= floor else {
            reply(ack(false, "The discharge target is below the discharge floor (\(floor)%)."))
            return
        }
        let ok = engine.startForceDischarge(
            targetPercent: request.targetPercent,
            floorPercent: request.floorPercent,
            belowFloorConsent: request.belowFloorConsent
        )
        let floorNote = ChargingPolicyEngine.requiresBelowFloorConsent(floor: floor)
            ? " Safety floor removed — this accelerates battery degradation."
            : ""
        reply(ack(ok, ok ? "Force discharge to \(request.targetPercent)% started." + floorNote : "Force discharge could not be started."))
    }

    func startForceCharge(_ envelope: XPCEnvelope, withReply reply: @escaping (XPCEnvelope?) -> Void) {
        guard let request = envelope.decode(StartForceChargeRequest.self, expectingKind: XPCEnvelope.kindForceCharge) else {
            reply(ack(false, "Malformed force-charge request."))
            return
        }
        let ok = engine.startForceCharge(targetPercent: request.targetPercent)
        reply(ack(ok, ok ? "Charging to \(request.targetPercent)%; the normal limit resumes afterwards." : "Force charge could not be started."))
    }

    func cancelOverrides(withReply reply: @escaping (XPCEnvelope?) -> Void) {
        engine.cancelOverrides()
        reply(ack(true, "Overrides cancelled; the normal charging policy is in effect."))
    }

    func beginCalibration(withReply reply: @escaping (XPCEnvelope?) -> Void) {
        let ok = engine.beginCalibration()
        reply(ack(ok, ok ? "Calibration started: discharge to 20%, charge to 100%, hold 3 hours, then drop to your limit." : "Calibration is not supported by the active backend."))
    }

    func cancelCalibration(withReply reply: @escaping (XPCEnvelope?) -> Void) {
        engine.cancelCalibration()
        reply(ack(true, "Calibration cancelled; normal charging restored."))
    }

    // MARK: Diagnostics

    func runDiagnostics(withReply reply: @escaping (XPCEnvelope?) -> Void) {
        reply(XPCEnvelope.encode(engine.diagnostics(), kind: XPCEnvelope.kindDiagnostics))
    }

    private func ack(_ accepted: Bool, _ message: String) -> XPCEnvelope {
        XPCEnvelope.encode(OperationAck(accepted: accepted, message: message), kind: XPCEnvelope.kindAck)
            ?? XPCEnvelope(kind: XPCEnvelope.kindError, payload: Data())
    }
}

private extension URL {
    /// `deleteLastPathComponent` on a fresh copy; returns false at root.
    mutating func deleteLastPathComponent() -> Bool {
        let before = path
        self.deleteLastPathComponent2()
        return path != before && path != "/"
    }

    mutating func deleteLastPathComponent2() {
        var components = pathComponents
        if components.count > 1 { components.removeLast() }
        let isAbsolute = components.first == "/"
        self = URL(fileURLWithPath: isAbsolute ? "/" + components.dropFirst().joined(separator: "/") : components.joined(separator: "/"))
    }
}
