import Foundation

enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case grokBot = "grok_bot"
    case grok
    case claude
    case unknown

    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .grokBot: "Grok Bot"
        case .claude: "Claude"
        case .grok: "Grok"
        case .unknown: "Agent"
        }
    }
}

enum IntegrationConnectionState: String, Codable, Sendable {
    case active, ready, needsSetup

    var title: String {
        switch self {
        case .active: "Active"
        case .ready: "Ready"
        case .needsSetup: "Needs Setup"
        }
    }

    var symbol: String {
        switch self {
        case .active: "wave.3.right.circle.fill"
        case .ready: "checkmark.circle.fill"
        case .needsSetup: "exclamationmark.circle.fill"
        }
    }
}

struct AgentIntegrationStatus: Identifiable, Equatable, Sendable {
    var provider: AgentProvider
    var state: IntegrationConnectionState
    var detail: String
    var activeSessionCount: Int
    var lastEventAt: Date?

    var id: AgentProvider { provider }
}

enum AgentState: String, Codable, CaseIterable, Identifiable, Sendable {
    case idle, working, toolRunning, waiting, error, completed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .idle: "Idle"
        case .working: "Thinking"
        case .toolRunning: "Tool Running"
        case .waiting: "Needs Approval"
        case .error: "Error / Blocked"
        case .completed: "Done"
        }
    }

    var symbol: String {
        switch self {
        case .idle: "moon.stars"
        case .working: "brain.head.profile"
        case .toolRunning: "hammer.fill"
        case .waiting: "hand.raised.fill"
        case .error: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        }
    }

    var priority: Int {
        switch self {
        case .error: 0
        case .waiting: 1
        case .toolRunning: 2
        case .working: 3
        case .completed: 4
        case .idle: 5
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "progress" {
            self = .working
        } else if let state = Self(rawValue: value) {
            self = state
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown agent state: \(value)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum AgentDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case simple
    case perAgent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple: "Simple"
        case .perAgent: "Per Agent"
        }
    }

    var detail: String {
        switch self {
        case .simple:
            "Use the entire array for one prioritized state. Tool activity counts as Thinking."
        case .perAgent:
            "Give each visible session its own stable portion of the array."
        }
    }
}

enum MenuBarIconStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case horizontalEight
    case horizontalFour

    var id: String { rawValue }

    var title: String {
        switch self {
        case .horizontalEight: "8 Horizontal"
        case .horizontalFour: "4 Horizontal"
        }
    }

    var detail: String {
        switch self {
        case .horizontalEight:
            "Show all eight physical LED positions in one compact row."
        case .horizontalFour:
            "Condense adjacent physical positions into four clear sequential dots."
        }
    }
}

enum MenuBarDotLayout {
    static func sourceIndices(
        for style: MenuBarIconStyle,
        ledCount: Int = 8
    ) -> [[Int]] {
        let count = max(1, min(8, ledCount))
        switch style {
        case .horizontalEight:
            return (0..<count).map { [$0] }
        case .horizontalFour:
            let groupCount = min(4, count)
            return (0..<groupCount).map { groupIndex in
                let lowerBound = groupIndex * count / groupCount
                let upperBound = ((groupIndex + 1) * count / groupCount) - 1
                return Array(lowerBound...max(lowerBound, upperBound))
            }
        }
    }

    static func colors(
        for style: MenuBarIconStyle,
        sourceColors: [LEDProgramColor]
    ) -> [LEDProgramColor] {
        sourceIndices(for: style, ledCount: sourceColors.count).map { indices in
            let colors = indices.compactMap { index in
                sourceColors.indices.contains(index) ? sourceColors[index] : nil
            }
            guard !colors.isEmpty else { return .black }
            return colors.max(by: { $0.peak < $1.peak }) ?? .black
        }
    }
}

