import Foundation

/// Pure decisions shared by the daemon implementation and tests. The daemon
/// remains the owner of the deadline; this type deliberately has no timers or
/// filesystem access.
public enum TemporaryOverrideDecisions {
    public static let supportedDurations: Set<TimeInterval> = [3600, 7200]

    public static func isValidDuration(_ duration: TimeInterval?) -> Bool {
        guard let duration else { return true }
        return supportedDurations.contains(duration)
    }

    public static func acceptedDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard isValidDuration(duration) else { return nil }
        return duration
    }

    public static func shouldExpire(
        override: PolicyOverride,
        expiresAt: Date?,
        now: Date
    ) -> Bool {
        guard override.isChargeOverride, let expiresAt else { return false }
        return expiresAt <= now
    }
}
