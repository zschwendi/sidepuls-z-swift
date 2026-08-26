import AppKit
import Foundation
import Observation
import ServiceManagement
import UniformTypeIdentifiers

enum CommandCenterSection: String, CaseIterable, Identifiable {
    case overview, lighting, profiles, agents, hardware, system, diagnostics

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Command Center"
        case .lighting: "Lighting Studio"
        case .profiles: "Profiles"
        case .agents: "Agents"
        case .hardware: "Hardware"
        case .system: "Connections"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "sparkles.rectangle.stack.fill"
        case .lighting: "lightbulb.led.wide.fill"
        case .profiles: "square.stack.3d.up.fill"
        case .agents: "cpu.fill"
        case .hardware: "externaldrive.fill"
        case .system: "switch.2"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

@MainActor
@Observable
final class CommandCenterStore {
    var selectedSection: CommandCenterSection = .overview
    var profiles: [LightingProfile] = [.factoryDefault]
    var selectedProfileID = LightingProfile.factoryDefault.id
    var selectedState: AgentState = .working
    var selectedAgentID: String?
    var agents: [AgentSession]
    var integrations: [AgentIntegrationStatus] = AgentProvider.allCases
        .filter { $0 != .unknown }
        .map {
            AgentIntegrationStatus(
                provider: $0,
                state: $0 == .codex ? .ready : .needsSetup,
                detail: $0 == .codex ? "Watching local sessions automatically" : "Checking integration",
                activeSessionCount: 0,
                lastEventAt: nil
            )
        }
    var proDevice = SidePulseDeviceKind.pro.disconnectedState
    var dotDevice = SidePulseDeviceKind.dot.disconnectedState
    var device: DeviceState {
        if proDevice.connected { return proDevice }
        if dotDevice.connected { return dotDevice }
        return proDevice
    }
    var hardwareDevices: [DeviceState] { [proDevice, dotDevice] }
    var batteryState: BatteryState?
    var batterySettings = AppPreferences.batteryIndicatorSettings()
    var agentDisplayMode = AppPreferences.agentDisplayMode()
    var menuBarIconStyle = AppPreferences.menuBarIconStyle()
    var universalBrightness = AppPreferences.universalBrightness()
    var launchAtLoginEnabled = false
    var launchAtLoginMessage: String?
    var lidIsClosed: Bool?
    var lastLidTransitionAt: Date?
    var scene = CompiledScene(program: "", slots: [])
    var profileTransferMessage: String?
    var profileTransferFailed = false
    var focusAutomationEnabled = ProfileLibrary.focusAutomationEnabled()
    var activeFocusProfileID: UUID?
    var liveOutputEnabled = AppPreferences.liveOutputEnabled() {
        didSet {
            AppPreferences.saveLiveOutputEnabled(liveOutputEnabled)
            syncHardwareOutput()
        }
    }
    var runtimeMessage = "Preview data — native event runtime not connected yet"

    private var proAllocator = StableSlotAllocator()
    private var dotAllocator = StableSlotAllocator()
    private let compiler = LightingSceneCompiler()
    @ObservationIgnored private var proScene = CompiledScene(program: "off", slots: [])
    @ObservationIgnored private var dotScene = CompiledScene(program: "off", slots: [])
    @ObservationIgnored private var runtime: NativeAgentRuntime?
    @ObservationIgnored private var proHardware: SidePulseHardwareController?
    @ObservationIgnored private var dotHardware: SidePulseHardwareController?
    @ObservationIgnored private var lidMonitor: LidStateMonitor?
    @ObservationIgnored private var batteryMonitor: BatteryStateMonitor?
    @ObservationIgnored private var lastLowBatteryAlertAt: Date?
    @ObservationIgnored private var isShowingPreviewData = true
    @ObservationIgnored private var lastOutputStates: [String: AgentState] = [:]
    @ObservationIgnored private var profileSelectionObserver: NSObjectProtocol?
    @ObservationIgnored private var focusMonitor: Timer?
    @ObservationIgnored private var hasObservedFocusContext = false
    @ObservationIgnored private var lastObservedFocusProfileID: UUID?

