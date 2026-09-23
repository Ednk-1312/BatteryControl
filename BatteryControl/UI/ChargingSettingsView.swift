import BatteryCore
import SwiftUI

/// Charging settings. "Fixed Charge Limit" is the primary, recommended mode
/// ("Set my Mac to 80%") — the user picks a limit preset, optionally tunes
/// the resume threshold, and the daemon maintains the band using the active
/// backend. Advanced modes (custom band, tight band, macOS default) remain
/// available but secondary.
struct ChargingSettingsView: View {

    @EnvironmentObject private var appState: AppState

    private enum SettingsMode {
        case fixedLimit
        case advanced
        case macOSDefault
    }

    @State private var settingsMode: SettingsMode = .fixedLimit
    @State private var limitPercent = 80
    @State private var resumePercent = 70
    @State private var customResumeEnabled = false
    @State private var advancedHysteresis = true
    @State private var advancedUpper = 80.0
    @State private var advancedLower = 70.0
    @State private var loadedPolicy: ChargingPolicy?

    var body: some View {
        Form {
            modePicker
            unsupportedNotice
            modeSections
            applySection
        }
        .formStyle(.grouped)
        .navigationTitle("Charging")
        .onAppear(perform: loadFromCurrentPolicy)
        .onChange(of: appState.snapshot?.activePolicy) { _, _ in
            loadFromCurrentPolicy()
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $settingsMode) {
            Text("Fixed Charge Limit").tag(SettingsMode.fixedLimit)
            Text("Advanced").tag(SettingsMode.advanced)
            Text("macOS default").tag(SettingsMode.macOSDefault)
        }
        .pickerStyle(.segmented)
        .disabled(!appState.capabilities.supportsUpperLimit)
        .onChange(of: settingsMode) { _, newValue in
            if newValue == .fixedLimit {
                advancedHysteresis = true
            }
        }
    }

