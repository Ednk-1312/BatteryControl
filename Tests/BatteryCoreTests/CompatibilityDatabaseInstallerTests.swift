import XCTest
@testable import BatteryCore

/// Tests for the compatibility-database install path: whole-payload
/// validation policy, atomic install + activation, and database reset
/// hygiene. The engine's re-classification hook is exercised through the
/// installer's pure parts here; the XPC wiring is covered by its own tests.
final class CompatibilityDatabaseInstallerTests: XCTestCase {

    override func tearDown() {
        FirmwareProfileLibrary.resetDatabase()
        super.tearDown()
    }

    private func makeProfile(
        id: String = "community-m2-test-machine",
        family: String = "firmwareLimit",
        withEvidence: Bool = true
    ) -> FirmwareProfile {
        FirmwareProfile(
            id: id,
            title: "Community-verified profile",
            controlFamily: family,
            keyProfile: SMCKeyProfile(
                chargingKeys: [],
                adapterKeys: ["CHIE"],
                firmwareLimitKeys: ["bfF0", "bfD0", "bfE0"],
                chargingInhibitValue: 0,
                adapterCutValue: 0x08,
                firmwareLimitActivation: (off: 0x00, active: 0x02),
                limitPercentEncodingIsLittleEndian: true,
                requiresDeactivateBeforeWrite: true
            ),
            evidence: withEvidence
                ? VerifiedEvidence(
                    chip: "Apple M2",
                    modelIdentifier: "Mac14,2",
                    systemFirmwareBuild: "10151.41.12",
                    osVersion: "macOS 15.3",
                    osBuild: "24D60",
                    provenBehavior: ["bfF0/bfD0/bfE0 programmed 80/70 and read back matching"],
                    verifiedOn: "2026-09-18"
                )
                : nil,
            notes: []
        )
    }

    // MARK: Payload validation

    func testValidPayloadIsAccepted() throws {
        let payload = FirmwareProfileLibrary.DatabasePayload(
            schemaVersion: 1,
            profiles: [makeProfile()]
        )
        let accepted = try CompatibilityDatabaseInstaller.validatedPayload(payload)
        XCTAssertEqual(accepted, 1)
    }

    func testUnsupportedSchemaRejectsWholePayload() {
        let payload = FirmwareProfileLibrary.DatabasePayload(
            schemaVersion: 99,
            profiles: [makeProfile()]
        )
        XCTAssertThrowsError(try CompatibilityDatabaseInstaller.validatedPayload(payload)) { error in
            guard case CompatibilityDatabaseInstaller.InstallError.databaseInvalid(let reason) = error else {
                return XCTFail("expected databaseInvalid")
            }
            XCTAssertTrue(reason.contains("schema"), "reason should mention schema: \(reason)")
        }
    }

    func testEmptyProfilesReject() {
        let payload = FirmwareProfileLibrary.DatabasePayload(schemaVersion: 1, profiles: [])
        XCTAssertThrowsError(try CompatibilityDatabaseInstaller.validatedPayload(payload)) { error in
            guard case CompatibilityDatabaseInstaller.InstallError.databaseInvalid(let reason) = error else {
                return XCTFail("expected databaseInvalid")
            }
            XCTAssertTrue(reason.contains("no profiles"))
        }
    }

    func testOneInvalidProfileRejectsWholePayload() {
        // A verified profile with no recorded model/firmware is invalid.
        let bad = makeProfile(id: "bad-profile", withEvidence: true)
        var badWithEmptyEvidence = bad
        badWithEmptyEvidence.evidence?.modelIdentifier = ""
        let payload = FirmwareProfileLibrary.DatabasePayload(
            schemaVersion: 1,
            profiles: [makeProfile(id: "good-profile"), badWithEmptyEvidence]
        )
        // Unlike startup loading (per-profile tolerance), an install rejects
        // the WHOLE payload so the caller can fix and retry.
        XCTAssertThrowsError(try CompatibilityDatabaseInstaller.validatedPayload(payload))
        // And nothing was activated.
        XCTAssertTrue(FirmwareProfileLibrary.all.count == FirmwareProfileLibrary.builtIn.count)
    }

    func testEmptyKeyProfileRejects() {
        let profile = FirmwareProfile(
            id: "no-keys",
            title: "Broken",
            controlFamily: "firmwareLimit",
            keyProfile: SMCKeyProfile(
                chargingKeys: [], adapterKeys: [], firmwareLimitKeys: [],
                chargingInhibitValue: 0, adapterCutValue: 0,
                firmwareLimitActivation: nil,
                limitPercentEncodingIsLittleEndian: false,
                requiresDeactivateBeforeWrite: false
            ),
            evidence: nil,
            notes: []
        )
        let payload = FirmwareProfileLibrary.DatabasePayload(schemaVersion: 1, profiles: [profile])
        XCTAssertThrowsError(try CompatibilityDatabaseInstaller.validatedPayload(payload)) { error in
            guard case CompatibilityDatabaseInstaller.InstallError.databaseInvalid(let reason) = error else {
                return XCTFail("expected databaseInvalid")
            }
            XCTAssertTrue(reason.contains("no SMC keys"))
        }
    }

    // MARK: Install + activation

    func testInstallWritesFileAndActivatesProfiles() throws {
        let dir = NSTemporaryDirectory() + "bc-dbtest-\(UUID().uuidString)"
        let path = dir + "/compatibility.json"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let payload = FirmwareProfileLibrary.DatabasePayload(
            schemaVersion: 1,
            profiles: [makeProfile()]
        )
        let result = try CompatibilityDatabaseInstaller.install(payload, toPath: path)
        XCTAssertEqual(result.acceptedProfiles, 1)
        XCTAssertEqual(result.installedPath, path)
        // Activation happened in-process: the profile is now visible.
        XCTAssertTrue(FirmwareProfileLibrary.all.contains { $0.id == "community-m2-test-machine" })

        // The written file round-trips through the startup loader.
        let loaded = try FirmwareProfileLibrary.loadDatabase(atPath: path)
        XCTAssertEqual(loaded, 1)
    }

    func testInstallOfInvalidPayloadWritesNothing() {
        let dir = NSTemporaryDirectory() + "bc-dbtest-\(UUID().uuidString)"
        let path = dir + "/compatibility.json"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let payload = FirmwareProfileLibrary.DatabasePayload(schemaVersion: 99, profiles: [makeProfile()])
        XCTAssertThrowsError(try CompatibilityDatabaseInstaller.install(payload, toPath: path))
        // No file was created.
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        // And nothing was activated.
        XCTAssertTrue(FirmwareProfileLibrary.all.count == FirmwareProfileLibrary.builtIn.count)
    }

    func testReinstallReplacesExistingFile() throws {
        let dir = NSTemporaryDirectory() + "bc-dbtest-\(UUID().uuidString)"
        let path = dir + "/compatibility.json"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let first = FirmwareProfileLibrary.DatabasePayload(schemaVersion: 1, profiles: [makeProfile(id: "first")])
        _ = try CompatibilityDatabaseInstaller.install(first, toPath: path)

        let second = FirmwareProfileLibrary.DatabasePayload(schemaVersion: 1, profiles: [makeProfile(id: "second")])
        _ = try CompatibilityDatabaseInstaller.install(second, toPath: path)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode(FirmwareProfileLibrary.DatabasePayload.self, from: data)
        XCTAssertEqual(decoded.profiles.map(\.id), ["second"])
    }
}
