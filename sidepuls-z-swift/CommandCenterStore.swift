import AppKit
import Foundation
#if PEEL_HOST_INTEGRATION
import SwiftUI
#endif
import Observation
import ServiceManagement
import UniformTypeIdentifiers

enum CommandCenterSection: String, CaseIterable, Identifiable {
    case overview, lighting, agents, hardware, settings
#if PEEL_WORKSPACE
    case usage
#endif
#if PEEL_HOST_INTEGRATION
    case host, remoteMac, mechanic
#endif

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .lighting: "Lighting"
        case .agents: "Agent Hub"
        case .hardware: "Devices & Macs"
        case .settings: "Preferences"
#if PEEL_WORKSPACE
        case .usage: "Usage"
#endif
#if PEEL_HOST_INTEGRATION
        case .host: "Host"
        case .remoteMac: "Remote Mac"
        case .mechanic: "Mechanic"
#endif
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .lighting: "lightbulb.led.wide.fill"
        case .agents: "cpu.fill"
        case .hardware: "point.3.connected.trianglepath.dotted"
        case .settings: "gearshape.fill"
#if PEEL_WORKSPACE
        case .usage: "gauge.with.dots.needle.50percent"
#endif
#if PEEL_HOST_INTEGRATION
        case .host: "rectangle.on.rectangle"
        case .remoteMac: "desktopcomputer"
        case .mechanic: "wrench.and.screwdriver"
#endif
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
    @ObservationIgnored private(set) var batterySampledAt: Date?
    var batterySettings = AppPreferences.batteryIndicatorSettings()
    var agentDisplayMode = AppPreferences.agentDisplayMode()
    var menuBarIconStyle = AppPreferences.menuBarIconStyle()
    var menuBarVisibilityMode = AppPreferences.menuBarVisibilityMode()
    var menuBarKeepWhenAutoHidden = AppPreferences.menuBarKeepWhenAutoHidden()
    var notchEnabled = AppPreferences.notchEnabled()
    var keepAwakeEnabled = false
    var keepAwakeNeedsAuthorization = false
    var keepAwakeStatus = "Keep the Mac awake while SidePulse is running"
    var notchBrightness = AppPreferences.notchBrightness()
    var utilityMode = UtilityOutputMode.agents
    var microphoneSettings = UtilityPreferences.load(MicrophoneIndicatorSettings.self, key: "microphone", default: MicrophoneIndicatorSettings()).upgradingLegacyAppearance
    var captureSettings = UtilityPreferences.load(CaptureIndicatorSettings.self, key: "capture", default: CaptureIndicatorSettings())
    var captureSnapshot = ScreenCaptureSnapshot.unavailable
    var screenshotActive = false
    var timerSettings = UtilityPreferences.load(TimerIndicatorSettings.self, key: "timer", default: TimerIndicatorSettings()).normalized
    var progressSettings = UtilityPreferences.load(ProgressIndicatorSettings.self, key: "progress", default: ProgressIndicatorSettings())
    var microphoneSnapshot = MicrophoneSnapshot.unavailable
    var timerState = CountdownState()
    var timerRemaining: TimeInterval = 0
    var progressSnapshot = ProgressTaskSnapshot.idle
    var progressCommand = ""
    var progressDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    var progressPID = ""
    var utilityError: String?
    var showsModeSettings = false
    var utilitySettingsPage = "microphone"
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
    private(set) var nearbyServiceSnapshot = NearbySignalServiceSnapshot.localOnly
    var nearbyLastSignalAt: Date?
    @ObservationIgnored var openPeelPairing: (@MainActor @Sendable () -> Void)?
#if PEEL_HOST_INTEGRATION
    /// Host-owned compact status content shown in the shared Overview.
    /// Standalone SidePulse leaves this unset, preserving its original view.
    var hostOverviewSummary: AnyView?

