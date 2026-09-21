import XCTest
@testable import BatteryCore

final class DailyUseModelsTests: XCTestCase {
    private func readings(
        cycle: Int = 42,
        max: Int = 4_000,
        design: Int = 5_000,
        temp: Double? = 31
    ) -> BatteryReadings {
        BatteryReadings(
            percentage: 80, isCharging: true, isExternalConnected: true,
            condition: .normal, cycleCount: cycle,
            currentCapacitymAh: 3_200, maxCapacitymAh: max,
            designCapacitymAh: design, voltagemV: 12_000,
            amperageMA: 1_000, temperatureC: temp
        )
    }

    func testHealthSummaryCalculatesCapacityRatioAndState() {
        let summary = BatteryHealthSummary(readings: readings())
        XCTAssertEqual(summary.capacityRatioPercent, 80)
        XCTAssertEqual(summary.cycleCount, 42)
        XCTAssertEqual(summary.chargingState, "Charging")
        XCTAssertEqual(summary.temperatureC, 31)
    }

    func testHealthSummaryDoesNotTurnMissingTelemetryIntoZero() {
        let summary = BatteryHealthSummary(readings: readings(cycle: 0, max: 0, design: 0, temp: nil))
        XCTAssertNil(summary.cycleCount)
        XCTAssertNil(summary.fullChargeCapacitymAh)
        XCTAssertNil(summary.designCapacitymAh)
        XCTAssertNil(summary.capacityRatioPercent)
        XCTAssertNil(summary.temperatureC)
    }

    func testHealthSummaryRejectsMalformedTemperature() {
        let summary = BatteryHealthSummary(readings: readings(temp: 999))
        XCTAssertNil(summary.temperatureC)
    }

    func testNamedPresetsUseExistingPolicyShape() {
        XCTAssertEqual(ChargePreset.daily.policy, FixedChargeLimit.policy(upper: 80, resume: 70))
        XCTAssertEqual(ChargePreset.batterySaver.policy, FixedChargeLimit.policy(upper: 70, resume: 60))
        XCTAssertEqual(ChargePreset.chronicallyPluggedIn.policy, FixedChargeLimit.policy(upper: 50))
        XCTAssertTrue(ChargePreset.chronicallyPluggedIn.explanation.contains("high voltage"))
        XCTAssertEqual(ChargePreset.fullCharge.policy, ChargingPolicy.passthrough())
        XCTAssertNil(ChargePreset.custom.policy)
    }

    func testPresetMatchingDoesNotConfuseCustomPolicy() {
        XCTAssertEqual(ChargePreset.matching(policy: FixedChargeLimit.policy(upper: 80, resume: 70)), .daily)
        XCTAssertEqual(ChargePreset.matching(policy: FixedChargeLimit.policy(upper: 50)), .chronicallyPluggedIn)
        XCTAssertEqual(ChargePreset.matching(policy: FixedChargeLimit.policy(upper: 66, resume: 55)), .custom)
        XCTAssertEqual(ChargePreset.matching(policy: .passthrough()), .fullCharge)
    }

    func testHistoryIsBoundedAndClearable() {
        let history = LocalEventHistory(maximumCount: 2)
        history.append(BatteryControlEvent(kind: "a", detail: "1"))
        history.append(BatteryControlEvent(kind: "b", detail: "2"))
        history.append(BatteryControlEvent(kind: "c", detail: "3"))
        XCTAssertEqual(history.snapshot().map(\.kind), ["b", "c"])
        history.clear()
        XCTAssertTrue(history.snapshot().isEmpty)
    }

    func testCorruptHistoryFallsBackToEmpty() {
        let history = LocalEventHistory.decode(Data("not json".utf8))
        XCTAssertTrue(history.snapshot().isEmpty)
    }

    func testTemporaryOverrideAcceptsOnlyOneOrTwoHours() {
        XCTAssertEqual(TemporaryOverrideDecisions.acceptedDuration(3600), 3600)
        XCTAssertEqual(TemporaryOverrideDecisions.acceptedDuration(7200), 7200)
        XCTAssertNil(TemporaryOverrideDecisions.acceptedDuration(1800))
        XCTAssertNil(TemporaryOverrideDecisions.acceptedDuration(nil))
    }

    func testTemporaryOverrideExpiresOnlyWhenDaemonDeadlinePasses() {
        let start = Date(timeIntervalSince1970: 100)
        let active = PolicyOverride.forceCharge(targetPercent: 100)
        XCTAssertFalse(TemporaryOverrideDecisions.shouldExpire(override: active, expiresAt: start.addingTimeInterval(3600), now: start.addingTimeInterval(3599)))
        XCTAssertTrue(TemporaryOverrideDecisions.shouldExpire(override: active, expiresAt: start.addingTimeInterval(3600), now: start.addingTimeInterval(3600)))
        XCTAssertFalse(TemporaryOverrideDecisions.shouldExpire(override: .none, expiresAt: start, now: start.addingTimeInterval(1)))
    }

