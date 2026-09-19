import Foundation

/// Installing a compatibility database on a live system. The database file
/// is root-owned; the ONLY writer is the privileged daemon, which receives
/// the payload over the already-authenticated XPC connection, validates it,
/// and activates it atomically. No client can write the file directly.
///
/// The database broadens *recognition* (evidence-backed classification for
/// machines the built-in profiles predate). It never grants control: the
/// runtime SMC capability probe and per-write verification decide that on
/// every machine, independent of the database.
public enum CompatibilityDatabaseInstaller {

    /// Errors from the install attempt. All are honest and specific — the
    /// caller reports them verbatim instead of a generic failure.
    public enum InstallError: Error, Equatable {
        case databaseInvalid(String)
    }

    /// Validate and stage a database payload. Pure (no filesystem), fully
    /// unit-testable. Returns the number of accepted profiles; throws with
    /// the specific reason when the payload is unusable.
    ///
    /// Policy: an unsupported schema or ANY invalid profile rejects the
    /// WHOLE payload. Unlike startup loading (which tolerates a bad record
    /// among good ones from an already-trusted file), an install request is
    /// untrusted input: the caller should fix the payload and retry, not
    /// silently lose evidence.
    public static func validatedPayload(
        _ payload: FirmwareProfileLibrary.DatabasePayload
    ) throws -> Int {
        guard payload.schemaVersion == FirmwareProfileLibrary.databaseSchemaVersion else {
            throw InstallError.databaseInvalid(
                "schema version \(payload.schemaVersion) is not supported by this daemon (expects \(FirmwareProfileLibrary.databaseSchemaVersion)) — update BatteryControl first"
            )
        }
        guard !payload.profiles.isEmpty else {
            throw InstallError.databaseInvalid("the database contains no profiles")
        }
        for profile in payload.profiles {
            if let problem = FirmwareProfileLibrary.profileValidationProblem(profile) {
                throw InstallError.databaseInvalid("profile '\(profile.id)': \(problem)")
            }
        }
        return payload.profiles.count
    }

    /// Result of a completed install.
    public struct InstallResult: Codable, Equatable, Sendable {
        /// Profiles accepted into the running daemon's library.
        public var acceptedProfiles: Int
        /// Total built-in + external profiles now active.
        public var totalProfiles: Int
        /// Path the database was written to.
        public var installedPath: String

        public init(acceptedProfiles: Int, totalProfiles: Int, installedPath: String) {
            self.acceptedProfiles = acceptedProfiles
            self.totalProfiles = totalProfiles
            self.installedPath = installedPath
        }
    }

    /// The daemon-side install: validate → encode → atomic replace →
    /// activate in-process. Returns the result; throws `InstallError` when
    /// the payload is invalid (nothing is written) and rethrows filesystem
    /// errors from the atomic replace.
    @discardableResult
    public static func install(
        _ payload: FirmwareProfileLibrary.DatabasePayload,
        toPath path: String
    ) throws -> InstallResult {
        let accepted = try validatedPayload(payload)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        // Atomic replace: an interrupted install can never leave a truncated
        // file that startup would then reject (built-in fallback would still
        // apply, but the installed database would silently vanish).
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let tempPath = path + ".tmp-\(getpid())"
        try data.write(to: URL(fileURLWithPath: tempPath), options: .atomic)
        _ = try FileManager.default.replaceItemAt(
            URL(fileURLWithPath: path),
            withItemAt: URL(fileURLWithPath: tempPath)
        )

        try FirmwareProfileLibrary.activateDatabase(payload)
        return InstallResult(
            acceptedProfiles: accepted,
            totalProfiles: FirmwareProfileLibrary.all.count,
            installedPath: path
        )
    }
}
