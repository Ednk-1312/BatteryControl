import Foundation

/// An entry in the diagnostics log — human-readable by design.
public struct DiagnosticEntry: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var severity: Severity
    public var operation: String
    public var backendID: String?
    public var message: String

    public enum Severity: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    public init(
        timestamp: Date = Date(),
        severity: Severity,
        operation: String,
        backendID: String? = nil,
        message: String
    ) {
        self.timestamp = timestamp
        self.severity = severity
        self.operation = operation
        self.backendID = backendID
        self.message = message
    }
}

/// Builds the structured "what actually happened" explanation shown in the UI
/// when a control operation fails or cannot be verified.
public enum ControlErrorExplainer {

    /// A complete, user-facing explanation of a failed operation.
    public struct Explanation: Codable, Equatable, Sendable {
        public var operation: String
        public var backendID: String
        public var error: String
        public var verificationResult: String
        public var suggestedNextAction: String

        public init(
            operation: String,
            backendID: String,
            error: String,
            verificationResult: String,
            suggestedNextAction: String
        ) {
            self.operation = operation
            self.backendID = backendID
            self.error = error
            self.verificationResult = verificationResult
            self.suggestedNextAction = suggestedNextAction
        }
    }

    /// Produce an explanation from a failed control attempt.
    public static func explain(_ attempt: ControlAttemptResult, suggestedNextAction: String) -> Explanation {
        Explanation(
            operation: "\(attempt.action.displayName) via \(attempt.backendID)",
            backendID: attempt.backendID,
            error: attempt.errorText ?? "The state change could not be verified.",
            verificationResult: attempt.verified
                ? "Verified"
                : "Not verified: \(attempt.verificationDetail)",
            suggestedNextAction: suggestedNextAction
        )
    }
}

extension ChargingAction {
    public var displayName: String {
        switch self {
        case .normal: return "Restore normal charging"
        case .inhibitCharging: return "Pause charging at limit"
        case .forceDischarge: return "Force discharge"
        case .hold: return "Hold current state"
        }
    }
}
