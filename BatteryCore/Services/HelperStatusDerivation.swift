import Foundation

/// Pure derivation of the GUI-side helper status from a status response.
///
/// The bug this pins down: after an in-place app upgrade with the GUI left
/// running, the (current) daemon answered status normally — so the dashboard
/// tiles read "Active & verified" — while the same response's version
/// mismatch set `helperStatus = .outdated`, which rendered as a "Privileged
/// helper required / Repair Helper" banner. Both cannot be true, and the
/// offered action (repair) cannot fix the actual problem, which is that the
/// RUNNING PROCESS is the outdated component and must be relaunched.
///
/// Rules encoded here:
/// - A stale process (bundle replaced after launch) is the upgrade case:
///   the helper itself is fine, so status reads `.running` and the UI
///   surfaces the dedicated "reopen the app" banner instead.
/// - Otherwise a daemon version different from the one this build expects
///   is `.outdated`.
/// - A matching version on a healthy response is `.running`.
public enum HelperStatusDerivation {

    /// Derive the helper status for the GUI from client-side facts.
    ///
    /// - Parameters:
    ///   - isStaleProcess: this GUI process predates the app bundle on disk
    ///     (in-place upgrade while running).
    ///   - daemonVersion: the version string the daemon reported.
    ///   - expectedVersion: the version this build expects
    ///     (`BatteryXPC.expectedHelperVersion`).
    public static func helperStatus(
        isStaleProcess: Bool,
        daemonVersion: String?,
        expectedVersion: String
    ) -> HelperStatus {
        // A stale process talks to a current daemon; the mismatch is in the
        // process, not the helper. The stale banner owns the messaging.
        if isStaleProcess { return .running }
        guard let daemonVersion else {
            // No version information (older daemon builds): derive nothing —
            // the caller keeps its registration-based status.
            return .running
        }
        return daemonVersion == expectedVersion ? .running : .outdated
    }

    /// Whether the setup banner may be shown at all. It must never appear
    /// next to live "Active & verified" data from a stale-process state —
    /// that combination was the contradictory dashboard.
    public static func shouldShowSetupBanner(
        needsSetup: Bool,
        isSupported: Bool,
        isStaleProcess: Bool
    ) -> Bool {
        needsSetup && isSupported && !isStaleProcess
    }
}
