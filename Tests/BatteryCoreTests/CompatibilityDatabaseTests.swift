import XCTest
@testable import BatteryCore

/// Tests for the distributable compatibility database and the tier write
/// gate. These lock in the safe-by-default behavior: unknown firmware
/// never receives speculative SMC writes, and a broken database entry can
/// never poison the rest.
final class CompatibilityDatabaseTests: XCTestCase {

    override func tearDown() {
        FirmwareProfileLibrary.resetDatabase()
        super.tearDown()
    }

    private var repoDatabaseURL: URL {
        // Tests run from DerivedData; locate the repo root by walking up
        // until Support/CompatibilityDatabase.json is found.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Support/CompatibilityDatabase.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        preconditionFailure("Support/CompatibilityDatabase.json not found from test source path")
    }

    // MARK: The shipped seed database

    func testShippedSeedDatabaseLoadsAndContainsVerifiedProfile() throws {
        let count = try FirmwareProfileLibrary.loadDatabase(atPath: repoDatabaseURL.path)
        XCTAssertGreaterThanOrEqual(count, 2, "the seed database should carry at least the two seed profiles")
        // Overriding a built-in with the same id leaves it present exactly once.
        let ids = FirmwareProfileLibrary.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate profile ids after database load")
        XCTAssertTrue(ids.contains("apple-silicon-20xxx-firmware-limit"))
        // Classification of the verified machine still works.
        let identity = PlatformIdentity(
            chipGeneration: .m3, isAppleSilicon: true,
            macModelIdentifier: "Mac15,13", marketingModelName: "x",
            osMajor: 15, osMinor: 8, osPatch: 0, osBuild: "24H23",
            systemFirmwareBuild: "20457.1.29"
        )
        XCTAssertEqual(
            FirmwareProfileLibrary.classify(identity: identity, detectedFamily: .firmwareLimit, systemFirmwareBuild: "20457.1.29"),
            .verified
        )
    }

    func testExternalProfileOverridesBuiltinById() throws {
        var updated = FirmwareProfileLibrary.appleSilicon20xxxFirmwareLimit
        updated.notes = ["overridden-by-database"]
        let payload = FirmwareProfileLibrary.DatabasePayload(schemaVersion: 1, profiles: [updated])
        try FirmwareProfileLibrary.activateDatabase(payload)
        let matches = FirmwareProfileLibrary.all.filter { $0.id == updated.id }
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.notes, ["overridden-by-database"])
    }

    func testInvalidProfileRejectedIndividually() {
        var bad = FirmwareProfileLibrary.appleSilicon20xxxFirmwareLimit
        bad.id = "bad-profile"
        bad.keyProfile.firmwareLimitKeys = []
        bad.keyProfile.chargingKeys = []
        bad.keyProfile.adapterKeys = []
        let good = FirmwareProfileLibrary.appleSiliconLegacySMCInhibit
        let payload = FirmwareProfileLibrary.DatabasePayload(schemaVersion: 1, profiles: [bad, good])
        // The invalid entry rejects the batch (fail-closed)…
        XCTAssertThrowsError(try FirmwareProfileLibrary.activateDatabase(payload)) { error in
            guard case FirmwareProfileLibrary.DatabaseError.invalidProfile(let id, _) = error else {
                return XCTFail("expected invalidProfile, got \(error)")
            }
            XCTAssertEqual(id, "bad-profile")
        }
        // …and nothing from the rejected batch stays active.
        XCTAssertTrue(FirmwareProfileLibrary.all.filter { $0.id == "bad-profile" }.isEmpty)
    }

    func testUnsupportedSchemaRejectedWholesale() {
        let payload = FirmwareProfileLibrary.DatabasePayload(schemaVersion: 999, profiles: [])
        XCTAssertThrowsError(try FirmwareProfileLibrary.activateDatabase(payload)) { error in
            XCTAssertEqual(error as? FirmwareProfileLibrary.DatabaseError, .unsupportedSchema(999))
        }
        // Built-ins remain active after a failed load.
        XCTAssertTrue(FirmwareProfileLibrary.all.contains { $0.id == "apple-silicon-20xxx-firmware-limit" })
    }

    func testMissingDatabaseFileIsNotAnError() throws {
        let count = try FirmwareProfileLibrary.loadDatabase(atPath: "/nonexistent/bc-compat.json")
        XCTAssertEqual(count, 0)
    }

    // MARK: The write gate (safe by default)

    func testWriteGateAllowsOnlyEvidenceBackedTiers() {
        XCTAssertTrue(FirmwareProfileLibrary.shouldAllowControlWrites(.verified))
        XCTAssertTrue(FirmwareProfileLibrary.shouldAllowControlWrites(.compatibleByCapability))
        XCTAssertFalse(FirmwareProfileLibrary.shouldAllowControlWrites(.untested), "novel key signatures must never receive speculative writes")
        XCTAssertFalse(FirmwareProfileLibrary.shouldAllowControlWrites(.unsupported))
    }

    func testValidationRequiresEvidenceFields() {
        var profile = FirmwareProfileLibrary.appleSilicon20xxxFirmwareLimit
        XCTAssertNil(FirmwareProfileLibrary.profileValidationProblem(profile))

        profile.evidence?.modelIdentifier = ""
        XCTAssertNotNil(FirmwareProfileLibrary.profileValidationProblem(profile))

        profile.evidence?.modelIdentifier = "Mac15,13"
        profile.evidence?.provenBehavior = []
        XCTAssertNotNil(FirmwareProfileLibrary.profileValidationProblem(profile))
    }
}
