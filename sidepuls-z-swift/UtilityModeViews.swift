import AppKit
import Observation
import SwiftUI

struct UtilityControlsView: View {
    @Bindable var store: CommandCenterStore
    var compact = false

    @State private var timerPopoverPresented = false

    var body: some View {
        HStack(spacing: compact ? 1 : 3) {
            utilityButton(
                label: "Flashlight",
                symbol: store.flashlightEnabled ? "flashlight.on.fill" : "flashlight.off.fill",
                active: store.flashlightEnabled,
                activeColor: .white,
                help: store.flashlightEnabled ? "Turn off Flashlight" : "Turn on Flashlight"
            ) {
                store.toggleFlashlight()
            }

            utilityButton(
                label: "Microphone",
                symbol: microphoneSymbol,
                active: store.utilityMode == .microphone,
                activeColor: microphoneColor,
                help: store.utilityMode == .microphone ? "Return from Microphone mode" : "Show microphone activity on the LEDs"
            ) {
                store.toggleMicrophone()
            }

            Button {
                timerPopoverPresented.toggle()
            } label: {
                HStack(spacing: compact ? 4 : 6) {
                    Image(systemName: timerSymbol)
                        .font(.system(size: 13, weight: .semibold))
                    if store.timerState.isActive {
                        Text(store.timerLabel)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .fixedSize()
                    }
                }
                .foregroundStyle(store.timerState.isActive ? Color.purple : Color.secondary)
                .frame(minWidth: compact ? 27 : 30, minHeight: 28)
                .padding(.horizontal, store.timerState.isActive ? 3 : 0)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help(store.timerState.isActive ? "Timer \(store.timerLabel) — open controls" : "Open Timer")
            .accessibilityLabel("Timer")
            .accessibilityValue(store.timerState.isActive ? store.timerLabel : "Inactive")
            .accessibilityHint("Opens timer controls")
            .popover(isPresented: $timerPopoverPresented, arrowEdge: .bottom) {
                TimerPopoverView(store: store)
                    .frame(width: 330)
                    .padding(18)
            }

            utilityButton(
                label: "SidePulse Notch",
                symbol: "rectangle.topthird.inset.filled",
                active: store.notchEnabled,
                activeColor: .cyan,
                help: store.notchEnabled ? "Turn off SidePulse Notch" : "Turn on SidePulse Notch"
            ) {
                store.setNotchEnabled(!store.notchEnabled)
            }

            Divider()
                .frame(height: 16)
                .opacity(0.45)

            utilityButton(
                label: "Live Output",
                symbol: "power",
                active: store.outputPowerIsOn,
                activeColor: .red,
                help: store.outputPowerIsOn ? "Turn off Live Output" : "Turn on Live Output"
            ) {
                store.toggleOutputPower()
            }
        }
        .controlSize(.small)
        .animation(.snappy(duration: 0.18), value: store.timerState.isActive)
    }

    private var timerSymbol: String {
        switch store.timerState.phase {
        case .running: "timer"
        case .paused: "pause.circle"
        case .finished: "checkmark.circle"
        case .idle: "timer"
        }
    }

    private var microphoneSymbol: String {
        switch store.microphoneSnapshot.activity {
        case .inUse: "mic.fill"
        case .muted: "mic.slash.fill"
        case .idle, .unavailable: "mic"
        }
    }

    private var microphoneColor: Color {
        switch store.microphoneSnapshot.activity {
        case .inUse: .red
        case .muted: .orange
        case .idle: .green
        case .unavailable: .secondary
        }
    }

    private func utilityButton(
        label: String,
        symbol: String,
        active: Bool,
        activeColor: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? activeColor : Color.secondary)
                .frame(width: 28, height: 28)
                .background(active ? activeColor.opacity(0.14) : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "On" : "Off")
    }
}

struct TimerPopoverView: View {
    @Bindable var store: CommandCenterStore
    @Environment(\.dismiss) private var dismiss
    @State private var durationText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Timer")
                        .font(.title3.bold())
                    Text(timerDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.timerState.isActive {
                    Text(store.timerLabel)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(timerColor)
                        .accessibilityLabel("Time remaining")
                }
            }

