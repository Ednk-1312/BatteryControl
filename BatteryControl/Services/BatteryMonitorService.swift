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

    /// From the setup flow: whether first-run setup completed.
    @Published var setupComplete: Bool = UserDefaults.standard.bool(forKey: "setupComplete")

    let batteryMonitor = BatteryMonitorService()
    private let installer = HelperInstaller()
    private var refreshTimer: Timer?

    init() {
        platform = PlatformDetector.detect()
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
    }

    // MARK: Derived state for the UI

    var isSupported: Bool { platform.isSupportedPlatform }

    var capabilities: BatteryCapabilities {
        snapshot?.capabilities ?? .unsupported
    }

    var effectiveReadings: BatteryReadings {
        snapshot?.readings ?? batteryMonitor.readings ?? .placeholder
    }

    var controlSummary: String {
        guard let snapshot else { return helperStatusText }
        if !isSupported { return "Unsupported platform" }
        switch snapshot.activePolicy.mode {
        case .passthrough:
            return "macOS default charging"
        case .hysteresis:
            return "Limit \(snapshot.activePolicy.upperLimit)% · lower \(snapshot.activePolicy.lowerLimit)%"
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

    /// When the last command completed. A status snapshot the daemon built
    /// BEFORE this instant predates the command's effect and must not be
    /// presented as the final state (§ command/monitor race).
    private var lastCommandCompletion: Date?

    /// Bounded one-shot refresh after a stale detection: set while the
    /// freshness-triggered follow-up request is outstanding so the next
    /// completion is always applied (never triggers another re-request).
    private var freshnessRefreshInFlight = false

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
        snapshot = response.snapshot
        if response.daemonVersion != BatteryXPC.expectedHelperVersion {
            helperStatus = .outdated
        } else {
            helperStatus = .running
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

    func startForceCharge(target: Int) {
        Task {
            let ack = await DaemonXPCClient.shared.startForceCharge(targetPercent: target)
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