/// Removes the long dim tails that make a sequential status-bar animation read
/// as a sliding gradient. Full-array and symmetric states remain unchanged
/// because their dots share the same peak brightness.
enum MenuBarSequentialEmphasis {
    static func colors(_ colors: [LEDProgramColor]) -> [LEDProgramColor] {
        let framePeak = colors.map(\.peak).max() ?? 0
        guard framePeak > 0.004 else { return colors }

        return colors.map { color in
            let relativePeak = color.peak / framePeak
            let emphasis = smoothStep(relativePeak, from: 0.92, to: 0.985)
            return color.scaled(by: emphasis)
        }
    }

    private static func smoothStep(_ value: Double, from lower: Double, to upper: Double) -> Double {
        let progress = max(0, min(1, (value - lower) / (upper - lower)))
        return progress * progress * (3 - (2 * progress))
    }
}

struct AgentSession: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var provider: AgentProvider
    var sessionID: String
    var name: String
    var project: String
    var cwd: String?
    var state: AgentState
    var eventName: String
    var toolName: String?
    var updatedAt: Date
    var message: String?
    var openURL: URL? = nil

    var subtitle: String {
        if let toolName, !toolName.isEmpty { return toolName }
        return provider.title
    }
}

enum AgentDisplayPolicy {
    static func aggregateState(
        for agents: [AgentSession],
        mode: AgentDisplayMode
    ) -> AgentState {
        switch mode {
        case .simple:
            return simpleState(for: agents)
        case .perAgent:
            return agents.min(by: {
                if $0.state.priority != $1.state.priority {
                    return $0.state.priority < $1.state.priority
                }
                return $0.updatedAt > $1.updatedAt
            })?.state ?? .idle
        }
    }

    static func lightingSessions(
        from agents: [AgentSession],
        mode: AgentDisplayMode
    ) -> [AgentSession] {
        guard mode == .simple else { return agents }
        let active = agents.filter { $0.state != .idle }
        guard !active.isEmpty else { return [] }

        let state = simpleState(for: active)
        let newestUpdate = active.map(\.updatedAt).max() ?? .now
        return [
            AgentSession(
                id: "sidepulse:simple-signal",
                provider: .unknown,
                sessionID: "simple-signal",
                name: "Combined signal",
                project: "SidePulse",
                cwd: nil,
                state: state,
                eventName: "SimpleMode",
                toolName: nil,
                updatedAt: newestUpdate,
                message: nil
            ),
        ]
    }

    private static func simpleState(for agents: [AgentSession]) -> AgentState {
        agents
            .map { normalizedSimpleState($0.state) }
            .min(by: { simplePriority($0) < simplePriority($1) })
            ?? .idle
    }

    private static func normalizedSimpleState(_ state: AgentState) -> AgentState {
        state == .toolRunning ? .working : state
    }

    private static func simplePriority(_ state: AgentState) -> Int {
        switch state {
        case .error: 0
        case .waiting: 1
        case .working, .toolRunning: 2
        case .completed: 3
        case .idle: 4
        }
    }
}

enum AgentStateTransitionPolicy {
    static func defersToAnimationBoundary(
        from previous: [String: AgentState],
        to current: [String: AgentState]
    ) -> Bool {
        guard !previous.isEmpty,
              Set(previous.keys) == Set(current.keys),
              previous != current
        else { return false }

        let flowingStates: Set<AgentState> = [.working, .toolRunning]
        let changedIDs = current.keys.filter { previous[$0] != current[$0] }
        return !changedIDs.isEmpty && changedIDs.allSatisfy { id in
            guard let oldState = previous[id], let newState = current[id] else { return false }
            return flowingStates.contains(oldState) && flowingStates.contains(newState)
        }
    }
}