    @ViewBuilder
    private var unsupportedNotice: some View {
        if !appState.capabilities.supportsUpperLimit {
            Section {
                Text("The active backend cannot verify charging control on this machine; these controls are disabled rather than pretending to work. See Diagnostics for details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var modeSections: some View {
        if settingsMode == .fixedLimit {
            presetsSection
            fixedLimitSections
        } else if settingsMode == .advanced {
            advancedSections
        }
    }

    private var applySection: some View {
        Section {
            Button(buttonLabel) {
                apply()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appState.capabilities.supportsUpperLimit)

            if showsOverrideCancel {
                Button("Cancel Override") {
                    appState.cancelOverrides()
                }
            }

            if let message = appState.lastAckMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Charging control runs in the privileged helper and keeps working after this window is closed, across sleep and restarts.")
        }
    }

    private var showsOverrideCancel: Bool {
        appState.snapshot?.isForceCharging == true
            || appState.snapshot?.isForceDischarging == true
    }

    // MARK: Daily-use presets

    private var presetsSection: some View {
        Section("Presets") {
            ForEach(ChargePreset.allCases, id: \.self) { preset in
                Button {
                    if let policy = preset.policy {
                        limitPercent = policy.upperLimit
                        resumePercent = policy.lowerLimit
                        customResumeEnabled = preset == .custom
                        if preset != .custom { appState.apply(preset: preset) }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                            Text(preset.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if appState.selectedPreset == preset {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Text("Presets use the same verified policy path as custom settings. A preset is not shown as active until the daemon confirms the hardware state.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Fixed Charge Limit

    @ViewBuilder
    private var fixedLimitSections: some View {
        chargeLimitSection
        resumeThresholdSection
        howItWorksSection
    }

    private var chargeLimitSection: some View {
        Section("Charge limit") {
            presetRow
            customRow
            summaryCaption
        }
    }

    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(FixedChargeLimit.presetPercents, id: \.self) { value in
                presetButton(value)
            }
        }
    }

    private var customRow: some View {
        HStack {
            Text("Custom")
                .foregroundStyle(.secondary)
            Spacer()
            Stepper("\(limitPercent)%", value: $limitPercent, in: 40...100)
                .labelsHidden()
                .monospacedDigit()
        }
    }

    private var summaryCaption: some View {
        Text("Set my Mac to \(limitPercent)%. Charging stops at/above \(limitPercent)%; BatteryControl maintains this automatically.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var resumeThresholdSection: some View {
        Section {
            Toggle("Custom lower limit", isOn: $customResumeEnabled)
            if customResumeEnabled {
                resumeSlider
                Text(FixedChargeLimit.explanation(upper: limitPercent, resume: resumePercent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                defaultResumeCaption
            }
        } header: {
            Text("Lower limit")
        }
    }

    private var resumeSlider: some View {
        HStack {
            Slider(value: resumePercentBinding, in: resumeSliderBounds, step: 1) {
                Text("Lower limit")
            }
            Text("\(resumePercent)%")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var resumePercentBinding: Binding<Double> {
        Binding(get: { Double(resumePercent) }, set: { resumePercent = Int($0) })
    }

    private var resumeSliderBounds: ClosedRange<Double> {
        Double(resumeRange.lowerBound)...Double(resumeRange.upperBound)
    }

    private var defaultResumeCaption: some View {
        let defaultResume = FixedChargeLimit.defaultResumeThreshold(forUpper: limitPercent)
        return Text("Default behavior: charging stops at \(limitPercent)% and resumes at \(defaultResume)%. Adjust the lower limit if you want a wider or tighter band.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var howItWorksSection: some View {
        Section("How this works") {
            Text("BatteryControl maintains the band around your limit using the battery's own management controller where available, so it holds during sleep and with the app closed. Every action is verified against the battery's actual state before it is reported as active — the dashboard never shows a limit that is not really enforced.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let note = ownershipNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Who is authoritative for charge limiting right now, explained in
    /// plain language. On macOS 26.4+ Apple ships its own Charge Limit
    /// (80–100%); when no BatteryControl policy is set and the native
    /// feature is engaged, say so instead of implying BatteryControl is
    /// doing anything. Never a control decision — purely explanatory.
    private var ownershipNote: String? {
        guard let snapshot = appState.snapshot, let native = snapshot.nativeChargeLimit else {
            return nil
        }
        let owner = OwnershipDecisions.owner(policyMode: snapshot.activePolicy.mode, native: native)
        return OwnershipDecisions.explanation(owner: owner, native: native, policyMode: snapshot.activePolicy.mode)
    }

    private var resumeRange: ClosedRange<Int> {
        FixedChargeLimit.allowedResumeRange(forUpper: limitPercent)
    }

    private func presetButton(_ value: Int) -> some View {
        let isSelected = limitPercent == value
        let fill: Color = isSelected ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.08)
        return Button {
            limitPercent = value
            resumePercent = FixedChargeLimit.defaultResumeThreshold(forUpper: value)
            customResumeEnabled = false
        } label: {
            Text("\(value)%")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(fill)
                .cornerRadius(7)
        }
        .buttonStyle(.plain)
    }

    // MARK: Advanced

    @ViewBuilder
    private var advancedSections: some View {
        advancedStrategySection
        if advancedHysteresis {
            advancedUpperSection
            advancedResumeSection
        } else {
            tightBandSection
        }
    }

    private var advancedStrategySection: some View {
        Section("Strategy") {
            Picker("Strategy", selection: $advancedHysteresis) {
                Text("Upper + lower limit").tag(true)
                Text("Tight band (±\(ChargingPolicy.fixedTargetBand))").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var advancedUpperSection: some View {
        Section("Upper limit") {
            HStack {
                Slider(value: advancedUpperBinding, in: upperSliderRange, step: 1) {
                    Text("Upper limit")
                }
                Text("\(Int(advancedUpper))%")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
            Picker("Preset", selection: advancedUpperPresetBinding) {
                ForEach(advancedPresetValues, id: \.self) { value in
                    Text("\(value)%").tag(value)
                }
            }
            .labelsHidden()
        }
    }

    private let advancedPresetValues: [Int] = [60, 70, 75, 80, 85, 90, 95, 100]

    private var upperSliderRange: ClosedRange<Double> { 40.0...100.0 }

    private var advancedUpperBinding: Binding<Double> {
        Binding(get: { advancedUpper }, set: { advancedUpper = $0 })
    }

    private var advancedUpperPresetBinding: Binding<Int> {
        Binding(get: { Int(advancedUpper) }, set: { advancedUpper = Double($0) })
    }

    private var advancedResumeSection: some View {
        Section("Lower limit") {
            HStack {
                Slider(value: advancedLowerBinding, in: resumeSliderRange, step: 1) {
                    Text("Lower limit")
                }
                Text("\(Int(advancedLower))%")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
            Text("Charging stops at \(Int(advancedUpper))% and resumes only after the battery falls to \(Int(advancedLower))%. The gap prevents rapid charge/pause cycling.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resumeSliderRange: ClosedRange<Double> {
        let top = Double(max(21, Int(advancedUpper) - 1))
        return 20.0...max(21.0, top)
    }

    private var advancedLowerBinding: Binding<Double> {
        Binding(get: { advancedLower }, set: { advancedLower = $0 })
    }

    private var tightBandSection: some View {
        Section("Tight band") {
            Text("Keeps the battery around \(Int(advancedUpper))% (a small internal band of ±\(ChargingPolicy.fixedTargetBand) points). The dashboard shows the actual state rather than promising an exact percentage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Apply / load

    private var buttonLabel: String {
        switch settingsMode {
        case .fixedLimit: return "Set \(limitPercent)% Limit"
        case .advanced: return "Apply Charging Policy"
        case .macOSDefault: return "Use macOS Default"
        }
    }

    private func apply() {
        switch settingsMode {
        case .fixedLimit:
            appState.apply(policy: FixedChargeLimit.policy(
                upper: limitPercent,
                resume: customResumeEnabled ? resumePercent : nil
            ))
        case .advanced:
            if advancedHysteresis {
                appState.apply(policy: ChargingPolicy.sanitized(upper: Int(advancedUpper), lower: Int(advancedLower)))
            } else {
                let upper = ChargingPolicyEngine.clampPercent(Int(advancedUpper))
                appState.apply(policy: ChargingPolicy(mode: .fixedTarget, upperLimit: upper, lowerLimit: 0))
            }
        case .macOSDefault:
            appState.apply(policy: .passthrough())
        }
    }

    private func loadFromCurrentPolicy() {
        guard let policy = appState.snapshot?.activePolicy,
              policy != loadedPolicy else { return }
        advancedUpper = Double(policy.upperLimit)
        advancedLower = Double(max(policy.lowerLimit, 1))

        loadedPolicy = policy
        switch policy.mode {
        case .passthrough:
            settingsMode = .macOSDefault
        case .hysteresis:
            settingsMode = .fixedLimit
            limitPercent = policy.upperLimit
            resumePercent = policy.lowerLimit
            customResumeEnabled = policy.lowerLimit != FixedChargeLimit.defaultResumeThreshold(forUpper: policy.upperLimit)
        case .fixedTarget:
            settingsMode = .advanced
            advancedHysteresis = false
        }
    }
}
