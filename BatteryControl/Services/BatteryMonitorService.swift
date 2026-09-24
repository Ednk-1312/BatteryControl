import AppKit
import BatteryCore
import Combine
import Foundation
import os

/// Publishes live battery readings to the UI from the app process (fast,
/// no privileges needed) while the authoritative snapshot comes from the
/// daemon.
final class BatteryMonitorService: ObservableObject {

    @Published private(set) var readings: BatteryReadings?

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reading = PlatformDetector.readBatteryFromIOKit()
            DispatchQueue.main.async {
                // Equal readings are the common case on an idle machine;
                // skip the publish instead of invalidating SwiftUI views
                // every 15 seconds for identical data.
                guard self?.readings != reading else { return }
                self?.readings = reading
            }
        }
    }
}

/// App-facing view of the whole system: daemon snapshot, platform gate,
/// helper status, and user actions. All UI subscribes to this.
@MainActor
final class AppState: ObservableObject {

    enum Route: Hashable {
        case dashboard
        case charging
        case discharge
        case calibration
        case info
        case diagnostics
        case settings
    }

    // MARK: Published state

    @Published var route: Route = .dashboard
    @Published var snapshot: BatteryStatusSnapshot?
    @Published var lastAck: OperationAck?
    @Published var lastAckMessage: String?
    @Published var platform: PlatformIdentity
    @Published var helperStatus: HelperStatus
    @Published var installProgress: String?
    @Published var isInstalling = false
    @Published var uninstallMessage: String?
    @Published var uninstallSucceeded = false

    /// Daily-use local history is bounded and never leaves this Mac.
    @Published private(set) var localHistory: LocalEventHistory

    /// Set at launch: this process predates the app bundle now on disk (an
    /// in-place upgrade happened while it ran). The daemon will keep
    /// rejecting this process's XPC connections — the UI must offer a
    /// relaunch instead of promising an automatic reconnect.
    @Published private(set) var isStaleProcess = false

    /// From the setup flow: whether first-run setup completed.
    @Published var setupComplete: Bool = UserDefaults.standard.bool(forKey: "setupComplete")

    // MARK: Update check (passive, no auto-install)

    /// A newer GitHub release, when the last check found one. Filled by the
    /// passive daily check; updating is always a deliberate user action.
    @Published private(set) var availableUpdate: UpdateCheck.Release?
    @Published private(set) var updateCheckFailed = false

    private static let updateCheckEnabledKey = "updateCheckEnabled"
    private static let updateCheckLastCompletedKey = "updateCheckLastCompleted"

