import Foundation

enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, grok, unknown

    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: "Codex"
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
        if let index = styles.firstIndex(where: { $0.state == style.state }) {
            styles[index] = style
        } else {
            styles.append(style)
        }
    }
}

extension LightingProfile {
    static let commandCenter = LightingProfile(
        id: UUID(uuidString: "1B91F090-339B-4C53-8DD2-74FF1F1E0611")!,
        name: "Command Center",
        symbol: "command",
        strategy: .adaptiveOccupancy,
        deviceBrightness: 0.72,
        styles: [
            .init(state: .idle, colorHex: "#0A1520", secondaryColorHex: "#10304A", motion: .breathe, cycleSeconds: 8, intensity: 0.28),
            .init(state: .working, colorHex: "#FF2BD6", secondaryColorHex: "#7C3AED", motion: .breathe, cycleSeconds: 2.6, intensity: 0.82),
            .init(state: .toolRunning, colorHex: "#00D5C8", secondaryColorHex: "#007AFF", motion: .breathe, cycleSeconds: 1.8, intensity: 0.8),
            .init(state: .waiting, colorHex: "#FFD60A", secondaryColorHex: "#FF9F0A", motion: .solid, cycleSeconds: 1, intensity: 0.88),
            .init(state: .error, colorHex: "#FF3B30", secondaryColorHex: "#FF453A", motion: .solid, cycleSeconds: 1, intensity: 0.95),
            .init(state: .completed, colorHex: "#30D158", secondaryColorHex: "#00C7BE", motion: .solid, cycleSeconds: 1, intensity: 0.85),
        ]
    )

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
    var lastWrite: Date?
    var lastError: String?
}