    init() {
        if let saved = ProfileLibrary.load(), !saved.profiles.isEmpty {
            profiles = saved.profiles
            selectedProfileID = saved.profiles.contains(where: { $0.id == saved.selectedProfileID })
                ? saved.selectedProfileID
                : saved.profiles[0].id
        } else {
            let initialProfile = LightingProfile.factoryDefault
            ProfileLibrary.save(profiles: [initialProfile], selectedProfileID: initialProfile.id)
            ProfileLibrary.setDefaultProfileID(initialProfile.id)
        }

        let now = Date.now
        agents = [
            AgentSession(
                id: "codex:sidepulse-command-center",
                provider: .codex,
                sessionID: "01a03523",
                name: "Build the SidePulse command center",
                project: "sidepuls-z-swift",
                cwd: "/Users/zach/Developer/Xcode Projects/sidepuls-z-swift",
                state: .toolRunning,
                eventName: "PreToolUse",
                toolName: "Xcode Build",
                updatedAt: now,
                message: nil
            ),
            AgentSession(
                id: "claude:design-review",
                provider: .claude,
                sessionID: "design-review",
                name: "Review profile behavior",
                project: "SidePulse",
                cwd: nil,
                state: .waiting,
                eventName: "PermissionRequest",
                toolName: nil,
                updatedAt: now.addingTimeInterval(-18),
                message: "Needs input"
            ),
            AgentSession(
                id: "grok:firmware-fixture",
                provider: .grok,
                sessionID: "firmware-fixture",
                name: "Validate LED firmware scenes",
                project: "SidePulse",
                cwd: nil,
                state: .completed,
                eventName: "Stop",
                toolName: nil,
                updatedAt: now.addingTimeInterval(-6),
                message: nil
            ),
        ]
        recompile()
        refreshLaunchAtLoginStatus()
        startNativeRuntime()
        startProfileAutomation()
    }

    var selectedProfile: LightingProfile {
        profiles.first(where: { $0.id == selectedProfileID }) ?? .factoryDefault
    }

    var liveProgram: String {
        if device.connected { return device.activeProgram }
        return LEDProgramOutputCalibration.scalingBrightness(
            in: scene.program,
            by: universalBrightness
        )
    }

    var aggregateState: AgentState {
        AgentDisplayPolicy.aggregateState(for: agents, mode: agentDisplayMode)
    }

    var lightingAgents: [AgentSession] {
        AgentDisplayPolicy.lightingSessions(from: agents, mode: agentDisplayMode)
    }

    func selectProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        resetAllocators()
        recompile()
        persistProfiles()
    }

    func selectAgentDisplayMode(_ mode: AgentDisplayMode) {
        guard agentDisplayMode != mode else { return }
        agentDisplayMode = mode
        if mode == .simple, selectedState == .toolRunning {
            selectedState = .working
        }
        AppPreferences.saveAgentDisplayMode(mode)
        resetAllocators()
        recompile()
    }

    func selectMenuBarIconStyle(_ style: MenuBarIconStyle) {
        guard menuBarIconStyle != style else { return }
        menuBarIconStyle = style
        AppPreferences.saveMenuBarIconStyle(style)
    }

    func setUniversalBrightness(_ brightness: Double) {
        let clamped = max(0, min(1, brightness))
        guard abs(universalBrightness - clamped) > 0.000_1 else { return }
        universalBrightness = clamped
        AppPreferences.saveUniversalBrightness(clamped)
        syncHardwareOutput()
    }