    func testStoredStateRoundTripsNewOverrideMetadata() throws {
        let state = PolicyStore.StoredState(
            policy: FixedChargeLimit.policy(upper: 80, resume: 70),
            override: .forceCharge(targetPercent: 100),
            overrideExpiresAt: Date(timeIntervalSince1970: 500),
            overridePreviousPolicy: FixedChargeLimit.policy(upper: 70, resume: 60)
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PolicyStore.StoredState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.overrideExpiresAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(decoded.overridePreviousPolicy, FixedChargeLimit.policy(upper: 70, resume: 60))
    }

    func testSnapshotMeaningfulEqualityIgnoresPollingTimestamp() {
        let readings = readings()
        let first = BatteryStatusSnapshot(readings: readings, activePolicy: .passthrough(), controlIsVerified: false, activeBackendID: "fallback", capabilities: .unsupported, helperStatus: .running, timestamp: Date(timeIntervalSince1970: 1))
        let second = BatteryStatusSnapshot(readings: readings, activePolicy: .passthrough(), controlIsVerified: false, activeBackendID: "fallback", capabilities: .unsupported, helperStatus: .running, timestamp: Date(timeIntervalSince1970: 2))
        XCTAssertTrue(first.meaningfullyEquals(second))
    }

    func testEventTransitionsSuppressEqualSnapshotsAndRecordRealChanges() {
        let readings = BatteryReadings(
            percentage: 80, isCharging: false, isExternalConnected: true,
            condition: .normal, cycleCount: 1, currentCapacitymAh: 4_000,
            maxCapacitymAh: 4_500, designCapacitymAh: 5_000, voltagemV: 12_000,
            amperageMA: 0, temperatureC: nil
        )
        let old = BatteryStatusSnapshot(
            readings: readings, activePolicy: .passthrough(), controlIsVerified: false,
            activeBackendID: "fallback", capabilities: .unsupported, helperStatus: .running
        )
        let newer = BatteryStatusSnapshot(
            readings: readings, activePolicy: FixedChargeLimit.policy(upper: 80, resume: 70),
            controlIsVerified: true, activeBackendID: "firmware-limit", capabilities: .unsupported,
            helperStatus: .running
        )
        XCTAssertTrue(EventTransitions.events(from: old, to: old).isEmpty)
        let events = EventTransitions.events(from: old, to: newer)
        XCTAssertTrue(events.contains { $0.kind == "charge-limit changed" })
        XCTAssertTrue(events.contains { $0.kind == "hardware verification succeeded" })
        XCTAssertTrue(events.contains { $0.kind == "hardware capability changed" })
    }

    func testUninstallDataChoiceIsExplicit() {
        XCTAssertEqual(UninstallDataChoice.allCases.count, 2)
        XCTAssertEqual(UninstallDataChoice.removeData.title, "Remove BatteryControl and its local data")
        XCTAssertEqual(UninstallDataChoice.keepData.title, "Remove BatteryControl but keep settings/history")
    }

    func testUninstallRequestDefaultsToRemovingPrivilegedCLIComponent() {
        XCTAssertEqual(UninstallRequest(), UninstallRequest(removeCLI: true))
    }

    func testSupportBundleContainsOnlyDeclaredContent() throws {
        let event = BatteryControlEvent(kind: "limit changed", detail: "80%")
        let bundle = SupportBundleManifest(appVersion: "1.3.0", compatibilityReport: nil, events: [event])
        let object = try JSONSerialization.jsonObject(with: bundle.jsonData()) as? [String: Any]
        XCTAssertEqual(object?.keys.sorted(), ["appVersion", "events"])
        let json = String(data: try bundle.jsonData(), encoding: .utf8)!
        XCTAssertFalse(json.contains("/Users/"))
        XCTAssertFalse(json.contains("serial"))
    }

    func testSupportBundleRedactsUserPathLikeEventDetails() throws {
        let event = BatteryControlEvent(kind: "diagnostic", detail: "opened /Users/alice/private-notes.txt")
        let bundle = SupportBundleManifest(appVersion: "1.3.0", compatibilityReport: nil, events: [event])
        let json = String(data: try bundle.jsonData(), encoding: .utf8)!
        XCTAssertFalse(json.contains("alice"))
        XCTAssertTrue(json.contains("<redacted>"))
    }
}
