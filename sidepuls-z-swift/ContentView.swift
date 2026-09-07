import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var store: CommandCenterStore
#if PEEL_HOST_INTEGRATION
    @Environment(PeelUnifiedModel.self) private var peel
    var peelHostContent: AnyView? = nil
    private var usageStore: PeelUsageStore { peel.usage }
#elseif PEEL_WORKSPACE
    @State private var usageStore = PeelUsageStore()
#endif

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 164, ideal: 184, max: 220)
        } detail: {
            ZStack {
                CommandCenterBackground()
                detail.padding(18)
            }
            .navigationTitle(store.selectedSection.title)
            .toolbar { toolbar }
        }
        .frame(minWidth: 880, minHeight: 580)
#if PEEL_WORKSPACE
        .onAppear {
            usageStore.startPresentation()
            if ProcessInfo.processInfo.arguments.contains("--peel-preview") {
#if !PEEL_HOST_INTEGRATION
                store.selectedSection = .usage
#endif
            }
        }
#if !PEEL_HOST_INTEGRATION
        .onDisappear { usageStore.stopPresentation() }
#endif
#endif
    }

    private var sidebar: some View {
        List(selection: $store.selectedSection) {
#if PEEL_HOST_INTEGRATION
            Section("Peel") {
                Label(CommandCenterSection.host.title, systemImage: CommandCenterSection.host.symbol)
                    .tag(CommandCenterSection.host)
                Label(CommandCenterSection.remoteMac.title, systemImage: CommandCenterSection.remoteMac.symbol)
                    .tag(CommandCenterSection.remoteMac)
            }
#endif
            Section {
                Label(CommandCenterSection.overview.title, systemImage: CommandCenterSection.overview.symbol)
                    .tag(CommandCenterSection.overview)
                Label(CommandCenterSection.agents.title, systemImage: CommandCenterSection.agents.symbol)
                    .tag(CommandCenterSection.agents)
#if PEEL_WORKSPACE && !PEEL_HOST_INTEGRATION
                Label(CommandCenterSection.usage.title, systemImage: CommandCenterSection.usage.symbol)
                    .tag(CommandCenterSection.usage)
#endif
                Label(CommandCenterSection.lighting.title, systemImage: CommandCenterSection.lighting.symbol)
                    .tag(CommandCenterSection.lighting)
                Label(CommandCenterSection.hardware.title, systemImage: CommandCenterSection.hardware.symbol)
                    .tag(CommandCenterSection.hardware)
            }
#if PEEL_HOST_INTEGRATION
            Section("Usage & System") {
                Label(CommandCenterSection.usage.title, systemImage: CommandCenterSection.usage.symbol)
                    .tag(CommandCenterSection.usage)
                Label(CommandCenterSection.mechanic.title, systemImage: CommandCenterSection.mechanic.symbol)
                    .tag(CommandCenterSection.mechanic)
            }
#endif
            Section {
                Label(CommandCenterSection.settings.title, systemImage: CommandCenterSection.settings.symbol)
                    .tag(CommandCenterSection.settings)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch store.selectedSection {
        case .overview: OverviewView(store: store)
        case .lighting: LightingStudioView(store: store)
        case .agents: AgentsView(store: store)
        case .hardware: HardwareView(store: store)
        case .settings: SettingsView(store: store)
#if PEEL_WORKSPACE
        case .usage: PeelUsageView(store: usageStore)
#endif
#if PEEL_HOST_INTEGRATION
        case .host:
            ScrollView { peelHostContent }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .remoteMac:
            if let viewer = peel.remoteMacViewer {
                PeelRemoteMacViewerView(controller: viewer)
            } else {
                ContentUnavailableView("Remote Mac", systemImage: "desktopcomputer",
                    description: Text("Open Host to prepare your paired Mac connections."))
            }
        case .mechanic:
            PeelMechanicSurface(processSampler: peel.sampler, systemMetrics: peel.systemMetrics,
                                presentation: .controlPanel)
#endif
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            UtilityControlsView(store: store)
                .padding(3)
                .glassEffect(.regular, in: .capsule)
        }
    }
}

struct OverviewView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CommandCenterHero(store: store)
#if PEEL_HOST_INTEGRATION
                if let hostOverviewSummary = store.hostOverviewSummary {
                    hostOverviewSummary
                }
#endif
                OverviewSignalRoutesView(store: store)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        LEDDeckView(store: store)
                            .frame(maxWidth: .infinity)
                        OverviewAgentsView(store: store)
                            .frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        LEDDeckView(store: store)
                        OverviewAgentsView(store: store)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }
}

struct OverviewSignalRoutesView: View {
    @Bindable var store: CommandCenterStore

    private var connectedCount: Int {
        store.hardwareDevices.filter(\.connected).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.purple)
                Text("Signal Routes")
                    .font(.headline)
                Text(routeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Manage", systemImage: "arrow.right") {
                    store.selectedSection = .hardware
                }
                .controlSize(.small)
                .buttonStyle(.glass)
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(store.hardwareDevices, id: \.kind) { device in
                        OverviewSignalRouteRow(store: store, device: device)
                            .frame(maxWidth: .infinity)
                    }
                }
                VStack(spacing: 8) {
                    ForEach(store.hardwareDevices, id: \.kind) { device in
                        OverviewSignalRouteRow(store: store, device: device)
                    }
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var routeSummary: String {
        let devices = "\(connectedCount) local output\(connectedCount == 1 ? "" : "s")"
        guard store.nearbyDiscoveryEnabled else { return devices }
        let macs = "\(store.nearbyPeers.count) nearby Mac\(store.nearbyPeers.count == 1 ? "" : "s")"
        return "\(devices) · \(macs)"
    }
}