    /// Whether the passive update check is enabled. Default on with a
    /// visible setting (the audience expects a plain link, not silence);
    /// disabling it stops all network requests. (@Published + UserDefaults,
    /// NOT @AppStorage: this class is an ObservableObject, where @AppStorage
    /// does not publish changes to observing views.)
    @Published var updateCheckEnabled: Bool = UserDefaults.standard.object(
        forKey: "updateCheckEnabled"
    ) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(updateCheckEnabled, forKey: Self.updateCheckEnabledKey)
            if !updateCheckEnabled {
                availableUpdate = nil
                updateCheckFailed = false
            }
        }
    }

    var updateCheckLastCompletedDate: Date? {
        let stored = UserDefaults.standard.double(forKey: Self.updateCheckLastCompletedKey)
        return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    private func setUpdateCheckCompleted(at date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.updateCheckLastCompletedKey)
    }

    /// One passive check: fetch the latest GitHub release and surface a
    /// link when it is newer than this build. Failures set a quiet flag and
    /// are retried on the next cadence — never aggressively, never loudly.
    func performUpdateCheckIfDue(now: Date = Date()) {
        guard updateCheckEnabled else { return }
        guard UpdateCheck.isCheckDue(lastCheck: updateCheckLastCompletedDate, now: now) else { return }
        Task {
            var request = URLRequest(url: UpdateCheck.apiLatestRelease)
            request.timeoutInterval = 15
            // No identifiers of any kind beyond what TLS itself exposes.
            request.setValue("BatteryControl/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")", forHTTPHeaderField: "User-Agent")
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let release = try UpdateCheck.parseLatestRelease(fromData: data)
                let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                let newer = UpdateCheck.isNewer(release.tagName, than: current)
                await MainActor.run {
                    self.availableUpdate = newer ? release : nil
                    self.updateCheckFailed = false
                    self.setUpdateCheckCompleted(at: now)
                }
            } catch {
                // Quiet failure; retried on the next cadence.
                await MainActor.run { self.updateCheckFailed = true }
            }
        }
    }

    /// Immediate check requested from the UI ("Check Now"): bypasses the
    /// cadence gate but still respects the enabled setting.
    func performUpdateCheckNow() {
        UserDefaults.standard.set(0.0, forKey: Self.updateCheckLastCompletedKey)
        performUpdateCheckIfDue()
    }

    let batteryMonitor = BatteryMonitorService()
    private let installer = HelperInstaller()
    private var refreshTimer: Timer?

    init() {
        platform = PlatformDetector.detect()
        localHistory = Self.loadLocalHistory()
        isStaleProcess = Self.detectStaleProcess()
        // Registration-only status: never blocks the main thread on XPC
        // (the blocking probe previously stalled launch up to ~3s when the
        // daemon was absent). The first poll fills in the live state.
        helperStatus = HelperInstaller().staticStatus(xpcDead: false)

        if !self.platform.isSupportedPlatform {
            DaemonAppLog.ui.error("Unsupported platform: \(self.platform.unsupportedReason ?? "unknown")")
        }

        poll()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
        // Passive update check: at most daily, no auto-download.
        performUpdateCheckIfDue()
    }

    /// Client-side facts for the staleness check: this process's start time
    /// and the installed bundle's creation time. The decision itself is
    /// `XPCRejectionClassifier.isProcessStaleAfterUpgrade` (unit-tested).
    private static func detectStaleProcess() -> Bool {
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &kinfo, &size, nil, 0) == 0 else { return false }
        let tv = kinfo.kp_proc.p_starttime
        let processStart = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
        let attrs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath)
        let created = attrs?[.creationDate] as? Date
        return XPCRejectionClassifier.isProcessStaleAfterUpgrade(
            runningProcessStart: processStart,
            bundleInstallTime: created
        )
    }

    /// One-click recovery from the stale-process state: start the freshly
    /// installed bundle and exit the stale process.
    func relaunchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Derived state for the UI

    var isSupported: Bool { platform.isSupportedPlatform }

    var capabilities: BatteryCapabilities {
        snapshot?.capabilities ?? .unsupported
    }

    var effectiveReadings: BatteryReadings {
        snapshot?.readings ?? batteryMonitor.readings ?? .placeholder
    }

    var healthSummary: BatteryHealthSummary {
        BatteryHealthSummary(readings: effectiveReadings)
    }

    var selectedPreset: ChargePreset {
        guard let policy = snapshot?.activePolicy else { return .custom }
        return ChargePreset.matching(policy: policy)
    }

    func apply(preset: ChargePreset) {
        guard let policy = preset.policy else { return }
        // The transition is recorded only after the daemon reports the new
        // policy in a status snapshot; selecting a button is not evidence of
        // a successful hardware operation.
        apply(policy: policy)
    }

    func recordEvent(_ kind: String, detail: String) {
        localHistory.append(BatteryControlEvent(kind: kind, detail: detail))
        persistLocalHistory()
    }

    func clearLocalHistory() {
        localHistory.clear()
        persistLocalHistory()
    }

    private static let historyURL: URL = BatteryControlUserData.applicationSupportURL()
        .appendingPathComponent("events.json")

    private static func loadLocalHistory() -> LocalEventHistory {
        guard let data = try? Data(contentsOf: historyURL) else { return LocalEventHistory() }
        return LocalEventHistory.decode(data)
    }

    private func persistLocalHistory() {
        guard let data = try? localHistory.encodedData() else { return }
        let url = Self.historyURL
        historyPersistenceQueue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Wait until all history writes queued before this call have completed.
    /// Used before deleting user data so uninstall cannot recreate the folder.
    private func flushLocalHistoryPersistence() {
        historyPersistenceQueue.sync {}
    }

    /// Concise policy summary for the menu bar. States the user's charge
    /// limit only — the lower hysteresis threshold is resume behavior, not
    /// a second "limit" (it leaked into this line as "· lower 78%").
    var controlSummary: String {
        guard let snapshot else { return helperStatusText }
        if !isSupported { return "Unsupported platform" }
        switch snapshot.activePolicy.mode {
        case .passthrough:
            return "macOS default charging"
        case .hysteresis:
            return "Charge limit \(snapshot.activePolicy.upperLimit)%"
        case .fixedTarget:
            return "Maintain about \(snapshot.activePolicy.upperLimit)%"
        }
    }

    var helperStatusText: String {
        switch helperStatus {
        case .running: return "Helper running"
        case .notInstalled: return "Helper not installed"
        case .outdated: return "Helper needs an update"
        case .notRunning: return "Helper not running"
        case .unreachable: return "Helper unreachable"
        }
    }

    var needsSetup: Bool {
        helperStatus != .running
    }

    // MARK: Polling

    /// Stale-response protection, structural: at most ONE status request is
    /// ever outstanding. Overlapping polls (10s timer, menu-bar refresh,
    /// post-command refresh) join the in-flight task instead of issuing a
    /// competing request, so two responses can never arrive out of order
    /// and a slower earlier response can never overwrite a newer one.
    private var inFlightPoll: Task<Void, Never>?

    /// Serializes local-history writes. Without this queue, a clear or a
    /// newer event can be followed by an older queued write, resurrecting
    /// deleted history; uninstall could also remove the directory while a
    /// pending write recreated it.
    private let historyPersistenceQueue = DispatchQueue(label: "com.batterycontrol.app.history-persistence")

    /// When the last command completed. A status snapshot the daemon built
    /// BEFORE this instant predates the command's effect and must not be
    /// presented as the final state (§ command/monitor race).
    private var lastCommandCompletion: Date?

    /// Bounded one-shot refresh after a stale detection: set while the
    /// freshness-triggered follow-up request is outstanding so the next
    /// completion is always applied (never triggers another re-request).
    private var freshnessRefreshInFlight = false

    /// Staleness is re-checked when a status response disagrees with the
    /// running process, not only once at launch (§ upgrade-while-running):
    /// an in-place app upgrade replaces the bundle while the GUI runs, and
    /// the launch-time detection missed it forever.
    private func recheckStaleProcessIfNeeded() {
        guard !isStaleProcess else { return }
        if Self.detectStaleProcess() {
            isStaleProcess = true
        }
    }

    func poll() {
        guard inFlightPoll == nil else { return }
        inFlightPoll = Task { [weak self] in
            let response = await DaemonXPCClient.shared.getStatus()
            guard let self else { return }
            self.inFlightPoll = nil
            self.applyStatus(response)
        }
    }

    /// Applies one status response. When the daemon could not be reached,
    /// the last snapshot is CLEARED so stale "verified" state is never
    /// presented as current — the UI falls back to local IOKit readings and
    /// an honest unavailable status until the daemon answers again.
    private func applyStatus(_ response: XPCStatusResponse?) {
        guard let response else {
            snapshot = nil
            // Registration state without an XPC probe (never blocks).
            helperStatus = HelperInstaller().staticStatus(xpcDead: true)
            freshnessRefreshInFlight = false
            return
        }
        // Command/monitor race guard: a response the daemon assembled before
        // the last command completed predates that command's effect. Skip
        // it and request one guaranteed to be newer — exactly once, so no
        // refresh loop is possible.
        if !response.isFresh(afterCommandAt: lastCommandCompletion), !freshnessRefreshInFlight {
            freshnessRefreshInFlight = true
            poll()
            return
        }
        freshnessRefreshInFlight = false
        // Only publish real changes: assigning an equal value to @Published
        // still fires objectWillChange, so an idle machine would invalidate
        // every SwiftUI view every poll forever. Equal snapshots are the
        // common case; skipping them makes idle GUI cost ~zero. History is
        // derived from the same authoritative snapshot transition, not from
        // the polling cadence.
        if snapshot == nil || !(snapshot?.meaningfullyEquals(response.snapshot) ?? false) {
            let events = EventTransitions.events(from: snapshot, to: response.snapshot)
            if !events.isEmpty {
                for event in events { localHistory.append(event) }
                persistLocalHistory()
            }
            snapshot = response.snapshot
        }
        // A daemon version below the running app means THIS APP is the
        // outdated component — typical after an in-place upgrade while the
        // GUI stayed open. The bundle was replaced under the running
        // process, so the process is stale too: surface "reopen the app"
        // (which actually fixes it) instead of "Repair Helper" (which
        // cannot, because repairing installs what is already installed).
        recheckStaleProcessIfNeeded()
        let nextHelperStatus = HelperStatusDerivation.helperStatus(
            isStaleProcess: isStaleProcess,
            daemonVersion: response.daemonVersion,
            expectedVersion: BatteryXPC.expectedHelperVersion
        )
        if helperStatus != nextHelperStatus {
            helperStatus = nextHelperStatus
        }
    }

    // MARK: Setup flow

    func installHelper() {
        guard !isInstalling else { return }
        isInstalling = true
        installProgress = HelperInstaller.InstallStep.registeringWithLaunchd.rawValue
        installer.install(progress: { [weak self] step in
            self?.installProgress = step
        }, completion: { [weak self] ok, message in
            guard let self else { return }
            self.isInstalling = false
            self.installProgress = nil
            self.lastAckMessage = ok ? "The privileged helper is installed and running." : message
            self.poll()
        })
    }

    func removeHelper() {
        guard !isInstalling else { return }
        isInstalling = true
        installer.uninstall(progress: { [weak self] step in
            self?.installProgress = step
        }, completion: { [weak self] ok, message in
            guard let self else { return }
            self.isInstalling = false
            self.installProgress = nil
            self.lastAckMessage = ok ? "The helper was removed and charging restored to macOS defaults." : message
            self.poll()
        })
    }

    func uninstallBatteryControl(removeUserData: Bool) {
        guard !isInstalling else { return }
        // The uninstall worker may remove Application Support. Drain the
        // serialized writer first so a queued snapshot cannot recreate local
        // data after the user explicitly chose to delete it.
        flushLocalHistoryPersistence()
        isInstalling = true
        uninstallMessage = nil
        uninstallSucceeded = false
        installer.uninstallApplication(removeUserData: removeUserData, progress: { [weak self] step in
            self?.installProgress = step
        }, completion: { [weak self] ok, message in
            guard let self else { return }
            self.isInstalling = false
            self.installProgress = nil
            self.uninstallSucceeded = ok
            self.uninstallMessage = message
            if ok { NSApp.terminate(nil) }
        })
    }

    func finishSetup() {
        setupComplete = true
        UserDefaults.standard.set(true, forKey: "setupComplete")
    }

    // MARK: Actions

    func apply(policy: ChargingPolicy) {
        Task {
            let ack = await DaemonXPCClient.shared.applyPolicy(policy)
            present(ack: ack)
        }
    }

    func startForceDischarge(target: Int, floor: Int? = nil, belowFloorConsent: Bool = false) {
        Task {
            let ack = await DaemonXPCClient.shared.startForceDischarge(
                targetPercent: target,
                floorPercent: floor ?? ChargingPolicyEngine.minimumDischargeFloor,
                belowFloorConsent: belowFloorConsent
            )
            present(ack: ack)
        }
    }

    func startForceCharge(target: Int, durationSeconds: TimeInterval? = nil) {
        Task {
            let ack = await DaemonXPCClient.shared.startForceCharge(
                targetPercent: target,
                durationSeconds: durationSeconds
            )
            present(ack: ack)
        }
    }

    func cancelOverrides() {
        Task {
            let ack = await DaemonXPCClient.shared.cancelOverrides()
            present(ack: ack)
        }
    }

    func beginCalibration() {
        Task {
            let ack = await DaemonXPCClient.shared.beginCalibration()
            present(ack: ack)
        }
    }

    func cancelCalibration() {
        Task {
            let ack = await DaemonXPCClient.shared.cancelCalibration()
            present(ack: ack)
        }
    }

    @MainActor
    private func present(ack: OperationAck?) {
        lastAck = ack
        lastAckMessage = ack?.message ?? "The helper did not respond. Try Repair Helper in Settings."
        // Record completion BEFORE the follow-up poll: any snapshot the
        // daemon built before this instant is pre-command and will be
        // skipped in favor of a fresh one (§ command/monitor race).
        lastCommandCompletion = Date()
        poll()
    }
}