    var launchAtLoginNeedsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    func refreshLaunchAtLoginStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginMessage = nil
        case .requiresApproval:
            launchAtLoginEnabled = true
            launchAtLoginMessage = "Allow SidePulse in System Settings → General → Login Items."
        case .notRegistered:
            launchAtLoginEnabled = false
            launchAtLoginMessage = nil
        case .notFound:
            launchAtLoginEnabled = false
            launchAtLoginMessage = nil
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginMessage = "Startup status is unavailable."
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginMessage = "Couldn’t update startup: \(error.localizedDescription)"
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func updateSelectedProfile(_ update: (inout LightingProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        let previousStrategy = profiles[index].strategy
        update(&profiles[index])
        if profiles[index].strategy != previousStrategy { resetAllocators() }
        recompile()
        persistProfiles()
    }

    func updateStyle(_ style: StateLightStyle) {
        updateSelectedProfile { $0.updateStyle(style) }
    }

    func duplicateSelectedProfile() {
        var copy = selectedProfile
        copy.id = UUID()
        copy.name = uniqueProfileName(base: "\(selectedProfile.name) Copy")
        profiles.append(copy)
        selectProfile(copy.id)
        ProfileFocusIntegration.profileLibraryDidChange()
    }

    func createProfile() {
        var profile = selectedProfile
        profile.id = UUID()
        profile.name = uniqueProfileName(base: "New Profile")
        profiles.append(profile)
        selectProfile(profile.id)
        ProfileFocusIntegration.profileLibraryDidChange()
    }

    func renameSelectedProfile(_ name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        profiles[index].name = name
        persistProfiles()
        ProfileFocusIntegration.profileLibraryDidChange()
    }

    func deleteSelectedProfile() {
        guard profiles.count > 1,
              selectedProfileID != defaultProfileID,
              let index = profiles.firstIndex(where: { $0.id == selectedProfileID })
        else { return }
        profiles.remove(at: index)
        selectedProfileID = defaultProfileID ?? profiles[0].id
        resetAllocators()
        recompile()
        persistProfiles()
        ProfileFocusIntegration.profileLibraryDidChange()
    }

    func exportProfiles() {
        let panel = NSSavePanel()
        panel.title = "Export SidePulse Profiles"
        panel.nameFieldStringValue = "SidePulse Profiles.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try ProfileLibrary.exportData(profiles: profiles)
            try data.write(to: url, options: .atomic)
            profileTransferFailed = false
            profileTransferMessage = "Exported \(profiles.count) profile\(profiles.count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            profileTransferFailed = true
            profileTransferMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func importProfiles() {
        let panel = NSOpenPanel()
        panel.title = "Import SidePulse Profiles"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let imported = try ProfileLibrary.importProfiles(from: Data(contentsOf: url))
            for profile in imported {
                if let existing = profiles.firstIndex(where: { $0.id == profile.id }) {
                    profiles[existing] = profile
                } else {
                    profiles.append(profile)
                }
            }
            selectedProfileID = imported[0].id
            resetAllocators()
            recompile()
            persistProfiles()
            ProfileFocusIntegration.profileLibraryDidChange()
            profileTransferFailed = false
            profileTransferMessage = "Imported \(imported.count) profile\(imported.count == 1 ? "" : "s") from \(url.lastPathComponent)."
        } catch {
            profileTransferFailed = true
            profileTransferMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func openFocusSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func selectAgent(_ agent: AgentSession) {
        selectedAgentID = agent.id
        selectedSection = .agents
        if agent.state == .completed {
            runtime?.acknowledgeCompleted(sessionID: agent.id)
        }
        guard let destination = agent.openURL else { return }
        NSWorkspace.shared.open(destination)
    }

    func openCodex() {
        if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }
        } else if let destination = URL(string: "codex://") {
            NSWorkspace.shared.open(destination)
        }
    }

    func recompile() {
        let displayedAgents = lightingAgents
        proScene = compiler.compile(
            profile: selectedProfile,
            agents: displayedAgents,
            allocator: &proAllocator,
            ledCount: SidePulseDeviceKind.pro.ledCount
        )
        dotScene = compiler.compile(
            profile: selectedProfile,
            agents: displayedAgents,
            allocator: &dotAllocator,
            ledCount: SidePulseDeviceKind.dot.ledCount
        )
        scene = proDevice.connected || !dotDevice.connected ? proScene : dotScene
        syncHardwareOutput()
    }

    func previewSelectedState() {
        let previewAgent = AgentSession(
            id: "sidepulse:preview",
            provider: .unknown,
            sessionID: "preview",
            name: selectedState.title,
            project: "SidePulse",
            cwd: nil,
            state: selectedState,
            eventName: "Preview",
            toolName: nil,
            updatedAt: .now,
            message: nil
        )
        var proPreviewAllocator = StableSlotAllocator()
        let proPreview = compiler.compile(
            profile: selectedProfile,
            agents: [previewAgent],
            allocator: &proPreviewAllocator,
            ledCount: SidePulseDeviceKind.pro.ledCount
        )
        var dotPreviewAllocator = StableSlotAllocator()
        let dotPreview = compiler.compile(
            profile: selectedProfile,
            agents: [previewAgent],
            allocator: &dotPreviewAllocator,
            ledCount: SidePulseDeviceKind.dot.ledCount
        )
        proHardware?.preview(
            program: proPreview.program,
            brightnessScale: universalBrightness
        )
        dotHardware?.preview(
            program: dotPreview.program,
            brightnessScale: universalBrightness
        )
    }

    func updateBatterySettings(_ update: (inout BatteryIndicatorSettings) -> Void) {
        var next = batterySettings
        update(&next)
        next = next.normalized
        guard next != batterySettings else { return }
        batterySettings = next
        lastLowBatteryAlertAt = nil
        AppPreferences.saveBatteryIndicatorSettings(next)
    }

    func selectBatteryIndicatorMode(_ mode: BatteryIndicatorMode) {
        updateBatterySettings { $0.mode = mode }
        if batterySettings.showsChargeInfo { previewBatteryIndicator() }
    }

    func previewBatteryIndicator() {
        guard batterySettings.showsChargeInfo else { return }
        let chargeFraction = batteryState?.chargeFraction ?? 1
        let proTransition = batteryIndicatorScene(
            chargeFraction: chargeFraction,
            ledCount: SidePulseDeviceKind.pro.ledCount
        )
        let dotTransition = batteryIndicatorScene(
            chargeFraction: chargeFraction,
            ledCount: SidePulseDeviceKind.dot.ledCount
        )
        proHardware?.preview(
            program: proTransition.program,
            brightnessScale: universalBrightness,
            duration: proTransition.duration
        )
        dotHardware?.preview(
            program: dotTransition.program,
            brightnessScale: universalBrightness,
            duration: dotTransition.duration
        )
    }

    private func persistProfiles() {
        ProfileLibrary.save(
            profiles: profiles,
            selectedProfileID: selectedProfileID
        )
    }

    var defaultProfileID: UUID? {
        let stored = ProfileLibrary.defaultProfileID()
        return stored.flatMap { id in profiles.contains(where: { $0.id == id }) ? id : nil }
            ?? profiles.first?.id
    }

    private func uniqueProfileName(base: String) -> String {
        guard profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(base) == .orderedSame }) else {
            return base
        }
        var suffix = 2
        while profiles.contains(where: {
            $0.name.localizedCaseInsensitiveCompare("\(base) \(suffix)") == .orderedSame
        }) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private func startProfileAutomation() {
        profileSelectionObserver = DistributedNotificationCenter.default().addObserver(
            forName: .sidePulseProfileSelectionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reloadProfileSelection()
            }
        }
        focusMonitor = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncFocusProfile()
            }
        }
        Task { @MainActor [weak self] in
            await self?.syncFocusProfile()
        }
    }

    private func reloadProfileSelection() {
        focusAutomationEnabled = ProfileLibrary.focusAutomationEnabled()
        guard let saved = ProfileLibrary.load(), !saved.profiles.isEmpty else { return }
        profiles = saved.profiles
        let targetID = saved.profiles.contains(where: { $0.id == saved.selectedProfileID })
            ? saved.selectedProfileID
            : saved.profiles[0].id
        guard selectedProfileID != targetID else { return }
        selectedProfileID = targetID
        resetAllocators()
        recompile()
    }

    private func syncFocusProfile() async {
        focusAutomationEnabled = ProfileLibrary.focusAutomationEnabled()
        guard focusAutomationEnabled else { return }
        let currentID = await ProfileFocusIntegration.currentProfileID()
        activeFocusProfileID = currentID

        let contextChanged = !hasObservedFocusContext || currentID != lastObservedFocusProfileID
        hasObservedFocusContext = true
        lastObservedFocusProfileID = currentID
        guard contextChanged else { return }

        let targetID = currentID ?? defaultProfileID
        guard let targetID,
              profiles.contains(where: { $0.id == targetID }),
              selectedProfileID != targetID
        else { return }
        selectedProfileID = targetID
        resetAllocators()
        recompile()
        persistProfiles()
    }

    private func startNativeRuntime() {
        let proHardware = SidePulseHardwareController(kind: .pro) { [weak self] device in
            Task { @MainActor [weak self] in
                self?.handleDeviceUpdate(device, kind: .pro)
            }
        }
        let dotHardware = SidePulseHardwareController(kind: .dot) { [weak self] device in
            Task { @MainActor [weak self] in
                self?.handleDeviceUpdate(device, kind: .dot)
            }
        }
        self.proHardware = proHardware
        self.dotHardware = dotHardware
        proHardware.start()
        dotHardware.start()

        let batteryMonitor = BatteryStateMonitor { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleBatteryUpdate(state)
            }
        }
        self.batteryMonitor = batteryMonitor
        batteryMonitor.start()

        let lidMonitor = LidStateMonitor { [weak self] isClosed, isTransition in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lidIsClosed = isClosed
                guard isTransition,
                      self.batterySettings.showsChargeInfo,
                      (isClosed
                        ? self.batterySettings.showsWhenLidCloses
                        : self.batterySettings.showsWhenLidOpens)
                else { return }
                self.lastLidTransitionAt = .now
                self.previewBatteryIndicator()
            }
        }
        self.lidMonitor = lidMonitor
        lidMonitor.start()

        let runtime = NativeAgentRuntime { [weak self] agents, message, integrations in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isShowingPreviewData {
                    self.resetAllocators()
                    self.isShowingPreviewData = false
                }
                self.agents = agents
                self.integrations = integrations
                self.runtimeMessage = message
                self.recompile()
            }
        }
        self.runtime = runtime
        runtime.start()
    }

    private func handleDeviceUpdate(_ device: DeviceState, kind: SidePulseDeviceKind) {
        let previous = kind == .pro ? proDevice : dotDevice
        let topologyChanged = previous.connected != device.connected || previous.path != device.path
        if kind == .pro {
            proDevice = device
        } else {
            dotDevice = device
        }
        if topologyChanged { recompile() }
    }

    private func handleBatteryUpdate(_ state: BatteryState?) {
        if batteryState != state { batteryState = state }
        let threshold = Double(batterySettings.lowBatteryThresholdPercent) / 100
        guard batterySettings.showsChargeInfo,
              batterySettings.lowBatteryReminderEnabled,
              let state,
              state.chargeFraction <= threshold,
              !state.isCharging,
              !state.isExternallyPowered
        else {
            lastLowBatteryAlertAt = nil
            return
        }

        let now = Date.now
        let interval = TimeInterval(batterySettings.lowBatteryReminderIntervalSeconds)
        guard lastLowBatteryAlertAt.map({ now.timeIntervalSince($0) >= interval }) ?? true else { return }
        lastLowBatteryAlertAt = now
        previewBatteryIndicator()
    }

    private func batteryIndicatorScene(
        chargeFraction: Double,
        ledCount: Int
    ) -> TimedLightingScene {
        SystemLightingScenes.batteryGauge(
            chargeFraction: chargeFraction,
            ledCount: ledCount,
            mode: batterySettings.mode,
            lowBatteryThresholdPercent: batterySettings.lowBatteryThresholdPercent
        )
    }

    private func syncHardwareOutput() {
        let currentStates = Dictionary(uniqueKeysWithValues: proScene.placementsTopToBottom.map {
            ($0.agent.id, $0.agent.state)
        })
        let timing = hardwareTiming(from: lastOutputStates, to: currentStates)
        proHardware?.update(
            enabled: liveOutputEnabled,
            program: proScene.program,
            brightnessScale: universalBrightness,
            timing: timing
        )
        dotHardware?.update(
            enabled: liveOutputEnabled,
            program: dotScene.program,
            brightnessScale: universalBrightness,
            timing: dotHardwareTiming(from: timing)
        )
        lastOutputStates = currentStates
    }

    private func dotHardwareTiming(from timing: HardwareUpdateTiming) -> HardwareUpdateTiming {
        guard case .animationBoundary = timing,
              dotScene.placementsTopToBottom.count == 1,
              let placement = dotScene.placementsTopToBottom.first,
              placement.ledIndices.count == SidePulseDeviceKind.dot.ledCount,
              selectedProfile.style(for: placement.agent.state).motion == .breathe
        else { return timing }
        return .animationBoundary(cycleSeconds: LightingSceneCompiler.dotDirectionalBreatheCycleSeconds)
    }

    private func resetAllocators() {
        proAllocator.reset()
        dotAllocator.reset()
    }

    private func hardwareTiming(
        from previous: [String: AgentState],
        to current: [String: AgentState]
    ) -> HardwareUpdateTiming {
        guard liveOutputEnabled,
              AgentStateTransitionPolicy.defersToAnimationBoundary(from: previous, to: current)
        else { return .immediate }

        let thinkingStyle = selectedProfile.style(for: .working)
        guard thinkingStyle.motion.isAnimated else { return .immediate }
        return .animationBoundary(cycleSeconds: thinkingStyle.cycleSeconds)
    }
}