private struct OverviewSignalRouteRow: View {
    @Bindable var store: CommandCenterStore
    let device: DeviceState

    private var selectedSourceName: String {
        switch store.signalSource(for: device.kind) {
        case .thisMac:
            return "This Mac"
        case .allMacs:
            return "All Macs"
        case .nearbyMac(let peerID):
            return store.nearbyPeers.first(where: { $0.id == peerID })?.displayName ?? "Unavailable Mac"
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: device.connected ? "lightbulb.led.fill" : "lightbulb.led")
                .foregroundStyle(device.connected ? .primary : .tertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(selectedSourceName)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(device.name)
                        .lineLimit(1)
                }
                .font(.subheadline.weight(.semibold))
                Text(device.connected ? store.signalSourceStatus(for: device.kind) : "Connect to use this output")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Circle()
                .fill(routeColor)
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.035), in: .rect(cornerRadius: 10))
    }

    private var routeColor: Color {
        guard device.connected else { return .secondary.opacity(0.45) }
        return store.routedSignalSourceName(for: device.kind) == "No active signal" ? .orange : .green
    }
}

struct CommandCenterHero: View {
    @Bindable var store: CommandCenterStore

    private var activeCount: Int { store.agents.count }
    private var finishedPlacement: AgentArrayPlacement? {
        guard store.agentDisplayMode == .perAgent else { return nil }
        let placements = store.scene.placementsTopToBottom
        guard !placements.isEmpty, placements.allSatisfy({ $0.agent.state == .completed }) else { return nil }
        return placements.first
    }

    private var title: String {
        if let title = store.utilityStatusTitle { return title }
        if !store.device.connected { return "Connect your SidePulse" }
        if !store.outputPowerIsOn { return "Turn on Live Output" }
        if activeCount == 0 { return "Start an agent" }
        if store.agentDisplayMode == .simple, store.aggregateState == .completed { return "Run finished" }
        if finishedPlacement != nil { return "Run finished" }
        return "SidePulse is live"
    }

    private var detail: String {
        if store.displayedUtilityMode != .agents { return store.utilityStatusDetail }
        if !store.device.connected {
            return "Plug in the device. SidePulse will detect it automatically and show you the exact hardware path."
        }
        if !store.outputPowerIsOn {
            return "The device is connected, but lighting output is paused. Turn it on to show active sessions."
        }
        if activeCount == 0 {
            return "Start or resume a Codex task. It will appear here automatically—there is no extra setup step."
        }
        if store.agentDisplayMode == .simple {
            if store.aggregateState == .completed {
                return "The full array stays green until the finished work is acknowledged."
            }
            return "The full array shows one prioritized state across \(activeCount) detected session\(activeCount == 1 ? "" : "s"). Tool activity is included in Thinking."
        }
        if finishedPlacement != nil {
            return "Green stays lit until the result is acknowledged. Open the finished session when you are ready for the next run."
        }
        let noun = activeCount == 1 ? "session" : "sessions"
        return "\(activeCount) active \(noun) mapped to the physical array. State changes update color and motion without reshuffling the agents."
    }

    private var tint: Color {
        switch store.displayedUtilityMode {
        case .agents:
            if !store.device.connected || !store.outputPowerIsOn { return .orange }
            if activeCount == 0 { return .cyan }
            return .green
        case .microphone:
            return Color(hex: store.onAirStyle?.colorHex ?? "#FF9F0A")
        case .timer:
            switch store.timerState.phase {
            case .running: return .purple
            case .paused: return .orange
            case .finished: return .green
            case .idle: return .secondary
            }
        case .progress:
            switch store.progressSnapshot.phase {
            case .idle: return .secondary
            case .running: return .cyan
            case .completed: return .green
            case .failed: return .red
            case .cancelled: return .orange
            }
        }
    }

    private var statusLabel: String {
        if store.displayedUtilityMode != .agents { return store.displayedUtilityMode.title.uppercased() }
        if !store.device.connected || !store.outputPowerIsOn { return "ACTION NEEDED" }
        if activeCount == 0 { return "READY" }
        if store.agentDisplayMode == .simple, store.aggregateState == .completed { return "READY FOR YOU" }
        if finishedPlacement != nil { return "READY FOR YOU" }
        return "LIVE NOW"
    }

