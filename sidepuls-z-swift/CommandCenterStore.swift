import AppKit
import Foundation
import Observation

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
    var profiles: [LightingProfile] = [.commandCenter, .quietNight, .highSignal]
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
    var lidIsClosed: Bool?
    var lastLidTransitionAt: Date?
    var scene = CompiledScene(program: "", slots: [])
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
    @ObservationIgnored private var codexActivationObserver: NSObjectProtocol?
    @ObservationIgnored private var isShowingPreviewData = true

    init() {
        if let saved = ProfileLibrary.load(), !saved.profiles.isEmpty {
            profiles = saved.profiles
            selectedProfileID = saved.profiles.contains(where: { $0.id == saved.selectedProfileID })
                ? saved.selectedProfileID
                : saved.profiles[0].id
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
    }

    var selectedProfile: LightingProfile {
        profiles.first(where: { $0.id == selectedProfileID }) ?? .commandCenter
    }

    var aggregateState: AgentState {
        agents.min(by: { $0.state.priority < $1.state.priority })?.state ?? .idle
    }

    func selectProfile(_ id: UUID) {
        selectedProfileID = id
        allocator.reset()
        recompile()
        persistProfiles()
        runtime?.updatePolicy(runtimePolicy)
    }

    func updateSelectedProfile(_ update: (inout LightingProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        let previousStrategy = profiles[index].strategy
        update(&profiles[index])
        if profiles[index].strategy != previousStrategy { allocator.reset() }
        recompile()
        persistProfiles()
        runtime?.updatePolicy(runtimePolicy)
    }

    func updateStyle(_ style: StateLightStyle) {
        updateSelectedProfile { $0.updateStyle(style) }
    }

    func duplicateSelectedProfile() {
        var copy = selectedProfile
        copy.id = UUID()
        copy.name += " Copy"
        profiles.append(copy)
        selectProfile(copy.id)
    }

    func createProfile() {
        var profile = LightingProfile.commandCenter
        profile.id = UUID()
        profile.name = "New Profile"
        profiles.append(profile)
        selectProfile(profile.id)
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

    private var runtimePolicy: AgentRuntimePolicy {
        AgentRuntimePolicy(
            completedHoldSeconds: selectedProfile.completedHoldSeconds,
            postToolHoldSeconds: selectedProfile.postToolHoldSeconds,
            toolTimeoutSeconds: selectedProfile.toolTimeoutSeconds
        )
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

        let lidMonitor = LidStateMonitor { [weak self] isClosed, isTransition in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lidIsClosed = isClosed
                guard isTransition else { return }
                self.lastLidTransitionAt = .now
                if !isClosed {
                    self.runtime?.acknowledgeCompleted()
                }
                let transition = SystemLightingScenes.lidTransition(
                    ledCount: self.device.ledCount,
                    closing: isClosed
                )
                self.hardware?.preview(
                    program: transition.program,
                    duration: transition.duration
                )
            }
        }
        self.lidMonitor = lidMonitor
        lidMonitor.start()

        let runtime = NativeAgentRuntime(policy: runtimePolicy) { [weak self] agents, message, integrations in
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

        codexActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                application.bundleIdentifier == "com.openai.codex"
            else { return }
            Task { @MainActor [weak self] in
                self?.runtime?.acknowledgeCompleted()
            }
        }
    }

    private func syncHardwareOutput() {
        hardware?.update(enabled: liveOutputEnabled, program: scene.program)
    }
}