            HStack(spacing: 8) {
                Text("Duration")
                    .font(.subheadline.weight(.medium))
                TextField("Minutes", text: $durationText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 82)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commitDuration)
                    .accessibilityLabel("Timer duration in minutes")
                Text("minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 8) {
                timerActionButton
                Button("Reset", systemImage: "arrow.counterclockwise") {
                    store.resetTimer()
                    syncDurationText()
                }
                .buttonStyle(.glass)
                .disabled(store.timerState.phase == .idle)
                .accessibilityLabel("Reset timer")

                Button("Show on LEDs", systemImage: "lightbulb.led.wide.fill") {
                    commitDuration()
                    store.selectUtilityMode(.timer)
                    dismiss()
                }
                .buttonStyle(.glass)
                .disabled(!store.timerState.isActive)
                .accessibilityHint("Show the timer output on the SidePulse LEDs")
            }

            HStack {
                if store.utilityMode != .agents {
                    ReturnToAgentLightingButton(store: store)
                }
                Spacer()
                Button("Customize", systemImage: "slider.horizontal.3") {
                    store.openUtilitySettings()
                    dismiss()
                }
                .buttonStyle(.glass)
            }

            if let error = store.utilityError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: syncDurationText)
        .onChange(of: store.timerSettings.durationSeconds) { _, _ in
            syncDurationText()
        }
    }

    @ViewBuilder
    private var timerActionButton: some View {
        switch store.timerState.phase {
        case .idle, .finished:
            Button("Start", systemImage: "play.fill") {
                commitDuration()
                store.startTimer()
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Start timer")
        case .running:
            Button("Pause", systemImage: "pause.fill") {
                store.pauseTimer()
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Pause timer")
        case .paused:
            Button("Resume", systemImage: "play.fill") {
                store.resumeTimer()
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Resume timer")
        }
    }

    private var timerDetail: String {
        switch store.timerState.phase {
        case .idle: "Ready to count down on SidePulse."
        case .running: "Counting down; the timer continues if you switch modes."
        case .paused: "Paused. Resume when you are ready."
        case .finished: "Finished. Start again or reset the timer."
        }
    }

    private var timerColor: Color {
        switch store.timerState.phase {
        case .finished: .green
        case .paused: .orange
        case .running: .purple
        case .idle: .secondary
        }
    }

    private func syncDurationText() {
        durationText = String(format: "%.2g", Double(store.timerSettings.durationSeconds) / 60)
    }

    private func commitDuration() {
        guard let minutes = Double(durationText), minutes.isFinite else {
            syncDurationText()
            return
        }
        let clampedMinutes = min(1440, max(1 / 60, minutes))
        store.updateTimerSettings { settings in
            settings.durationSeconds = Int((clampedMinutes * 60).rounded())
        }
        syncDurationText()
    }
}

struct UtilitySettingsView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Utility Modes")
                            .font(.title2.bold())
                        Text("Tune microphone, timer, and display indicators without changing agent lighting profiles.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.utilityMode != .agents {
                        ReturnToAgentLightingButton(store: store)
                    }
                }

                UtilitySettingsCard(
                    title: "Microphone",
                    symbol: "mic.fill",
                    tint: .red,
                    detail: microphoneSummary
                ) {
                    microphoneSettings
                }

                UtilitySettingsCard(
                    title: "Timer",
                    symbol: "timer",
                    tint: .purple,
                    detail: timerSummary
                ) {
                    timerSettings
                }

                UtilitySettingsCard(
                    title: "SidePulse Notch",
                    symbol: "rectangle.topthird.inset.filled",
                    tint: .cyan,
                    detail: "Mirror the active LED program beneath the camera notch or at the top center of a display."
                ) {
                    notchSettings
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
    }

    private var microphoneSummary: String {
        let activity: String
        switch store.microphoneSnapshot.activity {
        case .inUse: activity = "In use"
        case .muted: activity = "Hardware muted"
        case .idle: activity = "Idle"
        case .unavailable: activity = "Unavailable"
        }
        return "\(activity) · \(store.microphoneSnapshot.deviceName)"
    }

    private var timerSummary: String {
        let duration = CountdownState.label(seconds: Double(store.timerSettings.durationSeconds))
        return store.timerState.isActive ? "\(store.timerLabel) remaining · \(duration) configured" : "\(duration) configured"
    }

    private var microphoneSettings: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: microphoneStatusSymbol)
                    .foregroundStyle(microphoneStatusColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(microphoneStatusTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(store.microphoneSnapshot.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle("Show an idle microphone state", isOn: Binding(
                get: { store.microphoneSettings.showsWhenIdle },
                set: { value in store.updateMicrophoneSettings { $0.showsWhenIdle = value } }
            ))
            .toggleStyle(.switch)
            .font(.subheadline)

            Text("SidePulse reports in-use, hardware-muted, idle, or unavailable. This indicator does not mute the app or microphone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            UtilityStyleEditor(
                title: "In use",
                style: microphoneStyleBinding(\.activeStyle),
                preview: { store.previewUtilityStyle(store.microphoneSettings.activeStyle) }
            )
            UtilityStyleEditor(
                title: "Hardware muted",
                style: microphoneStyleBinding(\.mutedStyle),
                preview: { store.previewUtilityStyle(store.microphoneSettings.mutedStyle) }
            )
            UtilityStyleEditor(
                title: "Idle",
                style: microphoneStyleBinding(\.idleStyle),
                preview: { store.previewUtilityStyle(store.microphoneSettings.idleStyle) }
            )
        }
    }

    private var timerSettings: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Text("Duration")
                Spacer()
                TextField("Minutes", value: Binding(
                    get: { Double(store.timerSettings.durationSeconds) / 60 },
                    set: { value in
                        guard value.isFinite else { return }
                        let minutes = min(1440, max(1 / 60, value))
                        store.updateTimerSettings { $0.durationSeconds = Int((minutes * 60).rounded()) }
                    }
                ), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("Timer duration in minutes")
                Text("minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text("Warning threshold")
                Spacer()
                TextField("Seconds", value: Binding(
                    get: { store.timerSettings.warningSeconds },
                    set: { value in store.updateTimerSettings { $0.warningSeconds = value } }
                ), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("Timer warning threshold in seconds")
                Text("seconds")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("LED output", selection: Binding(
                get: { store.timerSettings.gaugeMode },
                set: { mode in store.updateTimerSettings { $0.gaugeMode = mode } }
            )) {
                ForEach(UtilityGaugeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            UtilityStyleEditor(
                title: "Running",
                style: timerStyleBinding(\.runningStyle),
                preview: { store.previewUtilityStyle(store.timerSettings.runningStyle) }
            )
            UtilityStyleEditor(
                title: "Warning",
                style: timerStyleBinding(\.warningStyle),
                preview: { store.previewUtilityStyle(store.timerSettings.warningStyle) }
            )
            UtilityStyleEditor(
                title: "Finished",
                style: timerStyleBinding(\.finishedStyle),
                preview: { store.previewUtilityStyle(store.timerSettings.finishedStyle) }
            )
        }
    }

    private var notchSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable SidePulse Notch", isOn: Binding(
                get: { store.notchEnabled },
                set: { store.setNotchEnabled($0) }
            ))
            .toggleStyle(.switch)

            HStack(spacing: 9) {
                Text("Brightness")
                    .font(.subheadline)
                Slider(value: Binding(
                    get: { store.notchBrightness },
                    set: { store.setNotchBrightness($0) }
                ), in: 0...1, step: 0.01)
                .disabled(!store.notchEnabled)
                .accessibilityLabel("Notch brightness")
                Text("\(Int((store.notchBrightness * 100).rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(width: 38, alignment: .trailing)
            }
        }
    }

    private var microphoneStatusTitle: String {
        switch store.microphoneSnapshot.activity {
        case .inUse: "Microphone in use"
        case .muted: "Microphone hardware muted"
        case .idle: "Microphone idle"
        case .unavailable: "Microphone unavailable"
        }
    }

    private var microphoneStatusSymbol: String {
        switch store.microphoneSnapshot.activity {
        case .inUse: "mic.fill"
        case .muted: "mic.slash.fill"
        case .idle: "mic"
        case .unavailable: "mic.slash"
        }
    }

    private var microphoneStatusColor: Color {
        switch store.microphoneSnapshot.activity {
        case .inUse: .red
        case .muted: .orange
        case .idle: .green
        case .unavailable: .secondary
        }
    }

    private func microphoneStyleBinding(_ keyPath: WritableKeyPath<MicrophoneIndicatorSettings, StateLightStyle>) -> Binding<StateLightStyle> {
        Binding(
            get: { store.microphoneSettings[keyPath: keyPath] },
            set: { value in store.updateMicrophoneSettings { $0[keyPath: keyPath] = value } }
        )
    }

    private func timerStyleBinding(_ keyPath: WritableKeyPath<TimerIndicatorSettings, StateLightStyle>) -> Binding<StateLightStyle> {
        Binding(
            get: { store.timerSettings[keyPath: keyPath] },
            set: { value in store.updateTimerSettings { $0[keyPath: keyPath] = value } }
        )
    }
}

