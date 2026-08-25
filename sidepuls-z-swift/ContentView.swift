import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 250)
        } detail: {
            ZStack {
                CommandCenterBackground()
                detail.padding(26)
            }
            .navigationTitle(store.selectedSection.title)
            .toolbar { toolbar }
        }
        .frame(minWidth: 1_080, minHeight: 700)
    }

    private var sidebar: some View {
        List(selection: $store.selectedSection) {
            Section("Home") {
                Label(CommandCenterSection.overview.title, systemImage: CommandCenterSection.overview.symbol)
                    .tag(CommandCenterSection.overview)
            }
            Section("Customize") {
                Label(CommandCenterSection.lighting.title, systemImage: CommandCenterSection.lighting.symbol)
                    .tag(CommandCenterSection.lighting)
                Label(CommandCenterSection.profiles.title, systemImage: CommandCenterSection.profiles.symbol)
                    .tag(CommandCenterSection.profiles)
            }
            Section("Monitor") {
                Label(CommandCenterSection.agents.title, systemImage: CommandCenterSection.agents.symbol)
                    .tag(CommandCenterSection.agents)
            }
            Section("Device") {
                ForEach([CommandCenterSection.hardware, .system, .diagnostics]) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("ACTIVE PROFILE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ProfileBadge(profile: store.selectedProfile)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selectedSection {
        case .overview: OverviewView(store: store)
        case .lighting: LightingStudioView(store: store)
        case .profiles: ProfilesView(store: store)
        case .agents: AgentsView(store: store)
        case .hardware: HardwareView(store: store)
        case .system: SystemView(store: store)
        case .diagnostics: DiagnosticsView(store: store)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Profile", selection: Binding(
                get: { store.selectedProfileID },
                set: { store.selectProfile($0) }
            )) {
                ForEach(store.profiles) { profile in
                    Label(profile.name, systemImage: profile.symbol).tag(profile.id)
                }
            }
            .frame(width: 190)

            Toggle(isOn: $store.liveOutputEnabled) {
                Label("Live Output", systemImage: "dot.radiowaves.left.and.right")
            }
            .toggleStyle(.button)
        }
    }
}