    /// Optional host-owned pressure signal. Nil keeps the original SidePulse
    /// routing and hardware output unchanged.
    private(set) var systemPressureIndicator: SidePulseSystemPressureIndicator?
#endif
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
    private var routedProSourceNodeID: String?
    private var routedDotSourceNodeID: String?
    @ObservationIgnored private let nearbyNodeID = AppPreferences.nearbyNodeID()
    @ObservationIgnored private let localHostDisplayName = Host.current().localizedName
        ?? ProcessInfo.processInfo.hostName
    @ObservationIgnored private var localSignalSequence: UInt64 = 0
    @ObservationIgnored private var localProgramStartedAt = Date.now
    @ObservationIgnored private var receivedNearbySignals: [String: ReceivedNearbySignal] = [:]
    @ObservationIgnored private var nearbyService: (any SidePulseSignalServicing)?
    @ObservationIgnored private var nearbyServiceGeneration = UUID()
#if PEEL_HOST_INTEGRATION
    @ObservationIgnored private var trustedSignalServiceInstalled = false
#endif
    @ObservationIgnored private var nearbyStaleMonitor: Timer?
    @ObservationIgnored private var runtime: NativeAgentRuntime?
    @ObservationIgnored private var agentSignalHistoryLedger = AgentSignalHistoryLedger.load()
    @ObservationIgnored private var proHardware: SidePulseHardwareController?
    @ObservationIgnored private var dotHardware: SidePulseHardwareController?
    @ObservationIgnored private let ejectGuard = SidePulseEjectGuard()
    @ObservationIgnored private let keepAwakeController = KeepAwakeController()
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
    @ObservationIgnored private var microphoneMonitor: MicrophoneActivityMonitor?
    @ObservationIgnored private var captureMonitor: ScreenCaptureActivityMonitor?
    @ObservationIgnored private var screenshotReset: Timer?
    @ObservationIgnored private var progressRunner: ProgressTaskRunner?
    @ObservationIgnored private var utilityTimer: Timer?
    @ObservationIgnored private var utilityProProgram: String?
    @ObservationIgnored private var utilityDotProgram: String?
    @ObservationIgnored private var utilityClockOrigin = Date.now
    @ObservationIgnored private var utilityPreview: (pro: String, dot: String, origin: Date)?
    @ObservationIgnored private var utilityPreviewReset: Timer?
    @ObservationIgnored private var utilityTerminationObserver: NSObjectProtocol?
#if PEEL_HOST_INTEGRATION
    @ObservationIgnored private var systemPressureStartedAt = Date.now
#endif
    @ObservationIgnored private var lastProSystemPressureWasActive = false
    @ObservationIgnored private var lastDotSystemPressureWasActive = false

    init() {
#if PEEL_WORKSPACE
        if ProcessInfo.processInfo.arguments.contains("--peel-preview") {
            agents = []
            isShowingPreviewData = false
            runtimeMessage = "Preview — live agent and device connections are paused"
            return
        }
#endif
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
        configureUtilityModes()
        setKeepAwakeEnabled(AppPreferences.keepAwakeEnabled())
    }

    var selectedProfile: LightingProfile {
        profiles.first(where: { $0.id == selectedProfileID }) ?? .factoryDefault
    }

    var softwareDisplayProgram: String {
        let routedScene = device.ledCount == SidePulseDeviceKind.dot.ledCount
            ? routedDotScene
            : routedProScene
        let preview = device.kind == .dot ? utilityPreview?.dot : utilityPreview?.pro
        let utility = device.kind == .dot ? utilityDotProgram : utilityProProgram
        let pressure = systemPressureProgram(for: device.kind)
        let underlyingProgram = preview
            ?? pressure
            ?? (device.connected ? device.sourceProgram : utility ?? routedScene.program)
        let program = flashlightEnabled
            ? FlashlightLighting.applying(
                to: underlyingProgram,
                mode: flashlightMode,
                ledCount: device.ledCount
            )
            : underlyingProgram
        // Color balance is a hardware calibration. Keep software previews,
        // the menu-bar icon, and the notch faithful to the stored program.
        return LEDProgramOutputCalibration.settingBrightness(in: program, to: 255)
    }

    var softwareDisplayClockOrigin: Date? {
        if let preview = utilityPreview { return preview.origin }
#if PEEL_HOST_INTEGRATION
        if systemPressureProgram(for: device.kind) != nil { return systemPressureStartedAt }
#endif
        if device.connected { return device.lastWrite }
        if displayedUtilityMode != .agents { return utilityClockOrigin }
        return device.kind == .dot ? routedDotClockOrigin : routedProClockOrigin
    }

