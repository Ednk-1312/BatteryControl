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
        helperStatus = HelperInstaller().currentStatus()

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

    func poll() {
        Task {
            if let response = await DaemonClient.shared.getStatus() {
                self.snapshot = response.snapshot
                self.helperStatus = .running
                if response.daemonVersion != BatteryXPC.expectedHelperVersion {
                    self.helperStatus = .outdated
                }
            } else {
                self.helperStatus = HelperInstaller().currentStatus()
            }
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
            let ack = await DaemonClient.shared.applyPolicy(policy)
            await present(ack: ack)
        }
    }

    func startForceDischarge(target: Int) {
        Task {
            let ack = await DaemonClient.shared.startForceDischarge(
                targetPercent: target,
                floorPercent: ChargingPolicyEngine.minimumDischargeFloor
            )
            await present(ack: ack)
        }
    }

    func startForceCharge(target: Int) {
        Task {
            let ack = await DaemonClient.shared.startForceCharge(targetPercent: target)
            await present(ack: ack)
        }
    }

    func cancelOverrides() {
        Task {
            let ack = await DaemonClient.shared.cancelOverrides()
            await present(ack: ack)
        }
    }

    func beginCalibration() {
        Task {
            let ack = await DaemonClient.shared.beginCalibration()
            await present(ack: ack)
        }
    }

    func cancelCalibration() {
        Task {
            let ack = await DaemonClient.shared.cancelCalibration()
            await present(ack: ack)
        }
    }

    @MainActor
    private func present(ack: OperationAck?) {
        lastAck = ack
        lastAckMessage = ack?.message ?? "The helper did not respond. Try Repair Helper in Settings."
        poll()
    }
}