struct OverviewView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                CommandCenterHero(store: store)

                DashboardSectionHeader(
                    eyebrow: "LIVE HARDWARE",
                    title: "What your SidePulse is showing",
                    detail: "A live rendering of the exact program written to the device, with LED \(store.device.ledCount) at the top and LED 1 at the bottom."
                )
                LEDDeckView(store: store)

                HStack(alignment: .top, spacing: 18) {
                    AgentGridView(store: store)
                    ActionCenterView(store: store).frame(width: 300)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

struct CommandCenterHero: View {
    @Bindable var store: CommandCenterStore

    private var activeCount: Int { store.scene.placementsTopToBottom.count }
    private var finishedPlacement: AgentArrayPlacement? {
        let placements = store.scene.placementsTopToBottom
        guard !placements.isEmpty, placements.allSatisfy({ $0.agent.state == .completed }) else { return nil }
        return placements.first
    }

    private var title: String {
        if !store.device.connected { return "Connect your SidePulse" }
        if !store.liveOutputEnabled { return "Turn on Live Output" }
        if activeCount == 0 { return "Start an agent" }
        if finishedPlacement != nil { return "Run finished" }
        return "SidePulse is live"
    }

    private var detail: String {
        if !store.device.connected {
            return "Plug in the device. SidePulse will detect it automatically and show you the exact hardware path."
        }
        if !store.liveOutputEnabled {
            return "The device is connected, but lighting output is paused. Turn it on to mirror active sessions."
        }
        if activeCount == 0 {
            return "Start or resume a Codex task. It will appear here automatically—there is no extra setup step."
        }
        if finishedPlacement != nil {
            return "Green stays lit until the result is acknowledged. Open the finished session, return to Codex, or open the lid when you are ready for the next run."
        }
        let noun = activeCount == 1 ? "session" : "sessions"
        return "\(activeCount) active \(noun) mapped to the physical array. State changes update color and motion without reshuffling the agents."
    }

    private var tint: Color {
        if !store.device.connected || !store.liveOutputEnabled { return .orange }
        if activeCount == 0 { return .cyan }
        return .green
    }

    private var statusLabel: String {
        if !store.device.connected || !store.liveOutputEnabled { return "ACTION NEEDED" }
        if activeCount == 0 { return "READY" }
        if finishedPlacement != nil { return "READY FOR YOU" }
        return "LIVE NOW"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            VStack(alignment: .leading, spacing: 15) {
                Label(statusLabel, systemImage: activeCount > 0 ? "wave.3.right.circle.fill" : "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)

                Text(title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    primaryAction
                    if activeCount > 0, store.device.connected, store.liveOutputEnabled {
                        Button("Tune this signal", systemImage: "paintpalette.fill") {
                            store.selectedState = store.aggregateState == .idle ? .working : store.aggregateState
                            store.selectedSection = .lighting
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 190)

            VStack(alignment: .leading, spacing: 14) {
                Text("GET STARTED")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                SetupStepView(
                    title: "Connect the device",
                    detail: store.device.connected ? store.device.name : "Waiting for hardware",
                    complete: store.device.connected,
                    current: !store.device.connected
                )
                SetupStepView(
                    title: "Enable live output",
                    detail: store.liveOutputEnabled ? "Lighting is enabled" : "Output is paused",
                    complete: store.liveOutputEnabled,
                    current: store.device.connected && !store.liveOutputEnabled
                )
                SetupStepView(
                    title: "Run an agent",
                    detail: activeCount > 0 ? "\(activeCount) detected" : "Start or resume Codex",
                    complete: activeCount > 0,
                    current: store.device.connected && store.liveOutputEnabled && activeCount == 0
                )
            }
            .frame(width: 270, alignment: .leading)
        }
        .padding(28)
        .glassEffect(.regular.tint(tint.opacity(0.09)), in: .rect(cornerRadius: 30))
    }

    @ViewBuilder
    private var primaryAction: some View {
        if !store.device.connected {
            Button("Open Hardware", systemImage: "externaldrive.fill") {
                store.selectedSection = .hardware
            }
            .buttonStyle(.glassProminent)
        } else if !store.liveOutputEnabled {
            Button("Turn On Live Output", systemImage: "power") {
                store.liveOutputEnabled = true
            }
            .buttonStyle(.glassProminent)
        } else if activeCount == 0 {
            Button("Open Codex", systemImage: "arrow.up.forward.app.fill") {
                store.openCodex()
            }
            .buttonStyle(.glassProminent)
        } else if let finishedPlacement {
            Button("Open Finished Run", systemImage: "checkmark.circle.fill") {
                store.selectAgent(finishedPlacement.agent)
            }
            .buttonStyle(.glassProminent)
        } else {
            Button("View Active Agents", systemImage: "cpu.fill") {
                store.selectedSection = .agents
            }
            .buttonStyle(.glassProminent)
        }
    }
}

struct SetupStepView: View {
    let title: String
    let detail: String
    let complete: Bool
    let current: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: complete ? "checkmark.circle.fill" : (current ? "arrow.right.circle.fill" : "circle"))
                .foregroundStyle(complete ? .green : (current ? .cyan : .secondary))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct DashboardSectionHeader: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(eyebrow)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.cyan)
            Text(title)
                .font(.title.bold())
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }
}

struct LEDDeckView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        let firmware = LEDFirmwareProgram(
            program: store.device.connected ? store.device.activeProgram : "off",
            ledCount: store.device.ledCount
        )
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("\(store.device.name) Array", systemImage: "lightbulb.led.wide.fill")
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(store.device.connected ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(store.device.connected ? "LIVE DEVICE FEED" : "DEVICE OFFLINE")
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                }

                HStack(alignment: .center, spacing: 28) {
                    TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                        let elapsed = store.device.lastWrite.map {
                            max(0, timeline.date.timeIntervalSince($0))
                        } ?? 0
                        let frame = firmware.frame(at: elapsed)

                        VStack(spacing: 12) {
                            ForEach(store.scene.slots.sorted(by: { $0.index > $1.index })) { slot in
                                LEDCell(
                                    slot: slot,
                                    outputColor: frame.colors.indices.contains(slot.index)
                                        ? frame.colors[slot.index]
                                        : .black
                                )
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 22)
                        .frame(width: 126)
                        .background(.black.opacity(0.68), in: .rect(cornerRadius: 30))
                        .overlay {
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .stroke(.white.opacity(0.1), lineWidth: 1)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("ASSIGNED SESSIONS · TOP TO BOTTOM")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        if store.scene.placementsTopToBottom.isEmpty {
                            Label("Array off", systemImage: "moon.fill")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(store.scene.placementsTopToBottom) { placement in
                                let color = Color(hex: store.selectedProfile.style(for: placement.agent.state).colorHex)
                                HStack(spacing: 11) {
                                    Capsule()
                                        .fill(color.gradient)
                                        .shadow(color: color.opacity(0.7), radius: 7)
                                        .frame(width: 7, height: 34)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(placement.agent.name)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Text("\(placement.rangeLabel) · \(placement.agent.state.title)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(color.opacity(0.07), in: .rect(cornerRadius: 13))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Label(
                    "The squircles mirror the hardware's color, global brightness, easing, delays, and animation phase.",
                    systemImage: "arrow.down"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(22)
            .glassEffect(.regular.tint(.cyan.opacity(0.08)), in: .rect(cornerRadius: 28))
        }
    }
}

struct LEDCell: View {
    let slot: AgentLEDSlot
    let outputColor: LEDProgramColor

    private var color: Color {
        Color(
            .sRGB,
            red: outputColor.red,
            green: outputColor.green,
            blue: outputColor.blue,
            opacity: 1
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(slot.index + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(color)
                .shadow(
                    color: color.opacity(min(0.88, outputColor.peak * 1.15)),
                    radius: 13
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .frame(width: 50, height: 50)
        }
        .help(slot.agent?.name ?? "Unassigned")
        .accessibilityLabel("LED \(slot.index + 1), \(slot.agent?.name ?? "off")")
    }
}

struct AgentGridView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions on the array").font(.title2.bold())
            Text("Select a session to open it. Finished sessions are acknowledged when opened.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            let placements = store.scene.placementsTopToBottom
            if placements.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ready for your next agent").font(.subheadline.weight(.semibold))
                        Text("Start or resume a Codex task — SidePulse discovers it automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular.tint(.cyan.opacity(0.06)), in: .rect(cornerRadius: 20))
            } else {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                    ForEach(placements) { placement in
                        AgentCard(agent: placement.agent, profile: store.selectedProfile)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AgentCard: View {
    let agent: AgentSession
    let profile: LightingProfile

    var body: some View {
        let color = Color(hex: profile.style(for: agent.state).colorHex)
        HStack(spacing: 14) {
            Image(systemName: agent.state.symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.13), in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(agent.provider.title) · \(agent.state.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .glassEffect(.regular.tint(color.opacity(0.08)).interactive(), in: .rect(cornerRadius: 20))
    }
}

struct ActionCenterView: View {
    @Bindable var store: CommandCenterStore

    private var currentState: AgentState {
        store.aggregateState == .idle ? .working : store.aggregateState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MAKE IT YOURS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.cyan)
            Text("Tune what the lights mean")
                .font(.title2.bold())
            Text("Start with the state you are seeing now. Everything else can wait.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                store.selectedState = currentState
                store.selectedSection = .lighting
            } label: {
                OverviewActionLabel(
                    title: "Tune \(currentState.title)",
                    detail: currentState == .working ? "Magenta · 1→\(store.device.ledCount) shimmer" : "Color, motion, and speed",
                    symbol: "paintpalette.fill"
                )
            }
            .buttonStyle(.glassProminent)

            Button {
                store.selectedSection = .profiles
            } label: {
                OverviewActionLabel(
                    title: "Choose a profile",
                    detail: store.selectedProfile.name,
                    symbol: "square.stack.3d.up.fill"
                )
            }
            .buttonStyle(.glass)

            Button {
                store.selectedSection = .system
            } label: {
                OverviewActionLabel(
                    title: "Manage connections",
                    detail: "Codex, Claude, Grok, and cloud",
                    symbol: "link"
                )
            }
            .buttonStyle(.glass)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Active sessions stay on", systemImage: "checkmark.circle.fill")
                Label("Finished sessions stay green until acknowledged", systemImage: "checkmark.circle.fill")
                Label("Activity never reshuffles residents", systemImage: "checkmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(22)
        .glassEffect(.regular.tint(.purple.opacity(0.07)), in: .rect(cornerRadius: 26))
    }
}

struct OverviewActionLabel: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SignalSummaryView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Signal policy").font(.headline)
            SignalMetric(title: "Active sessions", value: "Always on")
            SignalMetric(title: "Finished sessions", value: "Until acknowledged")
            SignalMetric(title: "State source", value: "Explicit events")
            Divider()
            Label("Activity changes state, not position", systemImage: "link")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

struct SignalMetric: View {
    let title: String
    let value: String
    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().fontWeight(.semibold)
        }
    }
}

struct LightingStudioView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(AgentState.allCases) { state in
                        StateStyleRow(
                            style: store.selectedProfile.style(for: state),
                            selected: store.selectedState == state,
                            action: { store.selectedState = state }
                        )
                    }
                }
            }
            .frame(width: 330)

            ScrollView {
                StyleInspectorView(store: store)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct StateStyleRow: View {
    let style: StateLightStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Circle()
                    .fill(Color(hex: style.colorHex))
                    .shadow(color: Color(hex: style.colorHex), radius: 6)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.state.title).fontWeight(.semibold)
                    Text("\(style.motion.title) · \(style.colorMode.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(
            selected ? .regular.tint(Color(hex: style.colorHex).opacity(0.18)) : .regular,
            in: .rect(cornerRadius: 18)
        )
    }
}

struct StyleInspectorView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        let style = store.selectedProfile.style(for: store.selectedState)
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(style.state.title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Shape exactly how this state looks on every assigned agent LED.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: previewColors(for: style),
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .shadow(color: Color(hex: style.colorHex).opacity(0.75), radius: 20)
                    .frame(width: 72, height: 72)
            }

            InspectorControl(title: "Color behavior") {
                Picker("Color behavior", selection: Binding(
                    get: { style.colorMode },
                    set: { colorMode in
                        var updated = style
                        updated.colorMode = colorMode
                        store.updateStyle(updated)
                    }
                )) {
                    ForEach(LightColorMode.allCases) { colorMode in
                        Text(colorMode.title).tag(colorMode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.large)

                Text(style.colorMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if style.colorMode != .rainbow {
                InspectorControl(title: style.colorMode == .single ? "Color" : "Colorway") {
                    ColorPicker(
                        style.colorMode == .single ? "State color" : "First color",
                        selection: Binding(
                            get: { Color(hex: style.colorHex) },
                            set: { newColor in
                                var updated = style
                                updated.colorHex = newColor.hexString
                                store.updateStyle(updated)
                            }
                        )
                    )
                    if style.colorMode != .single {
                        ColorPicker(
                            "Second color",
                            selection: Binding(
                                get: { Color(hex: style.secondaryColorHex) },
                                set: { newColor in
                                    var updated = style
                                    updated.secondaryColorHex = newColor.hexString
                                    store.updateStyle(updated)
                                }
                            )
                        )
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(previewColors(for: style).enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 18, height: 18)
                    }
                    Text("Spectrum generated automatically")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            InspectorControl(title: "Motion") {
                Picker("Motion", selection: Binding(
                    get: { style.motion },
                    set: { motion in
                        var updated = style
                        updated.motion = motion
                        store.updateStyle(updated)
                    }
                )) {
                    ForEach(LightMotion.allCases) { motion in Text(motion.title).tag(motion) }
                }
                .pickerStyle(.menu)
                .controlSize(.large)

                Text(style.motion.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            InspectorSlider(
                title: "Intensity",
                value: style.intensity,
                range: 0...1,
                formatted: "\(Int(style.intensity * 100))%"
            ) { value in
                var updated = style
                updated.intensity = value
                store.updateStyle(updated)
            }

            if style.motion.isAnimated || style.colorMode == .rotatingColorway {
                InspectorSlider(
                    title: "Cycle speed",
                    value: style.cycleSeconds,
                    range: 0.2...12,
                    formatted: "\(style.cycleSeconds.formatted(.number.precision(.fractionLength(0...1))))s"
                ) { value in
                    var updated = style
                    updated.cycleSeconds = value
                    store.updateStyle(updated)
                }
            }

            Spacer()
            HStack {
                Button("Reset State", systemImage: "arrow.counterclockwise") {
                    store.updateStyle(LightingProfile.factoryDefault.style(for: style.state))
                }
                Spacer()
                Button("Preview on SidePulse", systemImage: "play.fill") {
                    store.previewSelectedState()
                }
                    .buttonStyle(.glassProminent)
                    .disabled(!store.device.connected)
            }
        }
        .padding(26)
        .glassEffect(.regular.tint(Color(hex: style.colorHex).opacity(0.07)), in: .rect(cornerRadius: 28))
    }

    private func previewColors(for style: StateLightStyle) -> [Color] {
        switch style.colorMode {
        case .single:
            [Color(hex: style.colorHex), Color(hex: style.colorHex)]
        case .colorway:
            [Color(hex: style.colorHex), Color(hex: style.secondaryColorHex)]
        case .rainbow:
            [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]
        case .rotatingColorway:
            [
                Color(hex: style.colorHex),
                Color(hex: style.secondaryColorHex),
                Color(hex: style.colorHex),
            ]
        }
    }
}

struct InspectorControl<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}

struct InspectorSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let formatted: String
    let update: (Double) -> Void
    var body: some View {
        InspectorControl(title: title) {
            HStack {
                Slider(value: Binding(get: { value }, set: update), in: range)
                Text(formatted).monospacedDigit().frame(width: 54, alignment: .trailing)
            }
        }
    }
}

struct ProfilesView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Lighting Profiles").font(.largeTitle.bold())
                        Text("Build a setup for each part of your day, then switch it manually or with Focus.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import", systemImage: "square.and.arrow.down") { store.importProfiles() }
                        .buttonStyle(.glass)
                    Button("Export", systemImage: "square.and.arrow.up") { store.exportProfiles() }
                        .buttonStyle(.glass)
                    Button("New Profile", systemImage: "plus") { store.createProfile() }
                        .buttonStyle(.glassProminent)
                }

                HStack(alignment: .top, spacing: 18) {
                    SelectedProfileEditor(store: store)
                    FocusProfileCard(store: store)
                }

                if let message = store.profileTransferMessage {
                    Label(
                        message,
                        systemImage: store.profileTransferFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                        .font(.callout)
                        .foregroundStyle(store.profileTransferFailed ? Color.red : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("YOUR PROFILES")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [.init(.adaptive(minimum: 270), spacing: 16)], spacing: 16) {
                        ForEach(store.profiles) { profile in
                            ProfileCard(
                                profile: profile,
                                selected: profile.id == store.selectedProfileID,
                                isDefault: profile.id == store.defaultProfileID
                            ) {
                                store.selectProfile(profile.id)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }
}

struct SelectedProfileEditor: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Selected Profile", systemImage: store.selectedProfile.symbol)
                    .font(.headline)
                Spacer()
                if store.selectedProfileID == store.defaultProfileID {
                    Text("DEFAULT FALLBACK")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.cyan)
                }
            }

            TextField("Profile name", text: Binding(
                get: { store.selectedProfile.name },
                set: { store.renameSelectedProfile($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.title3.weight(.semibold))

            Picker("Array layout", selection: Binding(
                get: { store.selectedProfile.strategy },
                set: { strategy in store.updateSelectedProfile { $0.strategy = strategy } }
            )) {
                ForEach(SlotStrategy.allCases) { strategy in
                    Text(strategy.title).tag(strategy)
                }
            }

            HStack {
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    store.duplicateSelectedProfile()
                }
                .buttonStyle(.glass)

                Button("Delete", systemImage: "trash", role: .destructive) {
                    store.deleteSelectedProfile()
                }
                .buttonStyle(.glass)
                .disabled(store.selectedProfileID == store.defaultProfileID || store.profiles.count == 1)

                Spacer()
                Text("Tune colors and motion in Lighting Studio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.cyan.opacity(0.07)), in: .rect(cornerRadius: 26))
    }
}

struct FocusProfileCard: View {
    @Bindable var store: CommandCenterStore

    private var activeProfileName: String? {
        guard let activeID = store.activeFocusProfileID else { return nil }
        return store.profiles.first(where: { $0.id == activeID })?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Focus Automation", systemImage: "moon.circle.fill")
                    .font(.headline)
                Spacer()
                if let activeProfileName {
                    Text("\(activeProfileName.uppercased()) ACTIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.purple)
                } else if store.focusAutomationEnabled {
                    Text("AUTOMATION READY")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                }
            }

            Text("Add SidePulse as a Focus Filter, then choose a profile inside each Focus—School, Sleep, Work, or anything else you create.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(activeProfileName == nil
                 ? "When no configured Focus is active, SidePulse returns to Default."
                 : "This Focus is currently controlling SidePulse.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Open Focus Settings", systemImage: "arrow.up.forward.app") {
                store.openFocusSettings()
            }
            .buttonStyle(.glassProminent)
        }
        .padding(20)
        .frame(width: 390, alignment: .leading)
        .glassEffect(.regular.tint(.purple.opacity(0.08)), in: .rect(cornerRadius: 26))
    }
}

struct ProfileCard: View {
    let profile: LightingProfile
    let selected: Bool
    let isDefault: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: profile.symbol).font(.title2)
                    Spacer()
                    if isDefault {
                        Text("DEFAULT")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Text(profile.name).font(.title3.bold())
                HStack(spacing: 5) {
                    ForEach(profile.styles) { style in
                        Circle().fill(Color(hex: style.colorHex)).frame(width: 18, height: 18)
                    }
                }
                Text(profile.strategy.title).font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(.cyan.opacity(0.14)) : .regular, in: .rect(cornerRadius: 24))
    }
}

struct AgentsView: View {
    @Bindable var store: CommandCenterStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Agent Timeline").font(.largeTitle.bold())
                Spacer()
                RuntimePill(text: store.runtimeMessage)
            }
            if store.agents.isEmpty {
                Label("No agent is active right now. Codex sessions appear here automatically.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(store.scene.placementsTopToBottom) { placement in
                Button {
                    store.selectAgent(placement.agent)
                } label: {
                    HStack(spacing: 16) {
                        Text(placement.rangeLabel)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 78, alignment: .trailing)
                        AgentCard(agent: placement.agent, profile: store.selectedProfile)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

struct HardwareView: View {
    @Bindable var store: CommandCenterStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Hardware").font(.largeTitle.bold())
                Spacer()
                Toggle("Live output", isOn: $store.liveOutputEnabled).toggleStyle(.switch)
            }

            ForEach(store.hardwareDevices, id: \.path) { device in
                HardwareDeviceCard(device: device)
            }

            Label("Live Output is remembered between launches.", systemImage: "memorychip")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Compiled LED Scene").font(.headline)
            Text(store.scene.program)
                .textSelection(.enabled)
                .font(.body.monospaced())
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.45), in: .rect(cornerRadius: 16))
            Spacer()
        }
    }
}

struct HardwareDeviceCard: View {
    let device: DeviceState

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: device.connected ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")
                .font(.system(size: 34))
                .foregroundStyle(device.connected ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Text(device.name).font(.title3.bold())
                    Text(device.ledCount == 8 ? "8-LED PRIMARY" : "2-LED MIRROR")
                        .font(.caption2.bold())
                        .foregroundStyle(device.connected ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(device.connected ? 0.12 : 0.06), in: .capsule)
                }
                Text(device.connected ? "Connected" : "Waiting for device")
                    .foregroundStyle(.secondary)
                Text(device.ledCount == 8
                    ? "Eight-LED scene stays unchanged as the primary output."
                    : "40% brightness · 25% blue compensation · fluid two-dot fade.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if device.connected {
                    Text(device.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                if let error = device.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let lastWrite = device.lastWrite {
                    Label("Last write \(lastWrite.formatted(date: .omitted, time: .standard))", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
        }
        .padding(22)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

struct SystemView: View {
    @Bindable var store: CommandCenterStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connections & Battery").font(.largeTitle.bold())
                        Text("Agent signals and the system scenes that temporarily take over your SidePulse.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                BatterySettingsCard(store: store)
                Divider()
                ForEach(store.integrations) { integration in
                    IntegrationStatusCard(integration: integration)
                }
                FeaturePlaceholder(
                    title: "ChatGPT Chats",
                    subtitle: "Waiting for a supported local thinking / finished signal",
                    symbol: "bubble.left.and.bubble.right.fill",
                    badge: "Planned"
                )
                Spacer()
            }
        }
        .scrollIndicators(.hidden)
    }
}

struct BatterySettingsCard: View {
    @Bindable var store: CommandCenterStore

    private var batteryStatus: String {
        guard let state = store.batteryState else { return "Reading battery state…" }
        let percent = Int((state.chargeFraction * 100).rounded())
        let power = state.isCharging ? "Charging" : state.isExternallyPowered ? "AC Power" : "On Battery"
        let lid = store.lidIsClosed.map { $0 ? "Lid closed" : "Lid open" } ?? "Detecting lid"
        return "\(percent)% · \(power) · \(lid)"
    }

    private func settingBinding<Value>(
        _ keyPath: WritableKeyPath<BatteryIndicatorSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.batterySettings[keyPath: keyPath] },
            set: { value in
                store.updateBatterySettings { $0[keyPath: keyPath] = value }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "battery.75percent")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .frame(width: 44, height: 44)
                    .background(.green.opacity(0.12), in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Show Charge Info").font(.headline)
                    Text(batteryStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Show Charge Info", isOn: settingBinding(\.showsChargeInfo))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            VStack(alignment: .leading, spacing: 14) {
                Divider()
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Battery indication").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Picker("Battery indication", selection: Binding(
                            get: { store.batterySettings.mode },
                            set: { store.selectBatteryIndicatorMode($0) }
                        )) {
                            ForEach(BatteryIndicatorMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 260)
                    }
                    Button {
                        store.previewBatteryIndicator()
                    } label: {
                        Label("Preview", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.proDevice.connected)
                    Spacer()
                }
                Text(store.batterySettings.mode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                HStack(spacing: 24) {
                    Toggle("When lid is opened", isOn: settingBinding(\.showsWhenLidOpens))
                    Toggle("When lid is closed", isOn: settingBinding(\.showsWhenLidCloses))
                    Spacer()
                }
                .toggleStyle(.switch)

                Divider()
                HStack(spacing: 18) {
                    Toggle("Low battery reminder", isOn: settingBinding(\.lowBatteryReminderEnabled))
                        .toggleStyle(.switch)
                    Stepper(
                        "Below \(store.batterySettings.lowBatteryThresholdPercent)%",
                        value: settingBinding(\.lowBatteryThresholdPercent),
                        in: 5...100,
                        step: 5
                    )
                    Stepper(
                        "Every \(store.batterySettings.lowBatteryReminderIntervalSeconds)s",
                        value: settingBinding(\.lowBatteryReminderIntervalSeconds),
                        in: 5...3_600,
                        step: 5
                    )
                    Spacer()
                }
            }
            .disabled(!store.batterySettings.showsChargeInfo)
            .opacity(store.batterySettings.showsChargeInfo ? 1 : 0.45)
        }
        .padding(20)
        .glassEffect(.regular.tint(.green.opacity(0.035)), in: .rect(cornerRadius: 24))
    }
}

struct DiagnosticsView: View {
    @Bindable var store: CommandCenterStore
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Diagnostics").font(.largeTitle.bold())
            FeaturePlaceholder(title: "Native Runtime", subtitle: store.runtimeMessage, symbol: "waveform.path.ecg", badge: "Running")
            FeaturePlaceholder(title: "Scene Compiler", subtitle: "\(store.scene.program.utf8.count) byte firmware program", symbol: "curlybraces.square", badge: "Ready")
            FeaturePlaceholder(
                title: "Hardware Writer",
                subtitle: store.device.connected ? store.device.path : "Waiting for a mounted SidePulse device",
                symbol: "externaldrive.badge.checkmark",
                badge: store.device.connected ? "Connected" : "Waiting"
            )
            Spacer()
        }
    }
}

struct IntegrationStatusCard: View {
    let integration: AgentIntegrationStatus

    private var color: Color {
        switch integration.state {
        case .active: .green
        case .ready: .cyan
        case .needsSetup: .orange
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: integration.state.symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(integration.provider.title).font(.headline)
                Text(integration.detail).foregroundStyle(.secondary)
                if let lastEventAt = integration.lastEventAt {
                    Text("Last signal \(lastEventAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text(integration.state.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(color.opacity(0.1), in: .capsule)
        }
        .padding(18)
        .glassEffect(.regular.tint(color.opacity(0.04)), in: .rect(cornerRadius: 20))
    }
}

struct FeaturePlaceholder: View {
    let title: String
    let subtitle: String
    let symbol: String
    var badge = "Next"
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.title2).frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            Text(badge).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct ProfileBadge: View {
    let profile: LightingProfile
    var body: some View {
        Label(profile.name, systemImage: profile.symbol)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .capsule)
    }
}

struct RuntimePill: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "sparkles")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
    }
}

struct CommandCenterBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(nsColor: .windowBackgroundColor), .cyan.opacity(0.045), .purple.opacity(0.035)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(clean, radix: 16) ?? 0xFFFFFF
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}

#Preview {
    ContentView(store: CommandCenterStore())
}