    var connectedSoftwareDisplayProgram: String {
        device.connected ? softwareDisplayProgram : "off"
    }

    private var notchUsesNearbySignal: Bool {
        usesNearbySignal(for: device.kind)
    }

    private func usesNearbySignal(for kind: SidePulseDeviceKind) -> Bool {
        let source = kind == .dot ? routedDotSourceNodeID : routedProSourceNodeID
        return source != nil && source != nearbyNodeID
    }

#if PEEL_HOST_INTEGRATION
    private func canUseSystemPressureIndicator(for kind: SidePulseDeviceKind) -> Bool {
        guard systemPressureIndicator != nil,
              outputPowerIsOn,
              !flashlightEnabled,
              utilityPreview == nil,
              displayedUtilityMode == .agents,
              !hasLocalVisibleActivity,
              !usesNearbySignal(for: kind)
        else { return false }
        return true
    }

    private func activeSystemPressureIndicator(for kind: SidePulseDeviceKind) -> SidePulseSystemPressureIndicator? {
        guard canUseSystemPressureIndicator(for: kind) else { return nil }
        return systemPressureIndicator
    }

    private func systemPressureProgram(for kind: SidePulseDeviceKind) -> String? {
        guard let indicator = activeSystemPressureIndicator(for: kind)
        else { return nil }
        return SystemLightingScenes.systemPressure(
            indicator: indicator,
            ledCount: kind.ledCount
        ).program
    }
#else
    private func systemPressureProgram(for _: SidePulseDeviceKind) -> String? {
        nil
    }
#endif

    var notchDrivingAgents: [AgentSession] {
        guard outputPowerIsOn, displayedUtilityMode == .agents,
              !(flashlightEnabled && flashlightMode == .overrideEverything),
              utilityPreview == nil, !notchUsesNearbySignal else { return [] }
        return NotchAgentSelection.drivingAgents(agents: agents, mode: agentDisplayMode,
                                                displayedAgentIDs: scene.placementsTopToBottom.map { $0.agent.id })
    }

    var notchStatusTitle: String {
        if !outputPowerIsOn { return "Lights off" }
        if flashlightEnabled && flashlightMode == .overrideEverything { return "Flashlight" }
        if utilityPreview != nil { return "Lighting preview" }
        if let utilityStatusTitle { return utilityStatusTitle }
        if notchUsesNearbySignal { return routedSignalSourceName(for: device.kind) }
#if PEEL_HOST_INTEGRATION
        if let indicator = activeSystemPressureIndicator(for: device.kind) { return indicator.title }
#endif
        if notchDrivingAgents.isEmpty { return "SidePulse" }
        return agentDisplayMode == .simple ? aggregateState.title : "Live agents"
    }

