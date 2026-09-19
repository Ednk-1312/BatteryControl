import Foundation

/// Classifies why the daemon would refuse an XPC client. Pure and testable:
/// the daemon derives the reason from its own signature checks, and the GUI
/// can reproduce the same classification from client-side facts to explain
/// itself to the user instead of silently retrying forever.
public enum XPCRejectionClassifier {

    public enum Rejection: Equatable {
        /// The running client is stale: the app bundle on disk changed (an
        /// in-place upgrade) while this process was running, so its code
        /// signature no longer matches the daemon's. The process can never
        /// reconnect — it must be relaunched.
        case staleClientAfterUpgrade
        /// The client is simply not a BatteryControl app component (same
        /// team, different app; or unsigned foreign code). Refusing it is
        /// correct and permanent.
        case foreignClient
        /// The client's signature could not be inspected at all.
        case uninspectable
    }

    /// Decide the rejection reason from the client's own facts. The daemon
    /// passes the values it just computed; tests pass synthetic ones.
    public static func classify(
        clientPath: String?,
        clientBundleID: String?,
        expectedBundleID: String
    ) -> Rejection {
        // A BatteryControl app whose bundle was replaced after launch is the
        // stale-upgrade case: the process is still running pre-upgrade code.
        if let bundleID = clientBundleID, bundleID == expectedBundleID {
            return .staleClientAfterUpgrade
        }
        // No bundle identity recoverable — can't say anything meaningful.
        guard clientBundleID != nil else { return .uninspectable }
        return .foreignClient
    }

    /// User-facing explanation for a client that keeps getting rejected.
    public static func userExplanation(for rejection: Rejection) -> String? {
        switch rejection {
        case .staleClientAfterUpgrade:
            return "BatteryControl was updated while it was running. Quit and reopen the app to reconnect to the privileged daemon."
        case .foreignClient, .uninspectable:
            return nil
        }
    }

    /// Client-side staleness check: was this process launched before the
    /// app bundle currently on disk was installed? An in-place upgrade
    /// replaces the bundle while the process runs, so the on-disk signature
    /// no longer matches the running code and the daemon will (correctly)
    /// keep rejecting its connections. The UI must say "quit and reopen"
    /// instead of promising an automatic reconnect that can never happen.
    ///
    /// Detection uses the bundle's creation time (the installer creates the
    /// payload files fresh, while mtimes are preserved from the build
    /// machine) compared against the process start time, with a small
    /// tolerance so an app launched exactly as it was installed isn't
    /// misjudged. Works even for same-version rebuilds.
    public static func isProcessStaleAfterUpgrade(
        runningProcessStart: Date,
        bundleInstallTime: Date?
    ) -> Bool {
        guard let bundleInstallTime else { return false }
        return bundleInstallTime > runningProcessStart.addingTimeInterval(1)
    }
}