struct UtilityStyleEditor: View {
    let title: String
    @Binding var style: StateLightStyle
    let preview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(previewColors.first ?? .white)
                    .frame(width: 26, height: 16)
                    .shadow(color: previewColors.first ?? .clear, radius: 4)
                Button("Preview", systemImage: "play.fill", action: preview)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityLabel("Preview \(title) style on SidePulse")
            }

            Picker("Color behavior", selection: $style.colorMode) {
                ForEach(LightColorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("\(title) color behavior")

            if style.colorMode != .rainbow {
                ColorPicker(
                    style.colorMode == .single ? "Color" : "First color",
                    selection: Binding(
                        get: { Color(hex: style.colorHex) },
                        set: { style.colorHex = $0.hexString }
                    )
                )
                if style.colorMode != .single {
                    ColorPicker(
                        "Second color",
                        selection: Binding(
                            get: { Color(hex: style.secondaryColorHex) },
                            set: { style.secondaryColorHex = $0.hexString }
                        )
                    )
                }
            } else {
                HStack(spacing: 7) {
                    ForEach(Array(previewColors.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 16, height: 16)
                    }
                    Text("Spectrum generated automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Motion", selection: $style.motion) {
                ForEach(LightMotion.allCases) { motion in
                    Text(motion.title).tag(motion)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("\(title) motion")

            HStack(spacing: 9) {
                Text("Intensity")
                    .font(.caption)
                Slider(value: $style.intensity, in: 0...1, step: 0.01)
                    .accessibilityLabel("\(title) intensity")
                Text("\(Int((style.intensity * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }

            if style.motion.isAnimated || style.colorMode == .rotatingColorway {
                HStack(spacing: 9) {
                    Text("Cycle")
                        .font(.caption)
                    Slider(value: $style.cycleSeconds, in: 0.2...12, step: 0.1)
                        .accessibilityLabel("\(title) cycle speed")
                    Text("\(style.cycleSeconds.formatted(.number.precision(.fractionLength(0...1))))s")
                        .font(.caption.monospacedDigit())
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 15))
    }

    private var previewColors: [Color] {
        switch style.colorMode {
        case .single:
            [Color(hex: style.colorHex), Color(hex: style.colorHex)]
        case .colorway:
            [Color(hex: style.colorHex), Color(hex: style.secondaryColorHex)]
        case .rainbow:
            [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]
        case .rotatingColorway:
            [Color(hex: style.colorHex), Color(hex: style.secondaryColorHex), Color(hex: style.colorHex)]
        }
    }
}

struct ProgressModeStudioView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Progress")
                        .font(.title2.bold())
                    Text("Run a command or watch an existing process and show its progress on SidePulse.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.utilityMode != .agents {
                    ReturnToAgentLightingButton(store: store)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Run a task")
                    .font(.headline)
                TextField("Command", text: $store.progressCommand, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .accessibilityLabel("Progress command")
                HStack(spacing: 9) {
                    TextField("Working directory", text: $store.progressDirectory)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Progress working directory")
                    Button("Choose…", systemImage: "folder") {
                        store.chooseProgressDirectory()
                    }
                    .buttonStyle(.glass)
                }
                Button("Run & Watch", systemImage: "play.fill") {
                    store.runProgressCommand()
                }
                .buttonStyle(.glassProminent)
                .disabled(store.progressSnapshot.phase == .running || store.progressCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityHint("Runs the command in the selected directory and watches it")
            }
            .padding(16)
            .glassEffect(.regular.tint(.cyan.opacity(0.06)), in: .rect(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Watch a process")
                        .font(.headline)
                    Spacer()
                    Text("Optional")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 9) {
                    TextField("PID", text: $store.progressPID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .accessibilityLabel("Process ID to watch")
                    Button("Watch PID", systemImage: "eye.fill") {
                        store.watchProgressProcess()
                    }
                    .buttonStyle(.glass)
                    .disabled(store.progressSnapshot.phase == .running)
                }
            }
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

            progressStatus
            progressCustomization

            if let error = store.utilityError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var progressStatus: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label(progressPhaseTitle, systemImage: progressPhaseSymbol)
                    .font(.headline)
                    .foregroundStyle(progressPhaseColor)
                Spacer()
                if store.progressSnapshot.phase != .idle {
                    Text(store.progressSnapshot.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let fraction = store.progressSnapshot.fraction, fraction.isFinite {
                ProgressView(value: min(1, max(0, fraction)))
                    .tint(progressPhaseColor)
                    .accessibilityLabel("Progress")
                    .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
            }

            if !store.progressSnapshot.detail.isEmpty {
                Text(store.progressSnapshot.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let exitCode = store.progressSnapshot.exitCode {
                Text("Exit code \(exitCode)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if store.progressSnapshot.phase == .running {
                    Button("Cancel", systemImage: "xmark.circle") {
                        store.cancelProgress()
                    }
                    .buttonStyle(.glass)
                }
                if store.utilityMode != .progress && [.running, .completed, .failed].contains(store.progressSnapshot.phase) {
                    Button("Show on LEDs", systemImage: "lightbulb.led.wide.fill") {
                        store.selectUtilityMode(.progress)
                    }
                    .buttonStyle(.glass)
                }
                if store.progressSnapshot.logURL != nil {
                    Button("Open Log", systemImage: "doc.text.magnifyingglass") {
                        store.openProgressLog()
                    }
                    .buttonStyle(.glass)
                }
                Button("Clear", systemImage: "trash") {
                    store.clearProgress()
                }
                .buttonStyle(.glass)
                .disabled(store.progressSnapshot.phase == .idle || store.progressSnapshot.phase == .running)
            }
        }
        .padding(16)
        .glassEffect(.regular.tint(progressPhaseColor.opacity(0.06)), in: .rect(cornerRadius: 18))
    }

    private var progressCustomization: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LED customization")
                .font(.headline)
            Picker("LED output", selection: Binding(
                get: { store.progressSettings.gaugeMode },
                set: { mode in store.updateProgressSettings { $0.gaugeMode = mode } }
            )) {
                ForEach(UtilityGaugeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            UtilityStyleEditor(
                title: "Running",
                style: progressStyleBinding(\.runningStyle),
                preview: { store.previewUtilityStyle(store.progressSettings.runningStyle) }
            )
            UtilityStyleEditor(
                title: "Completed",
                style: progressStyleBinding(\.completedStyle),
                preview: { store.previewUtilityStyle(store.progressSettings.completedStyle) }
            )
            UtilityStyleEditor(
                title: "Failed",
                style: progressStyleBinding(\.failedStyle),
                preview: { store.previewUtilityStyle(store.progressSettings.failedStyle) }
            )
        }
        .padding(16)
        .glassEffect(.regular.tint(.cyan.opacity(0.04)), in: .rect(cornerRadius: 18))
    }

    private var progressPhaseTitle: String {
        switch store.progressSnapshot.phase {
        case .idle: "Ready"
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private var progressPhaseSymbol: String {
        switch store.progressSnapshot.phase {
        case .idle: "circle"
        case .running: "arrow.triangle.2.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "slash.circle"
        }
    }

    private var progressPhaseColor: Color {
        switch store.progressSnapshot.phase {
        case .idle: .secondary
        case .running: .cyan
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }

    private func progressStyleBinding(_ keyPath: WritableKeyPath<ProgressIndicatorSettings, StateLightStyle>) -> Binding<StateLightStyle> {
        Binding(
            get: { store.progressSettings[keyPath: keyPath] },
            set: { value in store.updateProgressSettings { $0[keyPath: keyPath] = value } }
        )
    }
}

private struct UtilitySettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let detail: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.11), in: .rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(18)
        .glassEffect(.regular.tint(tint.opacity(0.045)), in: .rect(cornerRadius: 22))
    }
}

private struct ReturnToAgentLightingButton: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        Button("Return to Agent Lighting", systemImage: "arrow.uturn.backward") {
            store.selectUtilityMode(.agents)
        }
        .buttonStyle(.glass)
        .accessibilityHint("Stops the utility LED output and restores agent lighting")
    }
}
