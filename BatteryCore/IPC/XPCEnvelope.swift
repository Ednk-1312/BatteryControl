import Foundation

/// NSSecureCoding envelope carrying JSON-encoded BatteryCore DTOs across
/// XPC. Using one envelope keeps the shared models plain `Codable` structs
/// (testable, no NSObject boilerplate) while satisfying the secure-coding
/// requirements of NSXPCConnection. The `kind` discriminator makes decoding
/// strict: the daemon rejects messages whose kind does not match the type
/// expected at the decode site.
public final class XPCEnvelope: NSObject, NSSecureCoding, @unchecked Sendable {

    public static let supportsSecureCoding = true

    public static let kindStatus = "status"
    public static let kindApplyPolicy = "applyPolicy"
    public static let kindForceDischarge = "forceDischarge"
    public static let kindForceCharge = "forceCharge"
    public static let kindCancelOverrides = "cancelOverrides"
    public static let kindCalibrationStart = "calibrationStart"
    public static let kindCalibrationCancel = "calibrationCancel"
    public static let kindDiagnostics = "diagnostics"
    public static let kindCompatibilityReport = "compatibilityReport"
    public static let kindDatabaseInstall = "databaseInstall"
    public static let kindAck = "ack"
    public static let kindError = "error"

    public let kind: String
    public let payload: Data

    public init(kind: String, payload: Data) {
        self.kind = kind
        self.payload = payload
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let kind = coder.decodeObject(of: NSString.self, forKey: "kind") as String?,
              let payload = coder.decodeObject(of: NSData.self, forKey: "payload") as Data?
        else { return nil }
        self.kind = kind as String
        self.payload = payload
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(kind, forKey: "kind")
        coder.encode(payload, forKey: "payload")
    }

    /// Encode a Codable payload into an envelope of the given kind.
    public static func encode<T: Encodable>(_ value: T, kind: String) -> XPCEnvelope? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return XPCEnvelope(kind: kind, payload: data)
    }

    /// Decode the payload as `T`, failing unless the kind matches.
    public func decode<T: Decodable>(_ type: T.Type, expectingKind expectedKind: String) -> T? {
        guard kind == expectedKind else { return nil }
        return try? JSONDecoder().decode(T.self, from: payload)
    }
}