    var notchStatusDetail: String {
        if !outputPowerIsOn { return "Turn the lights back on whenever you’re ready." }
        if flashlightEnabled && flashlightMode == .overrideEverything { return "Flashlight is using the full array." }
        if utilityPreview != nil { return "Previewing a lighting style." }
        if displayedUtilityMode != .agents { return utilityStatusDetail }
        if notchUsesNearbySignal { return "Showing a signal from your nearby Mac." }
#if PEEL_HOST_INTEGRATION
        if let indicator = activeSystemPressureIndicator(for: device.kind) { return indicator.detail }
#endif
        if notchDrivingAgents.isEmpty { return "No agent is driving the signal right now." }
        return agentDisplayMode == .simple ? "Driving the current signal" : "Shown on the array"
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

    var localMacDisplayName: String {
        localHostDisplayName
    }

    var localMacNodeID: String {
        nearbyNodeID
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
            if hasLocalVisibleActivity {
                return "This Mac active · \(name) fallback paused"
            }
            if let signal = receivedNearbySignals[peerID],
               signal.frame.hasVisibleActivity,
               signal.isFresh(at: .now) {
                return "Following \(name)"
            }
            if let signal = receivedNearbySignals[peerID], signal.isFresh(at: .now) {
                return "\(name) is idle · waiting"
            }
            return "\(name) unavailable · waiting"
        case .allMacs:
            if hasLocalVisibleActivity {
                return "This Mac active · nearby fallback paused"
            }
            let routedSource = routedSignalSourceName(for: kind)
            return routedSource == "No active signal"
                ? "All Macs · waiting for activity"
                : "All Macs · showing \(routedSource)"
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

#if PEEL_HOST_INTEGRATION
    func setSystemPressureIndicator(_ value: SidePulseSystemPressureIndicator?) {
        guard systemPressureIndicator != value else { return }
        systemPressureIndicator = value
        systemPressureStartedAt = .now
        syncHardwareOutput()
        notifySoftwareDisplayChanged()
    }
#endif

    func setMenuBarVisibilityMode(_ mode: MenuBarVisibilityMode) {
        menuBarVisibilityMode = mode
        AppPreferences.saveMenuBarVisibilityMode(mode)
        notifySoftwareDisplayChanged()
    }

    func setMenuBarKeepWhenAutoHidden(_ enabled: Bool) {
        menuBarKeepWhenAutoHidden = enabled
        AppPreferences.saveMenuBarKeepWhenAutoHidden(enabled)
        notifySoftwareDisplayChanged()
    }

    func setNotchEnabled(_ enabled: Bool) {
        guard notchEnabled != enabled else { return }
        notchEnabled = enabled
        AppPreferences.saveNotchEnabled(enabled)
        notifySoftwareDisplayChanged()
    }

    func toggleKeepAwake() {
        setKeepAwakeEnabled(!keepAwakeEnabled)
        if keepAwakeEnabled && keepAwakeNeedsAuthorization {
            keepAwakeController.authorizeClosedLidProtection()
        }
    }

    func authorizeClosedLidProtection() {
        if !keepAwakeEnabled { setKeepAwakeEnabled(true) }
        keepAwakeController.authorizeClosedLidProtection()
    }

    private func setKeepAwakeEnabled(_ enabled: Bool) {
        keepAwakeController.setEnabled(enabled)
        keepAwakeEnabled = keepAwakeController.isActive
        keepAwakeStatus = keepAwakeController.statusMessage
        keepAwakeNeedsAuthorization = keepAwakeController.needsClosedLidAuthorization
        AppPreferences.saveKeepAwakeEnabled(keepAwakeEnabled)
    }

    func setNotchBrightness(_ brightness: Double) {
        notchBrightness = max(0, min(1, brightness))
        AppPreferences.saveNotchBrightness(notchBrightness)
        notifySoftwareDisplayChanged()
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
        let generation = UUID()
        nearbyServiceGeneration = generation
#if PEEL_HOST_INTEGRATION
        trustedSignalServiceInstalled = false
#endif
        let callbacks = nearbySignalCallbacks(for: generation)
        let service = NearbySidePulseService(
            nodeID: nearbyNodeID,
            displayName: localHostDisplayName,
            onPeers: callbacks.peers,
            onSignal: callbacks.signal,
            onStatus: callbacks.status,
            onSnapshot: callbacks.snapshot
        )
        nearbyService = service
        configureNearbySignalService()
        publishLocalSignal()
    }

#if PEEL_HOST_INTEGRATION
    /// Replaces the local-only placeholder with the authenticated Host-owned
    /// service. The factory is the only path that unlocks cross-device config.
    func installTrustedSignalService(
        factory: @escaping TrustedSidePulseSignalServiceFactory
    ) {
        let generation = UUID()
        nearbyServiceGeneration = generation
        trustedSignalServiceInstalled = false

        nearbyService?.stop()
        nearbyService = nil
        nearbyPeers = []
        receivedNearbySignals.removeAll(keepingCapacity: true)
        nearbyLastSignalAt = nil
        nearbyServiceSnapshot = .localOnly
        nearbyStatusMessage = "Nearby network is off"
        refreshRoutedOutput()

        let callbacks = nearbySignalCallbacks(for: generation)
        let service = factory(
            nearbyNodeID,
            localHostDisplayName,
            callbacks.peers,
            callbacks.signal,
            callbacks.status,
            callbacks.snapshot
        )
        nearbyService = service
        trustedSignalServiceInstalled = true
        configureNearbySignalService()
        publishLocalSignal()
    }
#endif

    private func nearbySignalCallbacks(for generation: UUID) -> (
        peers: NearbySidePulseService.PeerHandler,
        signal: NearbySidePulseService.SignalHandler,
        status: NearbySidePulseService.StatusHandler,
        snapshot: NearbySidePulseService.SnapshotHandler
    ) {
        let peers: NearbySidePulseService.PeerHandler = { [weak self] peers in
            Task { @MainActor [weak self] in
                guard let self, self.nearbyServiceGeneration == generation else { return }
                self.handleNearbyPeers(peers)
            }
        }
        let signal: NearbySidePulseService.SignalHandler = { [weak self] signal in
            Task { @MainActor [weak self] in
                guard let self, self.nearbyServiceGeneration == generation else { return }
                self.handleNearbySignal(signal)
            }
        }
        let status: NearbySidePulseService.StatusHandler = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.nearbyServiceGeneration == generation else { return }
                self.nearbyStatusMessage = status
            }
        }
        let snapshot: NearbySidePulseService.SnapshotHandler = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.nearbyServiceGeneration == generation else { return }
                self.nearbyServiceSnapshot = snapshot
            }
        }
        return (peers: peers, signal: signal, status: status, snapshot: snapshot)
    }

    private func configureNearbySignalService() {
        nearbyService?.configure(nearbyServiceConfiguration)
        updateNearbyStaleMonitor()
    }

    private var nearbyServiceConfiguration: NearbySignalServiceConfiguration {
#if PEEL_HOST_INTEGRATION
        // Cross-device signals stay local-only until the Host installs its
        // authenticated peer transport through installTrustedSignalService.
        guard trustedSignalServiceInstalled else { return .localOnly }
#endif
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
        batterySampledAt = state == nil ? nil : .now
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
        if interruptsPreview, utilityPreview != nil {
            utilityPreviewReset?.invalidate()
            utilityPreviewReset = nil
            utilityPreview = nil
            notifySoftwareDisplayChanged()
        }
        let currentProStates = Dictionary(uniqueKeysWithValues: routedProScene.placementsTopToBottom.map {
            ($0.agent.id, $0.agent.state)
        })
        let currentDotStates = Dictionary(uniqueKeysWithValues: routedDotScene.placementsTopToBottom.map {
            ($0.agent.id, $0.agent.state)
        })
        let pressurePro = systemPressureProgram(for: .pro)
        let pressureDot = systemPressureProgram(for: .dot)
        let proTiming = flashlightEnabled || displayedUtilityMode != .agents || interruptsPreview
            || pressurePro != nil || lastProSystemPressureWasActive
            ? HardwareUpdateTiming.immediate
            : hardwareTiming(from: lastProOutputStates, to: currentProStates)
        let dotTiming = flashlightEnabled || displayedUtilityMode != .agents || interruptsPreview
            || pressureDot != nil || lastDotSystemPressureWasActive
            ? HardwareUpdateTiming.immediate
            : hardwareTiming(from: lastDotOutputStates, to: currentDotStates)
        let proProgram = flashlightEnabled
            ? FlashlightLighting.applying(
                to: utilityProProgram ?? pressurePro ?? routedProScene.program,
                mode: flashlightMode,
                ledCount: SidePulseDeviceKind.pro.ledCount
            )
            : utilityProProgram ?? pressurePro ?? routedProScene.program
        let dotProgram = flashlightEnabled
            ? FlashlightLighting.applying(
                to: utilityDotProgram ?? pressureDot ?? routedDotScene.program,
                mode: flashlightMode,
                ledCount: SidePulseDeviceKind.dot.ledCount
            )
            : utilityDotProgram ?? pressureDot ?? routedDotScene.program
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
        lastProSystemPressureWasActive = pressurePro != nil
        lastDotSystemPressureWasActive = pressureDot != nil
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

extension CommandCenterStore {
    var onAirSignal: OnAirSignal {
        guard utilityMode == .microphone else { return .none }
        return OnAirSignal.resolve(
            screenshotActive: screenshotActive && captureSettings.screenshotEnabled,
            microphoneActive: microphoneSnapshot.activity == .inUse || microphoneSnapshot.activity == .muted,
            hardwareMuted: microphoneSnapshot.activity == .muted,
            screenRecording: captureSnapshot.isRecording && captureSettings.screenRecordingEnabled
        )
    }

    var onAirStyle: StateLightStyle? {
        switch onAirSignal {
        case .none: nil
        case .microphone: microphoneSettings.activeStyle
        case .hardwareMuted: microphoneSettings.mutedStyle
        case .screenRecording: captureSettings.recordingStyle
        case .screenshot: captureSettings.screenshotStyle
        }
    }

    var onAirSymbol: String {
        switch onAirSignal {
        case .none: "mic"
        case .microphone: "mic.fill"
        case .hardwareMuted: "mic.slash.fill"
        case .screenRecording: "record.circle"
        case .screenshot: "camera.viewfinder"
        }
    }

    /// An armed microphone monitor falls through to the agent signal whenever
    /// no input is active. Arming it does not take over an idle array.
    var displayedUtilityMode: UtilityOutputMode {
        if utilityMode == .microphone, onAirSignal == .none {
            return .agents
        }
        return utilityMode
    }

    var utilityStatusTitle: String? {
        switch displayedUtilityMode {
        case .agents: return nil
        case .microphone:
            switch onAirSignal {
            case .microphone, .screenRecording: return "ON AIR"
            case .hardwareMuted: return "Microphone hardware muted"
            case .screenshot: return "Screenshot"
            case .none: return nil
            }
        case .timer: return timerState.phase == .finished ? "Timer finished" : "Timer · \(timerLabel)"
        case .progress:
            switch progressSnapshot.phase {
            case .idle: return "Progress ready"
            case .running: return progressSnapshot.fraction.map { "Progress · \(Int(($0 * 100).rounded()))%" } ?? "Task running"
            case .completed: return "Task finished"
            case .failed: return "Task failed"
            case .cancelled: return "Task cancelled"
            }
        }
    }

    var utilityStatusDetail: String {
        switch utilityMode {
        case .agents: ""
        case .microphone:
            switch onAirSignal {
            case .screenshot: "Screenshot captured"
            case .screenRecording: captureSnapshot.detail
            case .microphone:
                captureSnapshot.isRecording && captureSettings.screenRecordingEnabled
                    ? "Microphone and screen recording are active."
                    : "Microphone active · \(microphoneSnapshot.deviceName)"
            case .hardwareMuted: microphoneSnapshot.detail
            case .none: "Watching for microphone and screen capture activity. Agent lighting is active."
            }
        case .timer:
            timerState.phase == .finished ? "Your countdown is complete. Reset the timer when you’re ready." : timerState.phase == .paused ? "Paused with \(timerLabel) remaining." : "The LEDs count down with your timer."
        case .progress: progressSnapshot.detail
        }
    }

    var timerLabel: String {
        timerState.phase == .finished ? "Done" : CountdownState.label(seconds: timerRemaining)
    }

    private func configureUtilityModes() {
        keepAwakeController.onStatusChanged = { [weak self] in
            guard let self else { return }
            self.keepAwakeStatus = self.keepAwakeController.statusMessage
            self.keepAwakeNeedsAuthorization = self.keepAwakeController.needsClosedLidAuthorization
        }
        microphoneMonitor = MicrophoneActivityMonitor { [weak self] snapshot in
            guard let self, self.utilityMode == .microphone else { return }
            self.microphoneSnapshot = snapshot
            self.refreshUtilityOutput(interruptsPreview: true)
        }
        captureMonitor = ScreenCaptureActivityMonitor(onChange: { [weak self] snapshot in
            guard let self, self.utilityMode == .microphone else { return }
            self.captureSnapshot = snapshot
            self.refreshUtilityOutput(interruptsPreview: true)
        }, onScreenshot: { [weak self] in
            self?.showScreenshotIndicator()
        })
        progressRunner = ProgressTaskRunner { [weak self] snapshot in
            guard let self else { return }
            self.progressSnapshot = snapshot
            if self.utilityMode == .progress { self.refreshUtilityOutput() }
        }
        utilityTerminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.progressRunner?.shutdown()
                self?.keepAwakeController.stop()
                self?.microphoneMonitor?.stop()
                self?.captureMonitor?.stop()
                self?.screenshotReset?.invalidate()
                self?.utilityTimer?.invalidate()
            }
        }
    }

    func selectUtilityMode(_ mode: UtilityOutputMode) {
        let carriesFlashlightPower = mode != .agents && flashlightEnabled && !standardOutputPowerIsOn
        utilityMode = mode
        utilityError = nil
        if mode != .agents { flashlightEnabled = false }
        if carriesFlashlightPower { setOutputPower(true) }
        if mode == .microphone {
            microphoneMonitor?.start()
            captureMonitor?.start()
        } else {
            microphoneMonitor?.stop()
            captureMonitor?.stop()
            screenshotReset?.invalidate()
            screenshotReset = nil
            screenshotActive = false
            captureSnapshot = .unavailable
        }
        utilityPreviewReset?.invalidate()
        utilityPreview = nil
        refreshUtilityOutput(interruptsPreview: true)
    }

    func toggleMicrophone() {
        selectUtilityMode(utilityMode == .microphone ? .agents : .microphone)
    }

    func openUtilitySettings(_ mode: UtilityOutputMode = .microphone) {
        utilitySettingsPage = mode.rawValue
        showsModeSettings = true
        selectedSection = .settings
    }

    func startTimer() {
        timerState.start(seconds: Double(timerSettings.durationSeconds), now: .now)
        timerRemaining = timerState.remaining(at: .now)
        selectUtilityMode(.timer)
        startUtilityTimer()
    }

    func pauseTimer() {
        timerState.pause(now: .now)
        timerRemaining = timerState.remaining(at: .now)
        utilityTimer?.invalidate()
        utilityTimer = nil
        refreshUtilityOutput()
    }

    func resumeTimer() {
        timerState.resume(now: .now)
        timerRemaining = timerState.remaining(at: .now)
        if timerState.phase == .running { startUtilityTimer() }
        refreshUtilityOutput()
    }

    func resetTimer() {
        utilityTimer?.invalidate()
        utilityTimer = nil
        timerState.reset()
        timerRemaining = 0
        if utilityMode == .timer { selectUtilityMode(.agents) }
    }

    private func startUtilityTimer() {
        utilityTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timerState.tick(now: .now)
                self.timerRemaining = self.timerState.remaining(at: .now)
                if self.utilityMode == .timer { self.refreshUtilityOutput() }
                if self.timerState.phase != .running {
                    self.utilityTimer?.invalidate()
                    self.utilityTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        utilityTimer = timer
    }

    func updateMicrophoneSettings(_ update: (inout MicrophoneIndicatorSettings) -> Void) {
        update(&microphoneSettings)
        UtilityPreferences.save(microphoneSettings, key: "microphone")
        if utilityMode == .microphone { refreshUtilityOutput() }
    }

    func updateCaptureSettings(_ update: (inout CaptureIndicatorSettings) -> Void) {
        update(&captureSettings)
        if !captureSettings.screenshotEnabled {
            screenshotReset?.invalidate()
            screenshotReset = nil
            screenshotActive = false
        }
        UtilityPreferences.save(captureSettings, key: "capture")
        if utilityMode == .microphone { refreshUtilityOutput(interruptsPreview: true) }
    }

    func enableScreenRecordingDetection() {
        captureMonitor?.requestAccessibilityAccess()
    }

    private func showScreenshotIndicator() {
        guard utilityMode == .microphone, captureSettings.screenshotEnabled else { return }
        screenshotReset?.invalidate()
        screenshotActive = true
        utilityClockOrigin = .now
        refreshUtilityOutput(interruptsPreview: true)
        // One complete sweep, then restore the current mic/recording/agent signal.
        let duration = max(0.2, min(30, captureSettings.screenshotStyle.cycleSeconds))
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screenshotActive = false
                self.screenshotReset = nil
                self.refreshUtilityOutput(interruptsPreview: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        screenshotReset = timer
    }

    func updateTimerSettings(_ update: (inout TimerIndicatorSettings) -> Void) {
        update(&timerSettings)
        timerSettings = timerSettings.normalized
        UtilityPreferences.save(timerSettings, key: "timer")
        if utilityMode == .timer { refreshUtilityOutput() }
    }

    func updateProgressSettings(_ update: (inout ProgressIndicatorSettings) -> Void) {
        update(&progressSettings)
        UtilityPreferences.save(progressSettings, key: "progress")
        if utilityMode == .progress { refreshUtilityOutput() }
    }

    func chooseProgressDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose a working folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: progressDirectory)
        if panel.runModal() == .OK, let url = panel.url { progressDirectory = url.path }
    }

    func runProgressCommand() {
        do {
            try progressRunner?.run(command: progressCommand, directory: URL(fileURLWithPath: progressDirectory))
            selectUtilityMode(.progress)
        } catch { utilityError = error.localizedDescription }
    }

    func watchProgressProcess() {
        guard let pid = Int32(progressPID), pid > 0 else {
            utilityError = "Enter the process ID of the task to watch."
            return
        }
        do {
            try progressRunner?.watch(pid: pid)
            selectUtilityMode(.progress)
        } catch { utilityError = error.localizedDescription }
    }

    func cancelProgress() { progressRunner?.cancel() }

    func clearProgress() {
        progressRunner?.clear()
        if progressSnapshot.phase != .running, utilityMode == .progress { selectUtilityMode(.agents) }
    }

    func openProgressLog() {
        if let url = progressSnapshot.logURL { NSWorkspace.shared.open(url) }
    }

    private func refreshUtilityOutput(interruptsPreview: Bool = false) {
        let pro = utilityProgram(ledCount: 8)
        let dot = utilityProgram(ledCount: 2)
        if utilityProProgram != pro || utilityDotProgram != dot { utilityClockOrigin = .now }
        utilityProProgram = pro
        utilityDotProgram = dot
        syncHardwareOutput(interruptsPreview: interruptsPreview)
        notifySoftwareDisplayChanged()
    }

    private func utilityProgram(ledCount: Int) -> String? {
        switch utilityMode {
        case .agents: return nil
        case .microphone:
            guard let style = onAirStyle else { return nil }
            return UtilityLightingScenes.program(style: style, ledCount: ledCount)
        case .timer:
            guard timerState.isActive else { return "off" }
            if timerState.phase == .finished {
                return UtilityLightingScenes.program(style: timerSettings.finishedStyle, ledCount: ledCount)
            }
            let style = timerRemaining <= Double(timerSettings.warningSeconds) ? timerSettings.warningStyle : timerSettings.runningStyle
            let fraction = timerSettings.gaugeMode == .bar && timerState.duration > 0 ? timerRemaining / timerState.duration : nil
            return UtilityLightingScenes.program(style: style, ledCount: ledCount, fraction: fraction)
        case .progress:
            switch progressSnapshot.phase {
            case .idle, .cancelled: return "off"
            case .running:
                return UtilityLightingScenes.program(style: progressSettings.runningStyle, ledCount: ledCount, fraction: progressSettings.gaugeMode == .bar ? progressSnapshot.fraction : nil)
            case .completed:
                return UtilityLightingScenes.program(style: progressSettings.completedStyle, ledCount: ledCount)
            case .failed:
                return UtilityLightingScenes.program(style: progressSettings.failedStyle, ledCount: ledCount)
            }
        }
    }

    func previewUtilityStyle(_ style: StateLightStyle) {
        guard !flashlightEnabled || flashlightMode != .overrideEverything else { return }
        let pro = UtilityLightingScenes.program(style: style, ledCount: 8)
        let dot = UtilityLightingScenes.program(style: style, ledCount: 2)
        utilityPreviewReset?.invalidate()
        utilityPreview = (pro, dot, .now)
        notifySoftwareDisplayChanged()
        proHardware?.preview(program: flashlightEnabled ? FlashlightLighting.applying(to: pro, mode: flashlightMode, ledCount: 8) : pro,
                             brightnessScale: flashlightEnabled ? 1 : universalBrightness,
                             outputCalibration: flashlightEnabled ? .flashlight : proOutputCalibration, colorBalance: proColorBalance)
        dotHardware?.preview(program: flashlightEnabled ? FlashlightLighting.applying(to: dot, mode: flashlightMode, ledCount: 2) : dot,
                             brightnessScale: flashlightEnabled ? 1 : universalBrightness,
                             outputCalibration: flashlightEnabled ? .flashlight : dotOutputCalibration, colorBalance: .neutral)
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.utilityPreview = nil
                self?.notifySoftwareDisplayChanged()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        utilityPreviewReset = timer
    }
}
