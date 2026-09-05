import AppKit
import Observation
import SwiftUI

struct UtilityControlsView: View {
    @Bindable var store: CommandCenterStore
    var compact = false
    var openSettings: (() -> Void)? = nil

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
                label: "ON AIR",
                symbol: microphoneSymbol,
                active: store.utilityMode == .microphone,
                activeColor: microphoneColor,
                help: store.utilityMode == .microphone ? "Turn off ON AIR monitoring" : "Show microphone, screen recording and screenshot activity"
            ) {
                store.toggleMicrophone()
            }

            utilityButton(
                label: "Keep Awake",
                symbol: store.keepAwakeEnabled ? "cup.and.saucer.fill" : "cup.and.saucer",
                active: store.keepAwakeEnabled,
                activeColor: keepAwakeTint,
                help: keepAwakeHelp
            ) {
                store.toggleKeepAwake()
            }

            Button {
                timerPopoverPresented.toggle()
            } label: {
                HStack(spacing: compact ? 4 : 6) {
                    Image(systemName: timerSymbol)
                        .font(.system(size: 13, weight: .semibold))
                    Text(store.timerState.isActive ? store.timerLabel : "Timer")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .frame(width: 48, alignment: .center)
                }
                .foregroundStyle(store.timerState.isActive ? Color.purple : Color.secondary)
                .frame(minWidth: compact ? 27 : 30, minHeight: 28)
                .padding(.horizontal, 3)
                .contentShape(.rect(cornerRadius: 8))
            }
            .buttonStyle(UtilityToolbarButtonStyle(tint: .purple, active: store.timerState.isActive))
            .id("utility.timer")
            .help(store.timerState.isActive ? "Timer \(store.timerLabel) — open controls" : "Open Timer")
            .accessibilityLabel("Timer")
            .accessibilityValue(store.timerState.isActive ? store.timerLabel : "Inactive")
            .accessibilityHint("Opens timer controls")
            .popover(isPresented: $timerPopoverPresented, arrowEdge: .bottom) {
                TimerPopoverView(store: store, openSettings: openSettings)
                    .frame(width: 300)
                    .padding(20)
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
        .fixedSize(horizontal: true, vertical: false)
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
        store.onAirSymbol
    }

    private var microphoneColor: Color {
        Color(hex: store.onAirStyle?.colorHex ?? "#FF9F0A")
    }

    private var keepAwakeTint: Color {
        Color(red: 0.96, green: 0.63, blue: 0.2)
    }

    private var keepAwakeHelp: String {
        let status = store.keepAwakeStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty { return status }
        return store.keepAwakeEnabled ? "Turn off Keep Awake" : "Turn on Keep Awake"
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
                .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(UtilityToolbarButtonStyle(tint: activeColor, active: active))
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(active ? "On" : "Off")
        .id("utility.\(label)")
    }
}

struct TimerPopoverView: View {
    @Bindable var store: CommandCenterStore
    var openSettings: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var durationText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Timer", systemImage: "timer")
                    .font(.headline)
                Spacer()
                Text(phaseTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(timerColor)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(timerColor.opacity(0.1), in: .capsule)
            }