    private var heroSymbol: String {
        switch store.displayedUtilityMode {
        case .agents:
            activeCount > 0 ? "wave.3.right" : "sparkles"
        case .microphone:
            store.onAirSymbol
        case .timer:
            switch store.timerState.phase {
            case .running: "timer"
            case .paused: "pause.circle.fill"
            case .finished: "checkmark.circle.fill"
            case .idle: "timer"
            }
        case .progress:
            switch store.progressSnapshot.phase {
            case .idle: "circle"
            case .running: "arrow.triangle.2.circlepath"
            case .completed: "checkmark.circle.fill"
            case .failed: "xmark.octagon.fill"
            case .cancelled: "slash.circle"
            }
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.13))
                Image(systemName: heroSymbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 5) {
                Text(statusLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 7) {
                if store.displayedUtilityMode == .agents {
                    Picker("Signal Mode", selection: Binding(
                        get: { store.agentDisplayMode },
                        set: { store.selectAgentDisplayMode($0) }
                    )) {
                        ForEach(AgentDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 176)
                }

                HStack(spacing: 7) {
                    primaryAction
                    if store.displayedUtilityMode == .agents, activeCount > 0, store.device.connected, store.outputPowerIsOn {
                        Button("Tune signal", systemImage: "paintpalette.fill") {
                            store.selectedState = store.aggregateState == .idle ? .working : store.aggregateState
                            store.selectedSection = .lighting
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .glassEffect(.regular.tint(tint.opacity(0.08)), in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private var primaryAction: some View {
        if store.displayedUtilityMode != .agents {
            Button("Agent lighting", systemImage: "cpu") { store.selectUtilityMode(.agents) }
                .buttonStyle(.glass)
        } else if !store.device.connected {
            Button("Open Hardware", systemImage: "externaldrive.fill") {
                store.selectedSection = .hardware
            }
            .buttonStyle(.glassProminent)
        } else if !store.outputPowerIsOn {
            Button("Turn On Live Output", systemImage: "power") {
                store.setOutputPower(true)
            }
            .buttonStyle(.glassProminent)
        } else if activeCount == 0 {
            Button("Open Codex", systemImage: "arrow.up.forward.app.fill") {
                store.openCodex()
            }
            .buttonStyle(.glassProminent)
        } else if store.agentDisplayMode == .simple, store.aggregateState == .completed {
            Button("View Finished Runs", systemImage: "checkmark.circle.fill") {
                store.selectedSection = .agents
            }
            .buttonStyle(.glassProminent)
        } else if let finishedPlacement {
            Button("Open Finished Run", systemImage: "checkmark.circle.fill") {
                store.openAgent(finishedPlacement.agent)
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

struct SignalModeControl: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                Image(systemName: "slider.horizontal.3")
                    .font(.headline)
                    .foregroundStyle(.cyan)
                    .frame(width: 34, height: 34)
                    .background(.cyan.opacity(0.1), in: .rect(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Controls").font(.headline)
                    Text("Device and app behavior")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("SIGNAL MODE")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Picker("Signal Mode", selection: Binding(
                    get: { store.agentDisplayMode },
                    set: { store.selectAgentDisplayMode($0) }
                )) {
                    ForEach(AgentDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Max brightness")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((store.universalBrightness * 100).rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { store.universalBrightness },
                        set: { store.setUniversalBrightness($0) }
                    ),
                    in: 0...1,
                    step: 0.01
                )
                .tint(.purple)
                .controlSize(.small)
                .accessibilityLabel("Max Brightness")
                .accessibilityValue("\(Int((store.universalBrightness * 100).rounded())) percent")
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Color balance", systemImage: "camera.filters")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("Adjust red, green, and blue output across every SidePulse Pro lighting mode. SidePulse Dot is unchanged.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                colorBalanceSlider("Red", tint: .red, keyPath: \.red)
                colorBalanceSlider("Green", tint: .green, keyPath: \.green)
                colorBalanceSlider("Blue", tint: .blue, keyPath: \.blue)
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Label("Flashlight behavior", systemImage: "flashlight.on.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Flashlight Behavior", selection: Binding(
                        get: { store.flashlightMode },
                        set: { store.selectFlashlightMode($0) }
                    )) {
                        ForEach(FlashlightMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Text(store.flashlightMode.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 8) {
                Text("Menu bar icon")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Menu Bar Icon", selection: Binding(
                    get: { store.menuBarIconStyle },
                    set: { store.selectMenuBarIconStyle($0) }
                )) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Toggle("Start at login", isOn: Binding(
                get: { store.launchAtLoginEnabled },
                set: { store.setLaunchAtLoginEnabled($0) }
            ))
            .font(.caption)
            .toggleStyle(.switch)

            if let message = store.launchAtLoginMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if store.launchAtLoginNeedsApproval {
                        Button("Open Login Items") {
                            store.openLoginItemsSettings()
                        }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .padding(20)
        .glassEffect(.regular.tint(.cyan.opacity(0.06)), in: .rect(cornerRadius: 22))
        .onAppear {
            store.refreshLaunchAtLoginStatus()
        }
    }

    private func colorBalanceSlider(
        _ title: String,
        tint: Color,
        keyPath: WritableKeyPath<OutputColorBalance, Double>
    ) -> some View {
        let value = store.proColorBalance[keyPath: keyPath]
        return HStack(spacing: 8) {
            Text(title)
                .font(.caption2)
                .frame(width: 36, alignment: .leading)

            Slider(
                value: Binding(
                    get: { store.proColorBalance[keyPath: keyPath] },
                    set: { newValue in
                        var balance = store.proColorBalance
                        balance[keyPath: keyPath] = newValue
                        store.setProColorBalance(balance)
                    }
                ),
                in: 0...1,
                step: 0.01
            )
            .tint(tint)
            .controlSize(.small)
            .accessibilityLabel("\(title) Color Balance")
            .accessibilityValue("\(Int((value * 100).rounded())) percent")

            Text("\(Int((value * 100).rounded()))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, profiles, battery, modes, connections, diagnostics

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "App"
        case .profiles: "Profiles"
        case .battery: "Battery"
        case .modes: "Modes"
        case .connections: "Integrations"
        case .diagnostics: "Diagnostics"
        }
    }
}

struct SettingsView: View {
    @Bindable var store: CommandCenterStore
    @State private var selectedPane = SettingsPane.general

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text("Preferences").font(.title2.bold())
                    Spacer(minLength: 8)
                    settingsPanePicker
                        .frame(width: 520)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preferences").font(.title2.bold())
                    settingsPanePicker
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Group {
                switch selectedPane {
                case .general:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            SignalModeControl(store: store)
                        }
                            .frame(maxWidth: 620, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                case .profiles:
                    ProfilesView(store: store)
                case .battery:
                    BatteryView(store: store)
                case .modes:
                    UtilitySettingsView(store: store)
                case .connections:
                    ConnectionsView(store: store)
                case .diagnostics:
                    DiagnosticsView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear { openRequestedPane() }
        .onChange(of: store.showsModeSettings) { _, _ in openRequestedPane() }
    }

    private var settingsPanePicker: some View {
        Picker("Preferences", selection: $selectedPane) {
            ForEach(SettingsPane.allCases) { pane in
                Text(pane.title).tag(pane)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private func openRequestedPane() {
        if store.showsModeSettings {
            selectedPane = .modes
            store.showsModeSettings = false
        }
    }
}

struct NearbySignalNetworkCard: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
#if PEEL_HOST_INTEGRATION
        VStack(alignment: .leading, spacing: 14) {
            PeelTrustedSignalsCard(store: store)
            legacyNetworkBody
        }
#else
        legacyNetworkBody
#endif
    }

    private var legacyNetworkBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "network")
                    .font(.headline)
                    .foregroundStyle(.purple)
                    .frame(width: 30, height: 30)
                    .background(.purple.opacity(0.1), in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mac-to-Mac Signal").font(.headline)
                    Text(store.nearbyDisplayStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Label(relationshipLabel, systemImage: relationshipSymbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(statusColor.opacity(0.1), in: .capsule)
            }

            HStack(spacing: 10) {
                signalMacEndpoint(
                    title: store.localMacDisplayName,
                    detail: localMacDetail,
                    symbol: "desktopcomputer"
                )

                Image(systemName: relationshipSymbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 28)

                signalMacEndpoint(
                    title: nearbyMacTitle,
                    detail: nearbyMacDetail,
                    symbol: "desktopcomputer.and.arrow.down"
                )
            }

            if store.nearbyDiscoveryEnabled, !store.nearbyPeers.isEmpty {
                VStack(spacing: 0) {
                    ForEach(store.nearbyPeers) { peer in
                        HStack(spacing: 9) {
                            Circle()
                                .fill(store.nearbyServiceSnapshot.readyOutboundPeerIDs.contains(peer.id) ? Color.green : Color.secondary.opacity(0.55))
                                .frame(width: 7, height: 7)
                            Text(peer.displayName)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(store.nearbyServiceSnapshot.readyOutboundPeerIDs.contains(peer.id) ? "Connection ready" : "Available")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        if peer.id != store.nearbyPeers.last?.id { Divider() }
                    }
                }
                .background(.primary.opacity(0.025), in: .rect(cornerRadius: 10))
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 28) {
                    networkToggles
                }
                VStack(alignment: .leading, spacing: 10) {
                    networkToggles
                }
            }

            Label(
                "Each local SidePulse chooses its source below. Mac-to-Mac sharing sends only compiled LED color, motion, and timing on your local network.",
                systemImage: "lock.shield.fill"
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private var networkToggles: some View {
        Toggle("Share this Mac", isOn: Binding(
            get: { store.nearbySharingEnabled },
            set: { store.setNearbySharingEnabled($0) }
        ))
        .toggleStyle(.switch)
        .help("Let a SidePulse connected to another Mac use this Mac's signal")

        Toggle("Find nearby Macs", isOn: Binding(
            get: { store.nearbyDiscoveryEnabled },
            set: { store.setNearbyDiscoveryEnabled($0) }
        ))
        .toggleStyle(.switch)
        .help("Let this Mac route a local SidePulse from another Mac")
    }

    private func signalMacEndpoint(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(.primary.opacity(0.035), in: .rect(cornerRadius: 11))
    }

    private var nearbyMacTitle: String {
        if store.nearbyServiceSnapshot.readyOutboundPeerIDs.count == 1,
           let peerID = store.nearbyServiceSnapshot.readyOutboundPeerIDs.first,
           let peer = store.nearbyPeers.first(where: { $0.id == peerID }) {
            return peer.displayName
        }
        if store.nearbyPeers.count <= 1 { return "Nearby Macs" }
        return "\(store.nearbyPeers.count) Nearby Macs"
    }

    private var localMacDetail: String {
        let receivers = store.nearbyServiceSnapshot.inboundReceiverCount
        if receivers > 0 {
            return "Connected to \(receivers) nearby Mac\(receivers == 1 ? "" : "s")"
        }
        if store.nearbyServiceSnapshot.listenerReady { return "Available as a source" }
        return store.nearbySharingEnabled ? "Starting local sharing" : "Local signal only"
    }

    private var nearbyMacDetail: String {
        guard store.nearbyDiscoveryEnabled else { return "Discovery is off" }
        let connected = store.nearbyServiceSnapshot.readyOutboundPeerIDs.count
        if connected > 0 {
            if let lastSignalAt = store.nearbyLastSignalAt {
                return "Signal received \(lastSignalAt.formatted(.relative(presentation: .named)))"
            }
            return "\(connected) connection\(connected == 1 ? "" : "s") ready"
        }
        guard !store.nearbyPeers.isEmpty else { return "Searching on local network" }
        if let lastSignalAt = store.nearbyLastSignalAt {
            return "Signal received \(lastSignalAt.formatted(.relative(presentation: .named)))"
        }
        return "Available as signal sources"
    }

    private var relationshipLabel: String {
        let outbound = store.nearbyServiceSnapshot.readyOutboundPeerIDs.count
        let inbound = store.nearbyServiceSnapshot.inboundReceiverCount
        if outbound > 0, inbound > 0 {
            return "Both directions connected"
        }
        if outbound > 0 { return "Receiving from \(outbound)" }
        if inbound > 0 { return "Sharing to \(inbound)" }
        return switch (store.nearbySharingEnabled, store.nearbyDiscoveryEnabled) {
        case (true, true): "Two-way enabled"
        case (true, false): "Sharing enabled"
        case (false, true): "Receiving enabled"
        case (false, false): "Local only"
        }
    }

    private var relationshipSymbol: String {
        let outbound = !store.nearbyServiceSnapshot.readyOutboundPeerIDs.isEmpty
        let inbound = store.nearbyServiceSnapshot.inboundReceiverCount > 0
        if outbound && inbound { return "arrow.left.arrow.right" }
        if outbound { return "arrow.left" }
        if inbound { return "arrow.right" }
        return switch (store.nearbySharingEnabled, store.nearbyDiscoveryEnabled) {
        case (true, true): "arrow.left.arrow.right"
        case (true, false): "arrow.right"
        case (false, true): "arrow.left"
        case (false, false): "minus"
        }
    }

    private var statusColor: Color {
        if store.nearbySharingEnabled && store.nearbyDiscoveryEnabled { return .purple }
        if store.nearbySharingEnabled { return .cyan }
        if store.nearbyDiscoveryEnabled { return .green }
        return .secondary
    }
}

struct OverviewAgentsView: View {
    @Bindable var store: CommandCenterStore

    private var visibleAgents: [AgentSession] { Array(store.agents.prefix(4)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent Hub").font(.title2.bold())
                    Text("Open a session or view the full hub.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(store.agents.count) detected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button("Open Hub", systemImage: "arrow.right") {
                    store.selectedSection = .agents
                }
                .controlSize(.small)
                .buttonStyle(.glass)
            }

            if visibleAgents.isEmpty {
                Label("No active sessions", systemImage: "moon.stars.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(visibleAgents) { agent in
                        Button {
                            store.openAgent(agent)
                        } label: {
                            AgentCard(agent: agent, profile: store.selectedProfile)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(agent.name)")
                    }
                }
                if store.agents.count > visibleAgents.count {
                    Button("\(store.agents.count - visibleAgents.count) more in Agent Hub") {
                        store.selectedSection = .agents
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.link)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular.tint(.purple.opacity(0.05)), in: .rect(cornerRadius: 24))
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
                        Text(store.device.connected ? "LIVE DEVICE FEED" : store.displayedUtilityMode == .agents ? "DEVICE OFFLINE" : "SCREEN PREVIEW")
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                }

                HStack(alignment: .center, spacing: 28) {
                    DisplayLinkedLEDArray(
                        program: store.displayedUtilityMode == .agents ? store.connectedSoftwareDisplayProgram : store.softwareDisplayProgram,
                        ledCount: store.device.ledCount,
                        clockOrigin: store.softwareDisplayClockOrigin,
                        style: .commandCenter
                    )
                        .frame(
                            width: LEDArrayPreviewStyle.commandCenter.size(
                                ledCount: store.device.ledCount
                            ).width,
                            height: LEDArrayPreviewStyle.commandCenter.size(
                                ledCount: store.device.ledCount
                            ).height
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .frame(width: 92)
                        .background(.black.opacity(0.68), in: .rect(cornerRadius: 22))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(.white.opacity(0.1), lineWidth: 1)
                        }

                    VStack(alignment: .leading, spacing: 12) {
                        Text(store.displayedUtilityMode != .agents ? "\(store.displayedUtilityMode.title.uppercased()) · FULL ARRAY" : store.agentDisplayMode == .simple
                            ? "ONE SIGNAL · FULL ARRAY"
                            : "ASSIGNED SESSIONS · TOP TO BOTTOM")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                        if let title = store.utilityStatusTitle {
                            Text(title).font(.title3.weight(.semibold))
                            Text(store.utilityStatusDetail).font(.caption).foregroundStyle(.secondary)
                            Button("Agent lighting", systemImage: "cpu") { store.selectUtilityMode(.agents) }
                                .buttonStyle(.glass)
                        } else if store.scene.placementsTopToBottom.isEmpty {
                            Label("Array off", systemImage: "moon.fill")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(store.scene.placementsTopToBottom.prefix(store.agentDisplayMode == .simple ? 1 : 4)) { placement in
                                let color = Color(hex: store.selectedProfile.style(for: placement.agent.state).colorHex)
                                HStack(spacing: 11) {
                                    Capsule()
                                        .fill(color.gradient)
                                        .shadow(color: color.opacity(0.7), radius: 7)
                                        .frame(width: 7, height: 34)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(store.agentDisplayMode == .simple
                                            ? placement.agent.state.title
                                            : placement.agent.name)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1)
                                        Text(store.agentDisplayMode == .simple
                                            ? "All LEDs · highest-priority state"
                                            : "\(placement.rangeLabel) · \(placement.agent.state.title)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(color.opacity(0.07), in: .rect(cornerRadius: 13))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

            }
            .padding(16)
            .glassEffect(.regular.tint(.cyan.opacity(0.08)), in: .rect(cornerRadius: 22))
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
            Text("Select a session to open it. Finished, approval, and failed signals are acknowledged when opened.")
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
                        Button {
                            store.openAgent(placement.agent)
                        } label: {
                            AgentCard(agent: placement.agent, profile: store.selectedProfile)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(placement.agent.name)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SimpleSignalView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        let state = store.aggregateState
        let color = Color(hex: store.selectedProfile.style(for: state).colorHex)
        VStack(alignment: .leading, spacing: 12) {
            Text("One signal").font(.title2.bold())
            Text("The highest-priority state owns the entire array. Individual sessions stay available in Agents without competing for LEDs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Image(systemName: state.symbol)
                    .font(.title)
                    .foregroundStyle(color)
                    .frame(width: 54, height: 54)
                    .background(color.opacity(0.12), in: .circle)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title)
                        .font(.title3.bold())
                    Text("\(store.agents.count) detected session\(store.agents.count == 1 ? "" : "s") · all \(store.device.ledCount) LEDs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            .glassEffect(.regular.tint(color.opacity(0.1)), in: .rect(cornerRadius: 20))
            Text("Failure → Approval → Thinking → Done · tools count as Thinking")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
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
                store.selectedSection = .settings
            } label: {
                OverviewActionLabel(
                    title: "Choose a profile",
                    detail: store.selectedProfile.name,
                    symbol: "square.stack.3d.up.fill"
                )
            }
            .buttonStyle(.glass)

            Button {
                store.selectedSection = .settings
            } label: {
                OverviewActionLabel(
                    title: "Manage connections",
                    detail: "Codex, Grok Bot, Grok, Claude, and cloud",
                    symbol: "link"
                )
            }
            .buttonStyle(.glass)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Label("Active sessions stay on", systemImage: "checkmark.circle.fill")
                Label("Finished sessions stay green until acknowledged", systemImage: "checkmark.circle.fill")
                if store.agentDisplayMode == .simple {
                    Label("Tool activity counts as Thinking", systemImage: "checkmark.circle.fill")
                    Label("Priority state owns the full array", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Activity never reshuffles residents", systemImage: "checkmark.circle.fill")
                }
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
    @State private var showsProgress = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Agent states")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)

                    VStack(spacing: 2) {
                        ForEach(AgentState.allCases.filter {
                            store.agentDisplayMode == .perAgent || $0 != .toolRunning
                        }) { state in
                            StateStyleRow(
                                style: store.selectedProfile.style(for: state),
                                selected: !showsProgress && store.selectedState == state,
                                action: { showsProgress = false; store.selectedState = state }
                            )
                        }
                    }

                    Text("Utility")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)

                    ProgressStudioRow(
                        selected: showsProgress,
                        action: { showsProgress = true }
                    )
                }
                .padding(10)
                .frame(width: 232, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
            }
            .frame(width: 232)

            ScrollView {
                if showsProgress {
                    ProgressModeStudioView(store: store)
                        .frame(maxWidth: .infinity)
                } else {
                    StyleInspectorView(store: store)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

private struct StudioRowButtonStyle: ButtonStyle {
    let tint: Color
    let selected: Bool
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 52, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(fillColor(isPressed: configuration.isPressed))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(borderColor(isPressed: configuration.isPressed), lineWidth: selected ? 1.2 : 1)
            }
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private func fillColor(isPressed: Bool) -> Color {
        if selected { return tint.opacity(isPressed ? 0.25 : isHovering ? 0.19 : 0.13) }
        if isPressed { return Color.primary.opacity(0.14) }
        if isHovering { return Color.primary.opacity(0.07) }
        return .clear
    }

    private func borderColor(isPressed: Bool) -> Color {
        if selected { return tint.opacity(isPressed ? 0.9 : 0.66) }
        return isHovering ? Color.primary.opacity(0.16) : .clear
    }
}

private struct ProgressStudioRow: View {
    let selected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.cyan)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Progress")
                        .fontWeight(.semibold)
                    Text("Tell me when it’s done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(selected ? Color.cyan : Color.secondary.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioRowButtonStyle(tint: .cyan, selected: selected, isHovering: isHovering))
        .onHover { isHovering = $0 }
        .accessibilityLabel("Progress")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

struct StateStyleRow: View {
    let style: StateLightStyle
    let selected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Circle()
                    .fill(Color(hex: style.colorHex))
                    .shadow(color: Color(hex: style.colorHex), radius: 5)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.state.title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text("\(style.motion.title) · \(style.colorMode.title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(selected ? Color(hex: style.colorHex) : Color.secondary.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            StudioRowButtonStyle(
                tint: Color(hex: style.colorHex),
                selected: selected,
                isHovering: isHovering
            )
        )
        .onHover { isHovering = $0 }
        .accessibilityValue(selected ? "Selected" : "Not selected")
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
    @State private var showsAllSignalHistory = false

    private var visibleSignalHistory: ArraySlice<AgentSignalHistoryEntry> {
        store.agentSignalHistory.prefix(
            showsAllSignalHistory
                ? store.agentSignalHistory.count
                : AgentSignalHistoryLedger.defaultVisibleCount
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent Hub").font(.largeTitle.bold())
                    Text("Active sessions stay above; recent signals remain below so you can retrace what changed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RuntimePill(text: store.runtimeMessage)
            }
            if store.agents.isEmpty {
                Label("No agent is active right now. Codex sessions appear here automatically.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                HStack(spacing: 8) {
                    Text("\(store.agents.count) SESSION\(store.agents.count == 1 ? "" : "S")")
                    Text("·")
                    Text(store.agentDisplayMode == .simple ? "ONE PRIORITIZED LIGHT SIGNAL" : "PER-AGENT LIGHTING")
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.agents) { agent in
                        Button {
                            store.openAgent(agent)
                        } label: {
                            AgentTimelineRow(
                                agent: agent,
                                profile: store.selectedProfile,
                                allocationLabel: allocationLabel(for: agent)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Open \(agent.name)")
                    }

                    signalHistorySection
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var signalHistorySection: some View {
        Divider()
            .padding(.top, 10)
            .padding(.bottom, 4)

        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Agent History")
                    .font(.headline)
                Text("Recent state and tool changes behind SidePulse signals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(store.agentSignalHistory.count) / \(AgentSignalHistoryLedger.capacity)")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 2)

        if store.agentSignalHistory.isEmpty {
            Label("History starts with the next detected agent activity.", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            ForEach(visibleSignalHistory) { entry in
                let agent = entry.agentSnapshot
                if AgentOpenRouting.destination(for: agent) != nil {
                    Button {
                        store.openHistoricalAgent(agent)
                    } label: {
                        AgentSignalHistoryRow(
                            entry: entry,
                            profile: store.selectedProfile,
                            isOpenable: true
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Open \(entry.name) · \(entry.occurredAt.formatted(date: .abbreviated, time: .standard))")
                } else {
                    AgentSignalHistoryRow(
                        entry: entry,
                        profile: store.selectedProfile,
                        isOpenable: false
                    )
                    .help("No direct open route is available for \(entry.provider.title)")
                }
            }

            if store.agentSignalHistory.count > AgentSignalHistoryLedger.defaultVisibleCount {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showsAllSignalHistory.toggle()
                    }
                } label: {
                    Label(
                        showsAllSignalHistory
                            ? "Show latest \(AgentSignalHistoryLedger.defaultVisibleCount)"
                            : "Show \(store.agentSignalHistory.count - AgentSignalHistoryLedger.defaultVisibleCount) older actions",
                        systemImage: showsAllSignalHistory ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func allocationLabel(for agent: AgentSession) -> String {
        guard store.agentDisplayMode == .perAgent else { return "IN HUB" }
        return store.scene.placementsTopToBottom
            .first(where: { $0.agent.id == agent.id })?
            .rangeLabel
            ?? "NOT LIT"
    }
}

private struct AgentSignalHistoryRow: View {
    let entry: AgentSignalHistoryEntry
    let profile: LightingProfile
    let isOpenable: Bool

    private var color: Color { Color(hex: profile.style(for: entry.state).colorHex) }
    private var actionLabel: String {
        if let toolName = entry.toolName, !toolName.isEmpty {
            return "\(entry.eventName) · \(toolName)"
        }
        return entry.eventName
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: entry.state.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 27, height: 27)
                .background(color.opacity(0.12), in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(entry.state.title.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                }
                HStack(spacing: 5) {
                    Text(entry.provider.title)
                    Text("·")
                    Text(entry.project)
                    Text("·")
                    Text(actionLabel)
                        .fontDesign(.monospaced)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(entry.occurredAt, style: .relative)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            Image(systemName: isOpenable ? "arrow.up.right" : "minus")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 40)
        .contentShape(.rect)
        .glassEffect(
            .regular.tint(color.opacity(isOpenable ? 0.055 : 0.025)).interactive(isOpenable),
            in: .rect(cornerRadius: 13)
        )
    }
}

private struct AgentTimelineRow: View {
    let agent: AgentSession
    let profile: LightingProfile
    let allocationLabel: String

    private var color: Color { Color(hex: profile.style(for: agent.state).colorHex) }

    var body: some View {
        HStack(spacing: 15) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(allocationLabel)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(color)
                Text(agent.provider.title.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 72, alignment: .trailing)

            Image(systemName: agent.state.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.13), in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(agent.project)
                    Text("·")
                    Text(agent.state.title)
                    Text("·")
                    Text(agent.updatedAt, style: .relative)
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(agent.state.title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(color.opacity(0.1), in: .capsule)

            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
        .contentShape(.rect)
        .glassEffect(.regular.tint(color.opacity(0.07)).interactive(), in: .rect(cornerRadius: 15))
    }
}

struct HardwareView: View {
    @Bindable var store: CommandCenterStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Devices & Macs").font(.largeTitle.bold())
                        Text("Choose which Mac drives each SidePulse. Every device works as its own output.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Live output", isOn: Binding(
                        get: { store.outputPowerIsOn },
                        set: { store.setOutputPower($0) }
                    ))
                    .toggleStyle(.switch)
                }

                NearbySignalNetworkCard(store: store)

                HStack(alignment: .firstTextBaseline) {
                    Text("Local Outputs")
                        .font(.title2.bold())
                    Spacer()
                    Text("Source → SidePulse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(store.hardwareDevices, id: \.kind) { device in
                    HardwareDeviceCard(store: store, device: device)
                }

                EjectPreventionRow(store: store)

                Label("Power and max brightness apply to every connected output on this Mac.", systemImage: "dial.high")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Developer details") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Local compiled LED scene")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(store.scene.program)
                            .textSelection(.enabled)
                            .font(.caption.monospaced())
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.45), in: .rect(cornerRadius: 10))
                    }
                    .padding(.top, 8)
                }
                .font(.caption)
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
    }
}

struct EjectPreventionRow: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(store.ejectPreventionIsOn ? .green : .secondary)
                .frame(width: 38, height: 38)
                .background(
                    (store.ejectPreventionIsOn ? Color.green : Color.secondary).opacity(0.1),
                    in: .rect(cornerRadius: 12)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Keep SidePulse Pro mounted")
                    .font(.headline)
                Text(store.ejectPreventionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle(
                "Prevent SidePulse Pro ejection",
                isOn: Binding(
                    get: { store.ejectPreventionIsOn },
                    set: { store.setEjectPreventionEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!store.ejectPreventionCanBeChanged)
            .help(
                store.ejectPreventionManagedExternally
                    ? "Managed by the existing SidePulse eject helper"
                    : "Prevent macOS from ejecting SidePulse Pro after lock or hibernate"
            )
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct HardwareDeviceCard: View {
    @Bindable var store: CommandCenterStore
    let device: DeviceState
    @State private var showsCalibration = false

    private var kind: SidePulseDeviceKind { device.kind }
    private var calibration: SidePulseOutputCalibration {
        store.outputCalibration(for: kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: device.connected ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill")
                    .font(.title2)
                    .foregroundStyle(device.connected ? .green : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 9) {
                        Text(device.name).font(.headline)
                        Text("\(device.ledCount)-LED OUTPUT")
                            .font(.caption2.bold())
                            .foregroundStyle(device.connected ? .primary : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.white.opacity(device.connected ? 0.12 : 0.06), in: .capsule)
                    }
                    Text(device.connected ? "Connected · standalone" : "Ready for standalone use")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(device.connected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(device.connected ? "Connected" : "Not connected")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("SIGNAL SOURCE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(selectedSourceName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)

                VStack(alignment: .leading, spacing: 3) {
                    Text("OUTPUT")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(device.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Signal Source", selection: Binding(
                    get: { store.signalSource(for: kind) },
                    set: { store.selectSignalSource($0, for: kind) }
                )) {
                    Text("This Mac").tag(SidePulseSignalSource.thisMac)
                    Text("All Macs").tag(SidePulseSignalSource.allMacs)
                    if case .nearbyMac(let selectedPeerID) = store.signalSource(for: kind),
                       !store.nearbyPeers.contains(where: { $0.id == selectedPeerID }) {
                        Text("Unavailable Mac")
                            .tag(SidePulseSignalSource.nearbyMac(selectedPeerID))
                    }
                    ForEach(store.nearbyPeers) { peer in
                        Text(peer.displayName).tag(SidePulseSignalSource.nearbyMac(peer.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 154)
            }
            .padding(11)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 11))

            HStack(spacing: 8) {
                Label(routeStatusTitle, systemImage: routeStatusSymbol)
                if !store.nearbyDiscoveryEnabled,
                   store.signalSource(for: kind).needsNearbySignals {
                    Text("· discovery required")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(kind == .pro
                ? "Eight-LED SidePulse Pro output for local, nearby, or combined activity."
                : "Two-LED SidePulse Dot output. It works independently; a Pro is not required.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let error = device.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let lastWrite = device.lastWrite {
                Label("Last write \(lastWrite.formatted(date: .omitted, time: .standard))", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Divider()

            DisclosureGroup("Output calibration & details", isExpanded: $showsCalibration) {
                VStack(alignment: .leading, spacing: 12) {
                    calibrationSlider(
                        title: "Device brightness",
                        value: calibration.brightnessScale,
                        range: 0.1...1.5
                    ) { value in
                        store.updateOutputCalibration(for: kind) { $0.brightnessScale = value }
                    }
                    calibrationSlider(
                        title: "Blue balance",
                        value: calibration.blueScale,
                        range: 0.5...1.25
                    ) { value in
                        store.updateOutputCalibration(for: kind) { $0.blueScale = value }
                    }
                    HStack {
                        Text("Automatic default: \(Int(kind.defaultOutputCalibration.brightnessScale * 100))% brightness · \(Int(kind.defaultOutputCalibration.blueScale * 100))% blue")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Reset") {
                            store.resetOutputCalibration(for: kind)
                        }
                        .buttonStyle(.borderless)
                        .disabled(calibration == kind.defaultOutputCalibration)
                    }
                    if device.connected {
                        Divider()
                        LabeledContent("Mount", value: device.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var selectedSourceName: String {
        switch store.signalSource(for: kind) {
        case .thisMac:
            return store.localMacDisplayName
        case .allMacs:
            return "Best signal from all Macs"
        case .nearbyMac(let peerID):
            return store.nearbyPeers.first(where: { $0.id == peerID })?.displayName ?? "Unavailable Mac"
        }
    }

    private var routeStatusTitle: String {
        guard device.connected else { return "Route saved · connect this SidePulse to use it" }
        return store.signalSourceStatus(for: kind)
    }

    private var routeStatusSymbol: String {
        guard device.connected else { return "externaldrive" }
        if store.routedSignalSourceName(for: kind) == "No active signal" { return "pause.circle" }
        return "point.3.connected.trianglepath.dotted"
    }

    @ViewBuilder
    private func calibrationSlider(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(width: 110, alignment: .leading)
            Slider(
                value: Binding(get: { value }, set: onChange),
                in: range
            )
            Text("\(Int((value * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

struct BatteryView: View {
    @Bindable var store: CommandCenterStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Battery").font(.largeTitle.bold())
                    Text("Choose when SidePulse briefly shows your Mac's current charge.")
                        .foregroundStyle(.secondary)
                }
                BatterySettingsCard(store: store)
                Spacer()
            }
        }
        .scrollIndicators(.hidden)
    }
}

struct ConnectionsView: View {
    @Bindable var store: CommandCenterStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agent Integrations").font(.largeTitle.bold())
                        Text("Agent integrations that provide live SidePulse status.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
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
                    .disabled(!store.hardwareDevices.contains(where: \.connected))
                    Spacer()
                }
                Text(store.batterySettings.mode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                    GridRow {
                        Toggle("When lid is opened", isOn: settingBinding(\.showsWhenLidOpens))
                        Toggle("When lid is closed", isOn: settingBinding(\.showsWhenLidCloses))
                    }
                    GridRow {
                        Toggle(
                            "When charger connects or disconnects",
                            isOn: settingBinding(\.showsWhenPowerSourceChanges)
                        )
                        .gridCellColumns(2)
                    }
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