enum LightMotion: String, CaseIterable, Identifiable, Sendable, Codable {
    case off, solid, flash, pulse, breathe, chase, converge, diverge

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .solid: "Solid"
        case .flash: "Flash"
        case .pulse: "Pulse Together"
        case .breathe: "Directional Breathe"
        case .chase: "Ping-Pong Chase"
        case .converge: "Converge In"
        case .diverge: "Expand Out"
        }
    }

    var detail: String {
        switch self {
        case .off: "Keep this state dark."
        case .solid: "Hold every assigned LED steadily on."
        case .flash: "Switch the assigned LEDs on and off together."
        case .pulse: "Raise and lower every assigned LED in unison."
        case .breathe: "Offset each pulse from LED 1 toward LED 8."
        case .chase: "Travel to the end of each allocation, then reverse."
        case .converge: "Send two pulses from the allocation edges toward its center."
        case .diverge: "Send two pulses from the allocation center toward its edges."
        }
    }

    var isAnimated: Bool {
        self != .off && self != .solid
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "heartbeat", "solidFade": self = .pulse
        case "shimmer": self = .breathe
        default:
            guard let motion = Self(rawValue: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown light motion: \(value)"
                )
            }
            self = motion
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum LightColorMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case single, colorway, rainbow, rotatingColorway

    var id: String { rawValue }
    var title: String {
        switch self {
        case .single: "Single Color"
        case .colorway: "Two-Color Gradient"
        case .rainbow: "Rainbow"
        case .rotatingColorway: "Rotating Colorway"
        }
    }

    var detail: String {
        switch self {
        case .single: "Use one color across the full allocation."
        case .colorway: "Blend two colors across each agent's LEDs."
        case .rainbow: "Spread the spectrum across each allocation."
        case .rotatingColorway: "Cycle the two-color gradient through each allocation."
        }
    }
}

struct StateLightStyle: Identifiable, Codable, Hashable, Sendable {
    var state: AgentState
    var colorHex: String
    var secondaryColorHex: String
    var colorMode: LightColorMode
    var motion: LightMotion
    var cycleSeconds: Double
    var intensity: Double

    var id: AgentState { state }

    init(
        state: AgentState,
        colorHex: String,
        secondaryColorHex: String = "#7C3AED",
        colorMode: LightColorMode = .single,
        motion: LightMotion,
        cycleSeconds: Double,
        intensity: Double
    ) {
        self.state = state
        self.colorHex = colorHex
        self.secondaryColorHex = secondaryColorHex
        self.colorMode = colorMode
        self.motion = motion
        self.cycleSeconds = cycleSeconds
        self.intensity = intensity
    }

    private enum CodingKeys: String, CodingKey {
        case state, colorHex, secondaryColorHex, colorMode, motion, cycleSeconds, intensity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(AgentState.self, forKey: .state)
        colorHex = try container.decode(String.self, forKey: .colorHex)
        secondaryColorHex = try container.decodeIfPresent(String.self, forKey: .secondaryColorHex) ?? "#7C3AED"
        colorMode = try container.decodeIfPresent(LightColorMode.self, forKey: .colorMode) ?? .single
        motion = try container.decode(LightMotion.self, forKey: .motion)
        cycleSeconds = try container.decode(Double.self, forKey: .cycleSeconds)
        intensity = try container.decode(Double.self, forKey: .intensity)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(colorHex, forKey: .colorHex)
        try container.encode(secondaryColorHex, forKey: .secondaryColorHex)
        try container.encode(colorMode, forKey: .colorMode)
        try container.encode(motion, forKey: .motion)
        try container.encode(cycleSeconds, forKey: .cycleSeconds)
        try container.encode(intensity, forKey: .intensity)
    }
}

enum SlotStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case adaptiveOccupancy, stableAgents, providerLanes, priorityStack

    var id: String { rawValue }
    var title: String {
        switch self {
        case .adaptiveOccupancy: "Adaptive Array"
        case .stableAgents: "Stable Agent Slots"
        case .providerLanes: "Provider Lanes"
        case .priorityStack: "Priority Stack"
        }
    }
}

struct LightingProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var symbol: String
    var strategy: SlotStrategy
    var deviceBrightness: Double
    var styles: [StateLightStyle]

    func style(for state: AgentState) -> StateLightStyle {
        styles.first(where: { $0.state == state })
            ?? .init(state: state, colorHex: "#FFFFFF", motion: .solid, cycleSeconds: 2, intensity: 0.5)
    }

    mutating func updateStyle(_ style: StateLightStyle) {
        replaceStyle(style)
        guard [.working, .toolRunning].contains(style.state) else { return }

        let companionState: AgentState = style.state == .working ? .toolRunning : .working
        var companion = self.style(for: companionState)
        companion.motion = style.motion
        companion.cycleSeconds = style.cycleSeconds
        companion.intensity = style.intensity
        replaceStyle(companion)
    }

    private mutating func replaceStyle(_ style: StateLightStyle) {
        if let index = styles.firstIndex(where: { $0.state == style.state }) {
            styles[index] = style
        } else {
            styles.append(style)
        }
    }
}

