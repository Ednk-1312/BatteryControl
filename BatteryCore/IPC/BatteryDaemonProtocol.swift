import Foundation

/// The XPC interface the privileged daemon exports. Both processes share
/// this definition through BatteryCore; the runtime matches the ObjC
/// protocol by name across the connection.
///
/// Every mutating method takes an XPCEnvelope carrying a validated request
/// struct. No raw hardware primitives are exposed.
@objc public protocol BatteryDaemonProtocol {
    func getStatus(withReply reply: @escaping (XPCEnvelope?) -> Void)
    func applyPolicy(_ envelope: XPCEnvelope, withReply reply: @escaping (XPCEnvelope?) -> Void)
    func startForceDischarge(_ envelope: XPCEnvelope, withReply reply: @escaping (XPCEnvelope?) -> Void)
    func startForceCharge(_ envelope: XPCEnvelope, withReply reply: @escaping (XPCEnvelope?) -> Void)
    func cancelOverrides(withReply reply: @escaping (XPCEnvelope?) -> Void)
    func beginCalibration(withReply reply: @escaping (XPCEnvelope?) -> Void)
    func cancelCalibration(withReply reply: @escaping (XPCEnvelope?) -> Void)
    func runDiagnostics(withReply reply: @escaping (XPCEnvelope?) -> Void)
    func exportCompatibilityReport(withReply reply: @escaping (XPCEnvelope?) -> Void)
    func installCompatibilityDatabase(_ envelope: XPCEnvelope, withReply reply: @escaping (XPCEnvelope?) -> Void)
    func uninstall(_ envelope: XPCEnvelope, withReply reply: @escaping (XPCEnvelope?) -> Void)
}
