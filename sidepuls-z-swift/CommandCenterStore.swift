import AppKit
import Foundation
import Observation
import ServiceManagement
import UniformTypeIdentifiers

enum CommandCenterSection: String, CaseIterable, Identifiable {
    case overview, lighting, profiles, agents, hardware, system, diagnostics, settings

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
        case .settings: "Settings"
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
        case .settings: "gearshape.fill"
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
    var agents: [AgentSession]
    var agentSignalHistory: [AgentSignalHistoryEntry] = []
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
    var flashlightMode = AppPreferences.flashlightMode()
    var proColorBalance = AppPreferences.proColorBalance()
    var flashlightEnabled = false
    var ejectPreventionEnabled = AppPreferences.ejectPreventionEnabled()
    var ejectPreventionManagedExternally = false
    var ejectPreventionMessage = "Checking eject prevention…"
    var nearbySharingEnabled = AppPreferences.nearbySharingEnabled()
    var nearbyDiscoveryEnabled = AppPreferences.nearbyDiscoveryEnabled()
    var proSignalSource = AppPreferences.signalSource(for: .pro)
    var dotSignalSource = AppPreferences.signalSource(for: .dot)
    var proOutputCalibration = AppPreferences.outputCalibration(for: .pro)
    var dotOutputCalibration = AppPreferences.outputCalibration(for: .dot)
    var nearbyPeers: [NearbySignalPeer] = []
    var nearbyStatusMessage = "Nearby network is off"
    var nearbyLastSignalAt: Date?
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
    @ObservationIgnored private var routedProScene = CompiledScene(program: "off", slots: [])
    @ObservationIgnored private var routedDotScene = CompiledScene(program: "off", slots: [])
    @ObservationIgnored private var routedProClockOrigin = Date.now
    @ObservationIgnored private var routedDotClockOrigin = Date.now
    @ObservationIgnored private var routedProSourceNodeID: String?
    @ObservationIgnored private var routedDotSourceNodeID: String?
    @ObservationIgnored private let nearbyNodeID = AppPreferences.nearbyNodeID()
    @ObservationIgnored private var localSignalSequence: UInt64 = 0
    @ObservationIgnored private var localProgramStartedAt = Date.now
    @ObservationIgnored private var receivedNearbySignals: [String: ReceivedNearbySignal] = [:]
    @ObservationIgnored private var nearbyService: NearbySidePulseService?
    @ObservationIgnored private var nearbyStaleMonitor: Timer?
    @ObservationIgnored private var runtime: NativeAgentRuntime?
    @ObservationIgnored private var agentSignalHistoryLedger = AgentSignalHistoryLedger.load()
    @ObservationIgnored private var proHardware: SidePulseHardwareController?
    @ObservationIgnored private var dotHardware: SidePulseHardwareController?
    @ObservationIgnored private let ejectGuard = SidePulseEjectGuard()
    @ObservationIgnored private var lidMonitor: LidStateMonitor?
    @ObservationIgnored private var batteryMonitor: BatteryStateMonitor?
    @ObservationIgnored private var lastLowBatteryAlertAt: Date?
    @ObservationIgnored private var isShowingPreviewData = true
    @ObservationIgnored private var lastProOutputStates: [String: AgentState] = [:]
    @ObservationIgnored private var lastDotOutputStates: [String: AgentState] = [:]
    @ObservationIgnored private var profileSelectionObserver: NSObjectProtocol?
    @ObservationIgnored private var focusMonitor: Timer?
    @ObservationIgnored private var hasObservedFocusContext = false
    @ObservationIgnored private var lastObservedFocusProfileID: UUID?
    @ObservationIgnored private var softwareDisplayChangeHandler: (@MainActor @Sendable () -> Void)?

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
                cwd: "/Users/example/Developer/SidePulse-Z",
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
        agentSignalHistory = agentSignalHistoryLedger.entries
        if (proSignalSource.needsNearbySignals || dotSignalSource.needsNearbySignals),
           !nearbyDiscoveryEnabled {
            nearbyDiscoveryEnabled = true
            AppPreferences.saveNearbyDiscoveryEnabled(true)
        }
        recompile()
        refreshLaunchAtLoginStatus()
        startNativeRuntime()
        configureEjectPrevention()
        startNearbySignalService()
        startProfileAutomation()
    }

    var selectedProfile: LightingProfile {
        profiles.first(where: { $0.id == selectedProfileID }) ?? .factoryDefault
    }

    var softwareDisplayProgram: String {
        let routedScene = device.ledCount == SidePulseDeviceKind.dot.ledCount
            ? routedDotScene
            : routedProScene
        let underlyingProgram = device.connected ? device.sourceProgram : routedScene.program
        let program = flashlightEnabled
            ? FlashlightLighting.applying(
                to: underlyingProgram,
                mode: flashlightMode,
                ledCount: device.ledCount
            )
            : underlyingProgram
        let displayBalance = device.kind == .pro ? proColorBalance : .neutral
        return LEDProgramOutputCalibration.scalingColors(
            in: LEDProgramOutputCalibration.settingBrightness(in: program, to: 255),
            redScale: displayBalance.red,
            greenScale: displayBalance.green,
            blueScale: displayBalance.blue
        )
    }

    var softwareDisplayClockOrigin: Date? {
        if device.connected { return device.lastWrite }
        return device.kind == .dot ? routedDotClockOrigin : routedProClockOrigin
    }

    var connectedSoftwareDisplayProgram: String {
        device.connected ? softwareDisplayProgram : "off"
    }

    var aggregateState: AgentState {
        AgentDisplayPolicy.aggregateState(for: agents, mode: agentDisplayMode)
    }

    var lightingAgents: [AgentSession] {
        AgentDisplayPolicy.lightingSessions(from: agents, mode: agentDisplayMode)
    }

    var hasLocalVisibleActivity: Bool {
        lightingAgents.contains { $0.state != .idle }
    }

    func signalSource(for kind: SidePulseDeviceKind) -> SidePulseSignalSource {
        kind == .pro ? proSignalSource : dotSignalSource
    }

    func outputCalibration(for kind: SidePulseDeviceKind) -> SidePulseOutputCalibration {
        kind == .pro ? proOutputCalibration : dotOutputCalibration
    }

    func routedSignalSourceName(for kind: SidePulseDeviceKind) -> String {
        let nodeID = kind == .pro ? routedProSourceNodeID : routedDotSourceNodeID
        guard let nodeID else { return "No active signal" }
        guard nodeID != nearbyNodeID else { return "This Mac" }
        return nearbyPeers.first(where: { $0.id == nodeID })?.displayName ?? "Nearby Mac"
    }

    func signalSourceStatus(for kind: SidePulseDeviceKind) -> String {
        let source = signalSource(for: kind)
        switch source {
        case .thisMac:
            return hasLocalVisibleActivity ? "This Mac · active" : "This Mac · waiting for local activity"
        case .nearbyMac(let peerID):
            let name = nearbyPeers.first(where: { $0.id == peerID })?.displayName ?? "Nearby Mac"
            if let signal = receivedNearbySignals[peerID], signal.isFresh(at: .now) {
                return "Following \(name)"
            }
            return hasLocalVisibleActivity
                ? "\(name) unavailable · using local activity"
                : "\(name) unavailable · waiting"
        case .allMacs:
            return "All Macs · showing \(routedSignalSourceName(for: kind))"
        }
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
        notifySoftwareDisplayChanged()
    }

    func setSoftwareDisplayChangeHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {
        softwareDisplayChangeHandler = handler
        handler?()
    }

    func selectSignalSource(
        _ source: SidePulseSignalSource,
        for kind: SidePulseDeviceKind
    ) {
        guard signalSource(for: kind) != source else { return }
        if kind == .pro {
            proSignalSource = source
        } else {
            dotSignalSource = source
        }
        AppPreferences.saveSignalSource(source, for: kind)
        if source.needsNearbySignals, !nearbyDiscoveryEnabled {
            nearbyDiscoveryEnabled = true
            AppPreferences.saveNearbyDiscoveryEnabled(true)
        }
        refreshNearbyLastSignalAt()
        configureNearbySignalService()
        refreshRoutedOutput()
    }

    func setNearbySharingEnabled(_ enabled: Bool) {
        guard nearbySharingEnabled != enabled else { return }
        nearbySharingEnabled = enabled
        AppPreferences.saveNearbySharingEnabled(enabled)
        configureNearbySignalService()
        publishLocalSignal()
    }

    func setNearbyDiscoveryEnabled(_ enabled: Bool) {
        guard nearbyDiscoveryEnabled != enabled else { return }
        nearbyDiscoveryEnabled = enabled
        AppPreferences.saveNearbyDiscoveryEnabled(enabled)
        if !enabled {
            proSignalSource = .thisMac
            dotSignalSource = .thisMac
            AppPreferences.saveSignalSource(.thisMac, for: .pro)
            AppPreferences.saveSignalSource(.thisMac, for: .dot)
            receivedNearbySignals.removeAll(keepingCapacity: true)
            nearbyPeers = []
        }
        refreshNearbyLastSignalAt()
        configureNearbySignalService()
        refreshRoutedOutput()
    }

    func updateOutputCalibration(
        for kind: SidePulseDeviceKind,
        _ update: (inout SidePulseOutputCalibration) -> Void
    ) {
        var calibration = outputCalibration(for: kind)
        update(&calibration)
        calibration = calibration.normalized
        guard calibration != outputCalibration(for: kind) else { return }
        if kind == .pro {
            proOutputCalibration = calibration
        } else {
            dotOutputCalibration = calibration
        }
        AppPreferences.saveOutputCalibration(calibration, for: kind)
        syncHardwareOutput()
    }

    func resetOutputCalibration(for kind: SidePulseDeviceKind) {
        let calibration = kind.defaultOutputCalibration
        guard outputCalibration(for: kind) != calibration else { return }
        if kind == .pro {
            proOutputCalibration = calibration
        } else {
            dotOutputCalibration = calibration
        }
        AppPreferences.saveOutputCalibration(calibration, for: kind)
        syncHardwareOutput()
    }

    func setUniversalBrightness(_ brightness: Double) {
        let clamped = max(0, min(1, brightness))
        guard abs(universalBrightness - clamped) > 0.000_1 else { return }
        universalBrightness = clamped
        AppPreferences.saveUniversalBrightness(clamped)
        syncHardwareOutput()
    }

    func selectFlashlightMode(_ mode: FlashlightMode) {
        guard flashlightMode != mode else { return }
        flashlightMode = mode
        AppPreferences.saveFlashlightMode(mode)
        if flashlightEnabled {
            syncHardwareOutput(interruptsPreview: true)
            notifySoftwareDisplayChanged()
        }
    }

    func setProColorBalance(_ balance: OutputColorBalance) {
        let normalized = balance.normalized
        guard proColorBalance != normalized else { return }
        proColorBalance = normalized
        AppPreferences.saveProColorBalance(normalized)
        syncHardwareOutput(interruptsPreview: true)
        notifySoftwareDisplayChanged()
    }

    func setFlashlightEnabled(_ enabled: Bool) {
        guard flashlightEnabled != enabled else { return }
        flashlightEnabled = enabled
        syncHardwareOutput(interruptsPreview: true)
        notifySoftwareDisplayChanged()
    }

    func toggleFlashlight() {
        setFlashlightEnabled(!flashlightEnabled)
    }

    var ejectPreventionIsOn: Bool {
        ejectPreventionManagedExternally || ejectGuard.isRunning
    }

    var ejectPreventionCanBeChanged: Bool {
        !ejectPreventionManagedExternally
    }

    func setEjectPreventionEnabled(_ enabled: Bool) {
        guard ejectPreventionCanBeChanged else { return }
        ejectPreventionEnabled = enabled
        AppPreferences.saveEjectPreventionEnabled(enabled)
        configureEjectPrevention()
    }

    var outputPowerIsOn: Bool {
        flashlightEnabled || standardOutputPowerIsOn
    }

    private var standardOutputPowerIsOn: Bool {
        liveOutputEnabled && universalBrightness > 0.000_1
    }

    func setOutputPower(_ enabled: Bool) {
        if enabled {
            let restoresDefaultBrightness = universalBrightness <= 0.000_1
            if restoresDefaultBrightness {
                universalBrightness = 0.5
                AppPreferences.saveUniversalBrightness(0.5)
            }
            if !liveOutputEnabled {
                liveOutputEnabled = true
            } else if restoresDefaultBrightness {
                syncHardwareOutput()
            }
        } else {
            let flashlightWasEnabled = flashlightEnabled
            flashlightEnabled = false
            if liveOutputEnabled {
                liveOutputEnabled = false
            } else if flashlightWasEnabled {
                syncHardwareOutput(interruptsPreview: true)
            }
            if flashlightWasEnabled { notifySoftwareDisplayChanged() }
        }
    }

    func toggleOutputPower() {
        setOutputPower(!outputPowerIsOn)
    }

    var nearbyDisplayStatusMessage: String {
        nearbyStatusMessage
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

    private func configureEjectPrevention() {
        ejectPreventionManagedExternally = SidePulseEjectGuard.runningExternalHelperExists()
        if ejectPreventionManagedExternally {
            ejectGuard.stop()
            ejectPreventionMessage = "Protected by the existing SidePulse eject helper."
            return
        }

        guard ejectPreventionEnabled else {
            ejectGuard.stop()
            ejectPreventionMessage = "Off. Turn this on to protect SidePulse Pro from software ejects."
            return
        }

        do {
            try ejectGuard.start()
            ejectPreventionMessage = "On while SidePulse is running. Other SD cards are not affected."
        } catch {
            ejectPreventionMessage = "Couldn’t start eject prevention: \(error.localizedDescription)"
        }
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

    func openAgent(_ agent: AgentSession) {
        if agent.isAcknowledgableAlert {
            runtime?.acknowledgeAlert(agent)
        }
        openAgentDestination(agent)
    }

    func openHistoricalAgent(_ agent: AgentSession) {
        if agent.isAcknowledgableAlert {
            runtime?.acknowledgeAlert(agent)
        }
        openAgentDestination(agent)
    }

    private func openAgentDestination(_ agent: AgentSession) {
        guard let destination = AgentOpenRouting.destination(for: agent) else { return }

        let workspace = NSWorkspace.shared
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let bundleIdentifier = AgentOpenRouting.applicationBundleIdentifier(for: destination),
           let applicationURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            workspace.open(
                [destination],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { _, _ in }
        } else {
            workspace.open(destination, configuration: configuration) { _, _ in }
        }
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
        let nextProScene = compiler.compile(
            profile: selectedProfile,
            agents: displayedAgents,
            allocator: &proAllocator,
            ledCount: SidePulseDeviceKind.pro.ledCount
        )
        let nextDotScene = compiler.compile(
            profile: selectedProfile,
            agents: displayedAgents,
            allocator: &dotAllocator,
            ledCount: SidePulseDeviceKind.dot.ledCount
        )
        if nextProScene.program != proScene.program || nextDotScene.program != dotScene.program {
            localProgramStartedAt = .now
            localSignalSequence &+= 1
        }
        proScene = nextProScene
        dotScene = nextDotScene
        scene = proDevice.connected || !dotDevice.connected ? proScene : dotScene
        publishLocalSignal()
        refreshRoutedOutput()
    }

    private func localSignalFrame(sentAt: Date = .now) -> NearbySignalFrame {
        NearbySignalFrame(
            sourceNodeID: nearbyNodeID,
            sequence: localSignalSequence,
            generatedAt: localProgramStartedAt,
            sentAt: sentAt,
            programStartedAt: localProgramStartedAt,
            aggregateState: aggregateState,
            hasVisibleActivity: hasLocalVisibleActivity,
            proProgram: proScene.program,
            dotProgram: dotScene.program
        )
    }

    private func publishLocalSignal() {
        nearbyService?.updateLocalFrame(localSignalFrame())
    }

    private func refreshRoutedOutput(now: Date = .now) {
        let localFrame = localSignalFrame(sentAt: now)
        let proRoute = routedOutput(
            for: .pro,
            source: proSignalSource,
            localFrame: localFrame,
            now: now
        )
        let dotRoute = routedOutput(
            for: .dot,
            source: dotSignalSource,
            localFrame: localFrame,
            now: now
        )
        routedProScene = proRoute.scene
        routedDotScene = dotRoute.scene
        routedProClockOrigin = proRoute.clockOrigin
        routedDotClockOrigin = dotRoute.clockOrigin
        routedProSourceNodeID = proRoute.sourceNodeID
        routedDotSourceNodeID = dotRoute.sourceNodeID
        notifySoftwareDisplayChanged()
        syncHardwareOutput()
    }

    private func routedOutput(
        for kind: SidePulseDeviceKind,
        source: SidePulseSignalSource,
        localFrame: NearbySignalFrame,
        now: Date
    ) -> (scene: CompiledScene, clockOrigin: Date, sourceNodeID: String?) {
        guard let routed = NearbySignalRouter.route(
            source: source,
            localFrame: localFrame,
            receivedSignals: receivedNearbySignals,
            now: now
        ) else {
            return (CompiledScene(program: "off", slots: []), now, nil)
        }

        let isLocal = routed.frame.sourceNodeID == nearbyNodeID
        let localSlots = kind == .pro ? proScene.slots : dotScene.slots
        return (
            CompiledScene(
                program: routed.frame.program(for: kind),
                slots: isLocal ? localSlots : []
            ),
            routed.clockOrigin,
            routed.frame.sourceNodeID
        )
    }

    private func notifySoftwareDisplayChanged() {
        softwareDisplayChangeHandler?()
    }

    private func startNearbySignalService() {
        let displayName = Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
        let service = NearbySidePulseService(
            nodeID: nearbyNodeID,
            displayName: displayName,
            onPeers: { [weak self] peers in
                Task { @MainActor [weak self] in
                    self?.handleNearbyPeers(peers)
                }
            },
            onSignal: { [weak self] signal in
                Task { @MainActor [weak self] in
                    self?.handleNearbySignal(signal)
                }
            },
            onStatus: { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.nearbyStatusMessage = status
                }
            }
        )
        nearbyService = service
        configureNearbySignalService()
        publishLocalSignal()
    }

    private func configureNearbySignalService() {
        nearbyService?.configure(nearbyServiceConfiguration)
        updateNearbyStaleMonitor()
    }

    private var nearbyServiceConfiguration: NearbySignalServiceConfiguration {
        let sources = [proSignalSource, dotSignalSource]
        return NearbySignalServiceConfiguration(
            sharesLocalSignal: nearbySharingEnabled,
            discoversPeers: nearbyDiscoveryEnabled,
            followedPeerIDs: Set(sources.compactMap(\.selectedPeerID)),
            followsAllPeers: sources.contains(.allMacs)
        )
    }

    private func updateNearbyStaleMonitor() {
        if nearbyServiceConfiguration.receivesNearbySignals {
            guard nearbyStaleMonitor == nil else { return }
            nearbyStaleMonitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pruneStaleNearbySignals()
                }
            }
        } else {
            nearbyStaleMonitor?.invalidate()
            nearbyStaleMonitor = nil
        }
    }

    private func handleNearbyPeers(_ peers: [NearbySignalPeer]) {
        nearbyPeers = peers
        let availablePeerIDs = Set(peers.map(\.id))
        let disappearedPeerIDs = receivedNearbySignals.keys.filter {
            !availablePeerIDs.contains($0)
        }
        guard !disappearedPeerIDs.isEmpty else { return }
        for peerID in disappearedPeerIDs {
            receivedNearbySignals[peerID] = nil
        }
        refreshNearbyLastSignalAt()
        refreshRoutedOutput()
    }

    private func handleNearbySignal(_ signal: ReceivedNearbySignal) {
        let configuration = nearbyServiceConfiguration
        guard configuration.receivesNearbySignals,
              signal.peerID != nearbyNodeID,
              signal.frame.sourceNodeID == signal.peerID
        else { return }
        if let previous = receivedNearbySignals[signal.peerID] {
            guard signal.frame.sequence > previous.frame.sequence
                    || (signal.frame.sequence == previous.frame.sequence
                        && signal.frame.generatedAt >= previous.frame.generatedAt)
            else { return }
        }
        let now = Date.now
        receivedNearbySignals[signal.peerID] = signal
        refreshNearbyLastSignalAt(now: now)
        refreshRoutedOutput(now: now)
    }

    private func pruneStaleNearbySignals(now: Date = .now) {
        let stalePeerIDs = receivedNearbySignals.compactMap { peerID, signal in
            signal.isFresh(at: now) ? nil : peerID
        }
        guard !stalePeerIDs.isEmpty else { return }
        for peerID in stalePeerIDs {
            receivedNearbySignals[peerID] = nil
        }
        refreshNearbyLastSignalAt(now: now)
        refreshRoutedOutput(now: now)
    }

    private func refreshNearbyLastSignalAt(now: Date = .now) {
        let configuration = nearbyServiceConfiguration
        guard configuration.receivesNearbySignals else {
            nearbyLastSignalAt = nil
            return
        }
        nearbyLastSignalAt = receivedNearbySignals.values
            .filter { signal in
                signal.isFresh(at: now)
                    && (configuration.followsAllPeers
                        || configuration.followedPeerIDs.contains(signal.peerID))
            }
            .map(\.receivedAt)
            .max()
    }

    func previewSelectedState() {
        guard !flashlightEnabled || flashlightMode != .overrideEverything else { return }
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
        let usesFlashlight = flashlightEnabled
        proHardware?.preview(
            program: usesFlashlight
                ? FlashlightLighting.applying(
                    to: proPreview.program,
                    mode: flashlightMode,
                    ledCount: SidePulseDeviceKind.pro.ledCount
                )
                : proPreview.program,
            brightnessScale: usesFlashlight ? 1 : universalBrightness,
            outputCalibration: usesFlashlight ? .flashlight : proOutputCalibration,
            colorBalance: proColorBalance
        )
        dotHardware?.preview(
            program: usesFlashlight
                ? FlashlightLighting.applying(
                    to: dotPreview.program,
                    mode: flashlightMode,
                    ledCount: SidePulseDeviceKind.dot.ledCount
                )
                : dotPreview.program,
            brightnessScale: usesFlashlight ? 1 : universalBrightness,
            outputCalibration: usesFlashlight ? .flashlight : dotOutputCalibration,
            colorBalance: .neutral
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
        guard !flashlightEnabled || flashlightMode != .overrideEverything else { return }
        let chargeFraction = batteryState?.chargeFraction ?? 1
        let proTransition = batteryIndicatorScene(
            chargeFraction: chargeFraction,
            ledCount: SidePulseDeviceKind.pro.ledCount
        )
        let dotTransition = batteryIndicatorScene(
            chargeFraction: chargeFraction,
            ledCount: SidePulseDeviceKind.dot.ledCount
        )
        let usesFlashlight = flashlightEnabled
        proHardware?.preview(
            program: usesFlashlight
                ? FlashlightLighting.applying(
                    to: proTransition.program,
                    mode: flashlightMode,
                    ledCount: SidePulseDeviceKind.pro.ledCount
                )
                : proTransition.program,
            brightnessScale: usesFlashlight ? 1 : universalBrightness,
            outputCalibration: usesFlashlight ? .flashlight : proOutputCalibration,
            colorBalance: proColorBalance,
            duration: proTransition.duration
        )
        dotHardware?.preview(
            program: usesFlashlight
                ? FlashlightLighting.applying(
                    to: dotTransition.program,
                    mode: flashlightMode,
                    ledCount: SidePulseDeviceKind.dot.ledCount
                )
                : dotTransition.program,
            brightnessScale: usesFlashlight ? 1 : universalBrightness,
            outputCalibration: usesFlashlight ? .flashlight : dotOutputCalibration,
            colorBalance: .neutral,
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
        updateFocusMonitor()
    }

    private func reloadProfileSelection() {
        focusAutomationEnabled = ProfileLibrary.focusAutomationEnabled()
        updateFocusMonitor()
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

    private func updateFocusMonitor() {
        focusAutomationEnabled = ProfileLibrary.focusAutomationEnabled()
        guard focusAutomationEnabled else {
            focusMonitor?.invalidate()
            focusMonitor = nil
            activeFocusProfileID = nil
            hasObservedFocusContext = false
            lastObservedFocusProfileID = nil
            return
        }

        if focusMonitor == nil {
            focusMonitor = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.syncFocusProfile()
                }
            }
        }
        Task { @MainActor [weak self] in
            await self?.syncFocusProfile()
        }
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
                if self.agentSignalHistoryLedger.record(agents) {
                    self.agentSignalHistoryLedger.save()
                    self.agentSignalHistory = self.agentSignalHistoryLedger.entries
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
        if topologyChanged {
            recompile()
        } else {
            notifySoftwareDisplayChanged()
        }
    }

    private func handleBatteryUpdate(_ state: BatteryState?) {
        let previousState = batteryState
        if batteryState != state { batteryState = state }
        let chargerConnectionChanged = BatteryState.chargerConnectionChanged(
            from: previousState,
            to: state
        )
        let showedChargerPreview = batterySettings.showsChargeInfo
            && batterySettings.showsWhenPowerSourceChanges
            && chargerConnectionChanged
        if showedChargerPreview {
            previewBatteryIndicator()
        }

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
        if showedChargerPreview {
            lastLowBatteryAlertAt = now
            return
        }
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

    private func syncHardwareOutput(interruptsPreview: Bool = false) {
        let currentProStates = Dictionary(uniqueKeysWithValues: routedProScene.placementsTopToBottom.map {
            ($0.agent.id, $0.agent.state)
        })
        let currentDotStates = Dictionary(uniqueKeysWithValues: routedDotScene.placementsTopToBottom.map {
            ($0.agent.id, $0.agent.state)
        })
        let proTiming = flashlightEnabled
            ? HardwareUpdateTiming.immediate
            : hardwareTiming(from: lastProOutputStates, to: currentProStates)
        let dotTiming = flashlightEnabled
            ? HardwareUpdateTiming.immediate
            : hardwareTiming(from: lastDotOutputStates, to: currentDotStates)
        let proProgram = flashlightEnabled
            ? FlashlightLighting.applying(
                to: routedProScene.program,
                mode: flashlightMode,
                ledCount: SidePulseDeviceKind.pro.ledCount
            )
            : routedProScene.program
        let dotProgram = flashlightEnabled
            ? FlashlightLighting.applying(
                to: routedDotScene.program,
                mode: flashlightMode,
                ledCount: SidePulseDeviceKind.dot.ledCount
            )
            : routedDotScene.program
        let brightnessScale = flashlightEnabled ? 1 : universalBrightness
        let proCalibration = flashlightEnabled ? SidePulseOutputCalibration.flashlight : proOutputCalibration
        let dotCalibration = flashlightEnabled ? SidePulseOutputCalibration.flashlight : dotOutputCalibration
        proHardware?.update(
            enabled: outputPowerIsOn,
            program: proProgram,
            brightnessScale: brightnessScale,
            outputCalibration: proCalibration,
            colorBalance: proColorBalance,
            timing: proTiming,
            interruptsPreview: interruptsPreview
        )
        dotHardware?.update(
            enabled: outputPowerIsOn,
            program: dotProgram,
            brightnessScale: brightnessScale,
            outputCalibration: dotCalibration,
            colorBalance: .neutral,
            timing: flashlightEnabled ? .immediate : dotHardwareTiming(from: dotTiming),
            interruptsPreview: interruptsPreview
        )
        lastProOutputStates = currentProStates
        lastDotOutputStates = currentDotStates
    }

    private func dotHardwareTiming(from timing: HardwareUpdateTiming) -> HardwareUpdateTiming {
        guard case .animationBoundary = timing,
              routedDotScene.placementsTopToBottom.count == 1,
              let placement = routedDotScene.placementsTopToBottom.first,
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
        guard outputPowerIsOn,
              AgentStateTransitionPolicy.defersToAnimationBoundary(from: previous, to: current)
        else { return .immediate }

        let thinkingStyle = selectedProfile.style(for: .working)
        guard thinkingStyle.motion.isAnimated else { return .immediate }
        return .animationBoundary(cycleSeconds: thinkingStyle.cycleSeconds)
    }
}