extension LightingProfile {
    /// The factory baseline used only for a new library or an explicit state reset.
    /// A profile already saved by the user is always authoritative.
    static let factoryDefault = LightingProfile(
        id: UUID(uuidString: "1B91F090-339B-4C53-8DD2-74FF1F1E0611")!,
        name: "Default",
        symbol: "command",
        strategy: .adaptiveOccupancy,
        deviceBrightness: 0.72,
        styles: [
            .init(state: .idle, colorHex: "#EEF9E0", secondaryColorHex: "#7C3AED", motion: .off, cycleSeconds: 8, intensity: 0),
            .init(state: .working, colorHex: "#FF2BD6", secondaryColorHex: "#DBD1EE", motion: .breathe, cycleSeconds: 1.0340260549065254, intensity: 0.41507945559610704),
            .init(state: .toolRunning, colorHex: "#0018FF", secondaryColorHex: "#7C3AED", motion: .breathe, cycleSeconds: 1.0340260549065254, intensity: 0.41507945559610704),
            .init(state: .waiting, colorHex: "#FFD60A", secondaryColorHex: "#7C3AED", motion: .flash, cycleSeconds: 0.7369829683698299, intensity: 0.88),
            .init(state: .error, colorHex: "#FF0000", secondaryColorHex: "#7C3AED", motion: .solid, cycleSeconds: 1, intensity: 0.95),
            .init(state: .completed, colorHex: "#00D300", secondaryColorHex: "#7C3AED", motion: .solid, cycleSeconds: 1, intensity: 0.85),
        ]
    )

    // Retains the original source name for pre-schema-9 migration compatibility.
    static let commandCenter = factoryDefault

    static let quietNight = LightingProfile(
        id: UUID(uuidString: "7159FD95-BB00-483D-BA83-A619787972B4")!,
        name: "Quiet Night",
        symbol: "moon.stars.fill",
        strategy: .adaptiveOccupancy,
        deviceBrightness: 0.28,
        styles: commandCenter.styles.map { style in
            var result = style
            result.intensity *= 0.45
            result.cycleSeconds *= 1.35
            if result.motion == .chase { result.motion = .breathe }
            return result
        }
    )

    static let highSignal = LightingProfile(
        id: UUID(uuidString: "658CE9CF-17FC-4CB1-93FA-B60134121391")!,
        name: "High Signal",
        symbol: "bolt.fill",
        strategy: .adaptiveOccupancy,
        deviceBrightness: 1,
        styles: commandCenter.styles.map { style in
            var result = style
            result.intensity = min(1, result.intensity * 1.3)
            return result
        }
    )
}

struct AgentLEDSlot: Identifiable, Hashable, Sendable {
    let index: Int
    var agent: AgentSession?
    var id: Int { index }
}

struct AgentArrayPlacement: Identifiable, Equatable, Sendable {
    var agent: AgentSession
    var ledIndices: [Int]

    var id: String { agent.id }

    var rangeLabel: String {
        let physicalLEDs = ledIndices.map { $0 + 1 }.sorted(by: >)
        guard let top = physicalLEDs.first, let bottom = physicalLEDs.last else { return "Off array" }
        return top == bottom ? "LED \(top)" : "LEDs \(top)–\(bottom)"
    }
}

struct CompiledScene: Equatable, Sendable {
    var program: String
    var slots: [AgentLEDSlot]

