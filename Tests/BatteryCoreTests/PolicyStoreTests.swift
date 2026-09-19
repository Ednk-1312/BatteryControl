import XCTest
@testable import BatteryCore

/// Persistence tests for PolicyStore: round-trips, corrupt-store
/// quarantine, external-write reload (mtime guard), and the atomicity
/// guarantee that a stale temp file never becomes state. These run
/// against a temp-directory store — the daemon's production path
/// (/Library/Application Support/BatteryControl) is root-owned.
final class PolicyStoreTests: XCTestCase {

    private var dir: URL!
    private var storePath: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bc-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storePath = dir.appendingPathComponent("policy.json").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makePolicy(upper: Int = 80, lower: Int = 70) -> ChargingPolicy {
        ChargingPolicy(mode: .hysteresis, upperLimit: upper, lowerLimit: lower)
    }

    // MARK: Round-trip

    func testFreshStoreStartsAtDefaults() {
        let store = PolicyStore(path: storePath)
        XCTAssertEqual(store.state.policy.mode, .passthrough)
        XCTAssertEqual(store.state.override, .none)
        XCTAssertNil(store.state.calibration)
        // The default store is not written to disk until the first update.
        XCTAssertFalse(FileManager.default.fileExists(atPath: storePath))
    }

    func testUpdatePersistsPolicyAndOverride() {
        var store = PolicyStore(path: storePath)
        store.update {
            $0.policy = makePolicy(upper: 60, lower: 50)
            $0.override = .forceDischarge(targetPercent: 55, floorPercent: 20, belowFloorConsent: true)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: storePath))

        // A brand-new instance (daemon restart) must reconstruct both.
        store = PolicyStore(path: storePath)
        XCTAssertEqual(store.state.policy.upperLimit, 60)
        XCTAssertEqual(store.state.policy.effectiveLowerLimit, 50)
        XCTAssertEqual(
            store.state.override,
            .forceDischarge(targetPercent: 55, floorPercent: 20, belowFloorConsent: true),
            "Consent travels with the persisted override for the active session"
        )
    }

    func testOverrideClearingPersists() {
        var store = PolicyStore(path: storePath)
        store.update { $0.override = .forceCharge(targetPercent: 100) }
        store.update { $0.override = .none }

        store = PolicyStore(path: storePath)
        XCTAssertEqual(store.state.override, .none)
    }

    // MARK: Corrupt store

    func testCorruptStoreIsQuarantinedAndDefaultsApply() throws {
        try Data("not json at all {".utf8).write(to: URL(fileURLWithPath: storePath))
        let store = PolicyStore(path: storePath)

        // Defaults, never a decode failure.
        XCTAssertEqual(store.state.policy.mode, .passthrough)

        // The corrupt file must still exist for inspection, under a
        // quarantine name — not silently overwritten.
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(
            contents.contains { $0.hasPrefix("policy.json.corrupt-") },
            "corrupt store must be quarantined, contents: \(contents)"
        )
        let quarantined = contents.first { $0.hasPrefix("policy.json.corrupt-") }!
        XCTAssertEqual(
            try String(contentsOfFile: dir.appendingPathComponent(quarantined).path, encoding: .utf8),
            "not json at all {"
        )
    }

    func testCorruptStoreDoesNotBlockNewWrites() {
        try? Data("garbage".utf8).write(to: URL(fileURLWithPath: storePath))
        let store = PolicyStore(path: storePath)
        store.update { $0.policy = makePolicy(upper: 70, lower: 60) }

        // Recovery: the store must be fully usable afterward.
        let reloaded = PolicyStore(path: storePath)
        XCTAssertEqual(reloaded.state.policy.upperLimit, 70)
    }

    // MARK: External writes (mtime-guarded reload)

    func testExternalWriteIsReloadedByRunningStore() throws {
        let store = PolicyStore(path: storePath)
        store.update { $0.policy = makePolicy(upper: 80, lower: 78) }

        // Recovery tooling writes the file behind the daemon's back.
        let external = PolicyStore(path: storePath)
        external.update { $0.policy = makePolicy(upper: 60, lower: 50) }

        // Force a distinct mtime so the guard cannot be fooled by same-
        // second granularity.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: storePath
        )

        XCTAssertEqual(
            store.state.policy.upperLimit, 60,
            "a running store must observe external policy writes (recovery path)"
        )
    }

    // MARK: Atomicity / interrupted writes

    func testStaleTempFileNeverBecomesState() {
        let store = PolicyStore(path: storePath)
        store.update { $0.policy = makePolicy(upper: 80, lower: 70) }

        // Simulate a crash mid-write: a leftover .tmp file with junk.
        let tmp = storePath + ".tmp-\(UUID().uuidString)"
        try? Data("truncated".utf8).write(to: URL(fileURLWithPath: tmp))

        let reloaded = PolicyStore(path: storePath)
        XCTAssertEqual(
            reloaded.state.policy.upperLimit, 80,
            "a stale temp file must never be adopted as state"
        )
        try? FileManager.default.removeItem(atPath: tmp)
    }

    func testAtomicSaveLeavesNoTempFilesBehind() {
        let store = PolicyStore(path: storePath)
        for i in 0..<5 {
            store.update { $0.policy = makePolicy(upper: 60 + i, lower: 50 + i) }
        }
        let contents = try! FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(
            contents.allSatisfy { !$0.contains(".tmp-") },
            "completed saves must clean up temp files, contents: \(contents)"
        )
    }
}
