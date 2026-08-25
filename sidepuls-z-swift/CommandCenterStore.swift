import AppKit
import Foundation
import Observation
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
    var profiles: [LightingProfile] = [.commandCenter]
    var selectedProfileID = LightingProfile.commandCenter.id
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
    var device = DeviceState()
    var batteryState: BatteryState?
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

    private var allocator = StableSlotAllocator()
    private let compiler = LightingSceneCompiler()
    @ObservationIgnored private var runtime: NativeAgentRuntime?
    @ObservationIgnored private var hardware: SidePulseHardwareController?
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
            let initialProfile = LightingProfile.commandCenter
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
        startNativeRuntime()
        startProfileAutomation()
    }

    var selectedProfile: LightingProfile {
        profiles.first(where: { $0.id == selectedProfileID }) ?? .commandCenter
    }

    var aggregateState: AgentState {
        agents.min(by: { $0.state.priority < $1.state.priority })?.state ?? .idle
    }

    func selectProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        allocator.reset()
        recompile()
        persistProfiles()
    }

    func updateSelectedProfile(_ update: (inout LightingProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        let previousStrategy = profiles[index].strategy
        update(&profiles[index])
        if profiles[index].strategy != previousStrategy { allocator.reset() }
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
        allocator.reset()
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
            allocator.reset()
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
        scene = compiler.compile(
            profile: selectedProfile,
            agents: agents,
            allocator: &allocator,
            ledCount: device.ledCount
        )
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
        var previewAllocator = StableSlotAllocator()
        let preview = compiler.compile(
            profile: selectedProfile,
            agents: [previewAgent],
            allocator: &previewAllocator,
            ledCount: device.ledCount
        )
        hardware?.preview(program: preview.program)
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
        allocator.reset()
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
        allocator.reset()
        recompile()
        persistProfiles()
    }

    private func startNativeRuntime() {
        let hardware = SidePulseHardwareController { [weak self] device in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ledCountChanged = self.device.ledCount != device.ledCount
                self.device = device
                if ledCountChanged { self.recompile() }
            }
        }
        self.hardware = hardware
        hardware.start()

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
                guard isTransition else { return }
                self.lastLidTransitionAt = .now
                let transition = SystemLightingScenes.batteryGauge(
                    chargeFraction: self.batteryState?.chargeFraction ?? 1,
                    ledCount: self.device.ledCount
                )
                self.hardware?.preview(
                    program: transition.program,
                    duration: transition.duration
                )
            }
        }
        self.lidMonitor = lidMonitor
        lidMonitor.start()

        let runtime = NativeAgentRuntime { [weak self] agents, message, integrations in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isShowingPreviewData {
                    self.allocator.reset()
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

    private func handleBatteryUpdate(_ state: BatteryState?) {
        if batteryState != state { batteryState = state }
        guard let state, state.isLowAndDischarging else {
            lastLowBatteryAlertAt = nil
            return
        }

        let now = Date.now
        guard lastLowBatteryAlertAt.map({ now.timeIntervalSince($0) >= 15 }) ?? true else { return }
        lastLowBatteryAlertAt = now
        let alert = SystemLightingScenes.lowBatteryAlert(ledCount: device.ledCount)
        hardware?.preview(program: alert.program, duration: alert.duration)
    }

    private func syncHardwareOutput() {
        guard let hardware else { return }
        let currentStates = Dictionary(uniqueKeysWithValues: scene.placementsTopToBottom.map {
            ($0.agent.id, $0.agent.state)
        })
        let timing = hardwareTiming(from: lastOutputStates, to: currentStates)
        hardware.update(enabled: liveOutputEnabled, program: scene.program, timing: timing)
        lastOutputStates = currentStates
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