    /// Physical display order: LED 8 is the top of a Pro, LED 1 is the bottom.
    var placementsTopToBottom: [AgentArrayPlacement] {
        var order: [String] = []
        var agents: [String: AgentSession] = [:]
        var indices: [String: [Int]] = [:]

        for slot in slots.sorted(by: { $0.index > $1.index }) {
            guard let agent = slot.agent else { continue }
            if agents[agent.id] == nil {
                order.append(agent.id)
                agents[agent.id] = agent
            }
            indices[agent.id, default: []].append(slot.index)
        }

        return order.compactMap { id in
            guard let agent = agents[id] else { return nil }
            return AgentArrayPlacement(agent: agent, ledIndices: indices[id, default: []])
        }
    }
}

struct DeviceState: Equatable, Sendable {
    var name = "SidePulse Pro"
    var path = "/Volumes/SidePulse/LEDS.LED"
    var ledCount = 8
    var connected = false
    var activeProgram = "off"
    var sourceProgram = "off"
    var lastWrite: Date?
    var lastError: String?
}

enum BatteryIndicatorMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case levelColorOutline
    case levelColor
    case greenOutline
    case green
    case splitGreenOrange
    case statusArray
    case statusBottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .levelColorOutline: "Level Colors + Outline"
        case .levelColor: "Level Colors"
        case .greenOutline: "Green Bar + Outline"
        case .green: "Green Bar"
        case .splitGreenOrange: "Green → Orange Bar"
        case .statusArray: "AirPods Status · Full Array"
        case .statusBottom: "AirPods Status · Bottom LED"
        }
    }

    var detail: String {
        switch self {
        case .levelColorOutline:
            "Current behavior: charge level in green, orange, or red with unfilled LEDs dim white."
        case .levelColor:
            "Charge level in green, orange, or red with every unfilled LED off."
        case .greenOutline:
            "An always-green charge bar with unfilled LEDs dim white."
        case .green:
            "An always-green charge bar with every unfilled LED off."
        case .splitGreenOrange:
            "The lower four charge steps are green and the upper four are orange."
        case .statusArray:
            "The whole array is solid green above the reminder threshold or orange below it."
        case .statusBottom:
            "Only LED 1 is solid green above the reminder threshold or orange below it."
        }
    }
}

struct BatteryIndicatorSettings: Codable, Equatable, Sendable {
    var showsChargeInfo = true
    var mode: BatteryIndicatorMode = .levelColorOutline
    var showsWhenLidOpens = true
    var showsWhenLidCloses = true
    var lowBatteryReminderEnabled = true
    var lowBatteryThresholdPercent = 25
    var lowBatteryReminderIntervalSeconds = 15

    var normalized: BatteryIndicatorSettings {
        var result = self
        result.lowBatteryThresholdPercent = max(5, min(100, lowBatteryThresholdPercent))
        result.lowBatteryReminderIntervalSeconds = max(5, min(3_600, lowBatteryReminderIntervalSeconds))
        return result
    }
}

enum SidePulseDeviceKind: String, CaseIterable, Sendable {
    case pro
    case dot

    var name: String {
        switch self {
        case .pro: "SidePulse Pro"
        case .dot: "SidePulse Dot"
        }
    }

    var ledCount: Int {
        switch self {
        case .pro: 8
        case .dot: 2
        }
    }

    var outputBrightnessScale: Double {
        switch self {
        case .pro: 1
        case .dot: 0.4
        }
    }

    func calibratedBrightnessScale(universalBrightness: Double) -> Double {
        outputBrightnessScale * max(0, min(1, universalBrightness))
    }

    var outputBlueScale: Double {
        switch self {
        case .pro: 1
        case .dot: 0.75
        }
    }

    var fallbackPath: String {
        switch self {
        case .pro: "/Volumes/SidePulse/LEDS.LED"
        case .dot: "/Volumes/PulseDot/LEDS.LED"
        }
    }

    var disconnectedState: DeviceState {
        DeviceState(name: name, path: fallbackPath, ledCount: ledCount)
    }

    static func detected(fromVolumeName name: String) -> SidePulseDeviceKind? {
        let normalized = name.lowercased().filter(\.isLetter)
        guard normalized.contains("pulse") else { return nil }
        return normalized.contains("dot") ? .dot : .pro
    }
}