            VStack(spacing: 10) {
                Text(store.timerState.isActive ? store.timerLabel : CountdownState.label(seconds: Double(store.timerSettings.durationSeconds)))
                    .font(.system(size: 54, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(store.timerState.phase == .finished ? Color.green : Color.primary)
                    .contentTransition(.numericText(countsDown: true))
                    .accessibilityLabel("Time remaining")
                    .accessibilityValue(store.timerState.isActive ? store.timerLabel : "Not started")
                ProgressView(value: timerFraction)
                    .tint(timerColor)
                    .accessibilityLabel("Timer remaining")
                Text(timerDetail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            if store.timerState.phase == .idle || store.timerState.phase == .finished {
                HStack(spacing: 6) {
                    ForEach([5, 15, 25], id: \.self) { minutes in
                        Button("\(minutes) min") {
                            store.updateTimerSettings { $0.durationSeconds = minutes * 60 }
                            syncDurationText()
                        }
                        .buttonStyle(.bordered)
                        .tint(store.timerSettings.durationSeconds == minutes * 60 ? .purple : .secondary)
                    }
                    Spacer(minLength: 4)
                    TextField("Minutes", text: $durationText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(commitDuration)
                        .accessibilityLabel("Timer duration in minutes")
                    Text("min").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                timerActionButton.frame(maxWidth: .infinity)
                Button { store.resetTimer(); syncDurationText() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 28, height: 20)
                }
                .buttonStyle(.glass)
                .disabled(store.timerState.phase == .idle)
                .help("Reset timer")
                .accessibilityLabel("Reset timer")
            }
            .controlSize(.large)

            Divider().opacity(0.5)
            HStack {
                if store.timerState.isActive {
                    Button(store.utilityMode == .timer ? "Agent lighting" : "Show on LEDs") {
                        store.selectUtilityMode(store.utilityMode == .timer ? .agents : .timer)
                        dismiss()
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("Customize", systemImage: "slider.horizontal.3") {
                    commitDuration()
                    store.openUtilitySettings(.timer)
                    dismiss()
                    openSettings?()
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .onAppear(perform: syncDurationText)
        .onChange(of: store.timerSettings.durationSeconds) { _, _ in syncDurationText() }
    }

    private var phaseTitle: String {
        switch store.timerState.phase {
        case .idle: "Ready"
        case .running: "Counting down"
        case .paused: "Paused"
        case .finished: "Finished"
        }
    }

    private var timerFraction: Double {
        guard store.timerState.isActive, store.timerState.duration > 0 else { return 1 }
        if store.timerState.phase == .finished { return 1 }
        return min(1, max(0, store.timerRemaining / store.timerState.duration))
    }

    private var timerActionButton: some View {
        let title = store.timerState.phase == .running ? "Pause" : store.timerState.phase == .paused ? "Resume" : "Start timer"
        return Button {
            switch store.timerState.phase {
            case .running: store.pauseTimer()
            case .paused: store.resumeTimer()
            case .idle, .finished: commitDuration(); store.startTimer()
            }
        } label: {
            Label(title, systemImage: store.timerState.phase == .running ? "pause.fill" : "play.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .accessibilityLabel(store.timerState.phase == .running ? "Pause timer" : store.timerState.phase == .paused ? "Resume timer" : "Start timer")
    }

    private var timerDetail: String {
        switch store.timerState.phase {
        case .idle: "Ready to count down on SidePulse."
        case .running: "Keeps counting when you switch modes."
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
        durationText = (Double(store.timerSettings.durationSeconds) / 60).formatted(.number.grouping(.never).precision(.fractionLength(0...3)).locale(Locale(identifier: "en_US_POSIX")))
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

    private enum Page: String, CaseIterable {
        case microphone, timer, notch, coffee
        var title: String {
            switch self { case .microphone: "ON AIR"; case .timer: "Timer"; case .notch: "Top Display"; case .coffee: "Coffee" }
        }
        var symbol: String {
            switch self { case .microphone: "mic.fill"; case .timer: "timer"; case .notch: "rectangle.topthird.inset.filled"; case .coffee: "cup.and.saucer.fill" }
        }
        var tint: Color {
            switch self { case .microphone: .orange; case .timer: .purple; case .notch: .cyan; case .coffee: .orange }
        }
    }

    private var page: Page { Page(rawValue: store.utilitySettingsPage) ?? .microphone }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Utility modes").font(.title2.bold())
                Text("A look for every signal.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(Page.allCases, id: \.self) { item in
                    Button { store.utilitySettingsPage = item.rawValue } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .contentShape(.rect(cornerRadius: 10))
                    }
                    .buttonStyle(UtilityToolbarButtonStyle(tint: item.tint, active: page == item))
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
            }
            .padding(4)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 14))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch page {
                    case .microphone:
                        UtilitySettingsCard(title: "ON AIR", symbol: page.symbol, tint: page.tint, detail: microphoneSummary) {
                            microphoneSettings
                        }
                    case .timer:
                        UtilitySettingsCard(title: "Timer", symbol: page.symbol, tint: page.tint, detail: timerSummary) {
                            timerSettings
                        }
                    case .notch:
                        UtilitySettingsCard(title: "Top Display Island", symbol: page.symbol, tint: page.tint,
                            detail: "Your active lighting, just beneath the camera notch—or in a compact island at the top of a display without one.") {
                            notchSettings
                        }
                    case .coffee:
                        UtilitySettingsCard(title: "Keep Awake", symbol: page.symbol, tint: page.tint,
                            detail: "Keep your Mac working while SidePulse is running, even with the display off.") {
                            Toggle("Coffee", isOn: Binding(
                                get: { store.keepAwakeEnabled },
                                set: { value in if value != store.keepAwakeEnabled { store.toggleKeepAwake() } }
                            ))
                            .toggleStyle(.switch)
                            Text(store.keepAwakeStatus)
                                .font(.subheadline).foregroundStyle(store.keepAwakeEnabled ? Color.orange : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if store.keepAwakeNeedsAuthorization {
                                Button("Enable closed-lid protection…") {
                                    store.authorizeClosedLidProtection()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                            }
                            Text("Closed-lid protection needs macOS authentication once per SidePulse launch. Coffee restores normal sleep when turned off or when SidePulse exits. A sleep block already set by another app is preserved.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var microphoneSummary: String {
        guard store.utilityMode == .microphone else { return "A clear signal when your microphone or screen is being captured." }
        return store.utilityStatusTitle ?? "Watching for activity · agent lighting"
    }

    private var timerSummary: String {
        let duration = CountdownState.label(seconds: Double(store.timerSettings.durationSeconds))
        if store.timerState.phase == .finished { return "Finished · \(duration) timer" }
        return store.timerState.isActive ? "\(store.timerLabel) remaining" : "\(duration) · ready when you are"
    }

    private var microphoneSettings: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                if store.utilityMode == .microphone {
                    Label(microphoneStatusTitle, systemImage: microphoneStatusSymbol)
                        .font(.subheadline.weight(.medium)).foregroundStyle(microphoneStatusColor)
                } else {
                    Label("Indicator off", systemImage: "mic")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("ON AIR mode", isOn: Binding(
                    get: { store.utilityMode == .microphone },
                    set: { store.selectUtilityMode($0 ? .microphone : .agents) }
                ))
                .labelsHidden().toggleStyle(.switch)
            }
            if store.utilityMode == .microphone {
                Text(store.utilityStatusDetail)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("Orange moves inward while your mic or macOS Screenshot recording is active. Saved screenshots get a quick white sweep. Your agents show between captures. Each signal has its own editable look.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            UtilityStyleSelector(options: [
                UtilityStyleOption("Microphone", style: microphoneStyleBinding(\.activeStyle)),
                UtilityStyleOption("Hardware muted", style: microphoneStyleBinding(\.mutedStyle))
            ], preview: store.previewUtilityStyle)

            Divider().padding(.vertical, 3)
            Toggle("Screen recording", isOn: Binding(
                get: { store.captureSettings.screenRecordingEnabled },
                set: { value in store.updateCaptureSettings { $0.screenRecordingEnabled = value } }
            ))
            Toggle("Screenshots", isOn: Binding(
                get: { store.captureSettings.screenshotEnabled },
                set: { value in store.updateCaptureSettings { $0.screenshotEnabled = value } }
            ))
            UtilityStyleSelector(options: [
                UtilityStyleOption("Screen recording", style: captureStyleBinding(\.recordingStyle)),
                UtilityStyleOption("Screenshot", style: captureStyleBinding(\.screenshotStyle))
            ], preview: store.previewUtilityStyle)
            if store.utilityMode == .microphone, !store.captureSnapshot.isAvailable {
                Text(store.captureSnapshot.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Enable recording detection…", action: store.enableScreenRecordingDetection)
                    .buttonStyle(.bordered)
            }
            Text("Recording detection covers the macOS Screenshot app. Screenshot flashes follow newly saved files after Spotlight indexes them; clipboard-only screenshots aren’t reported.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

            UtilityStyleSelector(options: [
                UtilityStyleOption("Running", style: timerStyleBinding(\.runningStyle)),
                UtilityStyleOption("Warning", style: timerStyleBinding(\.warningStyle)),
                UtilityStyleOption("Finished", style: timerStyleBinding(\.finishedStyle))
            ], preview: store.previewUtilityStyle)
        }
    }

    private var notchSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable Top Display Island", isOn: Binding(
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
                .accessibilityLabel("Top display brightness")
                Text("\(Int((store.notchBrightness * 100).rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(width: 38, alignment: .trailing)
            }
            Text("Hover over the top-center island for agents and quick controls.")
                .font(.caption).foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)
            Picker("Menu bar icon", selection: Binding(
                get: { store.menuBarVisibilityMode },
                set: { store.setMenuBarVisibilityMode($0) }
            )) {
                ForEach(MenuBarVisibilityMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)

            if store.menuBarVisibilityMode == .whenNotchOff {
                Toggle("Keep available in full screen", isOn: Binding(
                    get: { store.menuBarKeepWhenAutoHidden },
                    set: { store.setMenuBarKeepWhenAutoHidden($0) }
                ))
                .toggleStyle(.switch)
                Text("Also keeps the icon when the menu bar auto-hides. Move to the top of the screen to reveal it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var microphoneStatusTitle: String {
        store.utilityStatusTitle ?? "Watching for activity · agent lighting"
    }

    private var microphoneStatusSymbol: String {
        store.onAirSymbol
    }

    private var microphoneStatusColor: Color {
        Color(hex: store.onAirStyle?.colorHex ?? "#FF9F0A")
    }

    private func captureStyleBinding(_ keyPath: WritableKeyPath<CaptureIndicatorSettings, StateLightStyle>) -> Binding<StateLightStyle> {
        Binding(
            get: { store.captureSettings[keyPath: keyPath] },
            set: { value in store.updateCaptureSettings { $0[keyPath: keyPath] = value } }
        )
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

struct ProgressModeStudioView: View {
    @Bindable var store: CommandCenterStore

    private enum Source: String, CaseIterable {
        case command = "Run a command"
        case process = "Watch a process"
    }
    @State private var source: Source = .command
    @State private var showsCustomization = false
    @State private var showsTaskDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Progress")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Tell me when it’s done.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            if store.progressSnapshot.phase != .idle { progressStatus }

            if store.progressSnapshot.phase == .running {
                DisclosureGroup("Task details", isExpanded: $showsTaskDetails) {
                    taskSource.padding(.top, 12)
                }
                .font(.subheadline.weight(.medium))
            } else {
                taskSource
            }

            if let error = store.utilityError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)
            DisclosureGroup(isExpanded: $showsCustomization) {
                progressCustomization.padding(.top, 14)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                    Text("Lighting").font(.subheadline.weight(.semibold))
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach([store.progressSettings.runningStyle.colorHex, store.progressSettings.completedStyle.colorHex, store.progressSettings.failedStyle.colorHex].indices, id: \.self) { index in
                            let colors = [store.progressSettings.runningStyle.colorHex, store.progressSettings.completedStyle.colorHex, store.progressSettings.failedStyle.colorHex]
                            Circle().fill(Color(hex: colors[index])).frame(width: 8, height: 8)
                        }
                    }
                }
            }
            .tint(.secondary)
        }
        .padding(2)
        .padding(.bottom, 20)
    }

    private var taskSource: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Task source", selection: $source) {
                ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented)

            if source == .command {
                VStack(alignment: .leading, spacing: 8) {
                    Text("COMMAND").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("Command to run", text: $store.progressCommand, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder).lineLimit(2...4)
                        .accessibilityLabel("Progress command")
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        TextField("Working directory", text: $store.progressDirectory)
                            .textFieldStyle(.plain).font(.caption)
                            .accessibilityLabel("Progress working directory")
                        Button("Choose…") { store.chooseProgressDirectory() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                    .padding(9)
                    .background(.primary.opacity(0.035), in: .rect(cornerRadius: 8))
                }
                Button { store.runProgressCommand() } label: {
                    Label("Run & Watch", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .disabled(store.progressSnapshot.phase == .running || store.progressCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityHint("Runs the command in the selected directory and watches it")
            } else {
                Text("Follow a process that’s already running.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("Process ID", text: $store.progressPID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Process ID to watch")
                    Button("Watch", systemImage: "eye") { store.watchProgressProcess() }
                        .buttonStyle(.glassProminent)
                        .disabled(store.progressSnapshot.phase == .running)
                }
                Text("Stopping a watch leaves the process running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.progressSnapshot.phase == .idle {
                Text("Your lights show activity, then signal when the task finishes.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.primary.opacity(0.025), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.065)))
    }

    private var progressStatus: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: progressPhaseSymbol)
                    .font(.title2).foregroundStyle(progressPhaseColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(progressPhaseTitle).font(.headline)
                    Text(store.progressSnapshot.title)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if store.progressSnapshot.phase == .running, let fraction = store.progressSnapshot.fraction {
                    Text("\(Int((min(1, max(0, fraction)) * 100).rounded()))%")
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
            }
            if store.progressSnapshot.phase == .running {
                if let fraction = store.progressSnapshot.fraction {
                    ProgressView(value: min(1, max(0, fraction)))
                        .tint(progressPhaseColor).accessibilityLabel("Progress")
                } else {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Watching for completion…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(store.progressSnapshot.detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if store.progressSnapshot.phase == .running {
                    Button(store.progressSnapshot.logURL == nil ? "Stop watching" : "Cancel task", systemImage: "stop.fill") {
                        store.cancelProgress()
                    }.buttonStyle(.glass)
                } else {
                    Button("Clear") { store.clearProgress() }.buttonStyle(.glass)
                }
                if store.progressSnapshot.logURL != nil {
                    Button("Open Log", systemImage: "doc.text") { store.openProgressLog() }
                        .buttonStyle(.borderless)
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)

            if [.running, .completed, .failed].contains(store.progressSnapshot.phase) {
                Button(store.utilityMode == .progress ? "Return to agent lighting" : "Show on LEDs", systemImage: store.utilityMode == .progress ? "arrow.uturn.backward" : "lightbulb.led.wide.fill") {
                    store.selectUtilityMode(store.utilityMode == .progress ? .agents : .progress)
                }
                .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(16)
        .background(progressPhaseColor.opacity(0.07), in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(progressPhaseColor.opacity(0.18)))
    }

    private var progressCustomization: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("LED output", selection: Binding(
                get: { store.progressSettings.gaugeMode },
                set: { mode in store.updateProgressSettings { $0.gaugeMode = mode } }
            )) {
                ForEach(UtilityGaugeMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            UtilityStyleSelector(options: [
                UtilityStyleOption("Running", style: progressStyleBinding(\.runningStyle)),
                UtilityStyleOption("Completed", style: progressStyleBinding(\.completedStyle)),
                UtilityStyleOption("Failed", style: progressStyleBinding(\.failedStyle))
            ], preview: store.previewUtilityStyle)
        }
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
        .background(.primary.opacity(0.025), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.06)))
    }
}

private struct ReturnToAgentLightingButton: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        Button("Agent lighting", systemImage: "arrow.uturn.backward") {
            store.selectUtilityMode(.agents)
        }
        .buttonStyle(.glass)
        .accessibilityHint("Stops the utility LED output and restores agent lighting")
    }
}

private struct UtilityToolbarButtonStyle: ButtonStyle {
    var tint: Color
    var active: Bool

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, tint: tint, active: active)
    }

    private struct Surface: View {
        let configuration: Configuration
        let tint: Color
        let active: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(active ? tint.opacity(configuration.isPressed ? 0.3 : hovered ? 0.22 : 0.13) : Color.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.065 : 0))
                }
                .contentShape(.rect(cornerRadius: 8))
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}
