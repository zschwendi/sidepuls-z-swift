import Foundation

enum UtilityOutputMode: String, CaseIterable, Sendable {
    case agents, microphone, timer, progress
    var title: String {
        switch self {
        case .agents: "Agents"
        case .microphone: "Microphone"
        case .timer: "Timer"
        case .progress: "Progress"
        }
    }
}

enum UtilityGaugeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case bar, animation
    var id: String { rawValue }
    var title: String { self == .bar ? "LED bar" : "Full-array animation" }
}

struct MicrophoneIndicatorSettings: Codable, Equatable, Sendable {
    var activeStyle = StateLightStyle(state: .working, colorHex: "#FF3B30", motion: .solid, cycleSeconds: 2, intensity: 0.8)
    var mutedStyle = StateLightStyle(state: .waiting, colorHex: "#FFD60A", motion: .solid, cycleSeconds: 2, intensity: 0.6)
    var idleStyle = StateLightStyle(state: .idle, colorHex: "#30D158", motion: .solid, cycleSeconds: 2, intensity: 0.25)
    var showsWhenIdle = true
}

struct TimerIndicatorSettings: Codable, Equatable, Sendable {
    var durationSeconds = 25 * 60
    var warningSeconds = 60
    var gaugeMode = UtilityGaugeMode.bar
    var runningStyle = StateLightStyle(state: .working, colorHex: "#7C3AED", motion: .solid, cycleSeconds: 2, intensity: 0.65)
    var warningStyle = StateLightStyle(state: .waiting, colorHex: "#FF9F0A", motion: .pulse, cycleSeconds: 1.5, intensity: 0.8)
    var finishedStyle = StateLightStyle(state: .completed, colorHex: "#30D158", motion: .flash, cycleSeconds: 0.6, intensity: 0.9)
    var normalized: Self {
        var value = self
        value.durationSeconds = min(86400, max(1, durationSeconds))
        value.warningSeconds = min(value.durationSeconds, max(0, warningSeconds))
        return value
    }
}

struct ProgressIndicatorSettings: Codable, Equatable, Sendable {
    var gaugeMode = UtilityGaugeMode.bar
    var runningStyle = StateLightStyle(state: .working, colorHex: "#0A84FF", motion: .breathe, cycleSeconds: 1.6, intensity: 0.7)
    var completedStyle = StateLightStyle(state: .completed, colorHex: "#30D158", motion: .solid, cycleSeconds: 1, intensity: 0.85)
    var failedStyle = StateLightStyle(state: .error, colorHex: "#FF453A", motion: .flash, cycleSeconds: 0.8, intensity: 0.9)
}

enum CountdownPhase: String, Sendable {
    case idle, running, paused, finished
}

struct CountdownState: Equatable, Sendable {
    var phase = CountdownPhase.idle
    private(set) var duration: TimeInterval = 0
    private(set) var pausedRemaining: TimeInterval = 0
    private(set) var deadline: Date?

    var isActive: Bool { phase != .idle }

    func remaining(at now: Date) -> TimeInterval {
        switch phase {
        case .running: max(0, deadline?.timeIntervalSince(now) ?? 0)
        case .paused: pausedRemaining
        case .idle, .finished: 0
        }
    }

    mutating func start(seconds: TimeInterval, now: Date) {
        duration = min(86400, max(1, seconds))
        pausedRemaining = duration
        deadline = now.addingTimeInterval(duration)
        phase = .running
    }

    mutating func tick(now: Date) {
        if phase == .running, remaining(at: now) <= 0 {
            phase = .finished
            deadline = nil
            pausedRemaining = 0
        }
    }

    mutating func pause(now: Date) {
        tick(now: now)
        guard phase == .running else { return }
        pausedRemaining = remaining(at: now)
        deadline = nil
        phase = .paused
    }

    mutating func resume(now: Date) {
        guard phase == .paused else { return }
        deadline = now.addingTimeInterval(pausedRemaining)
        phase = .running
    }

    mutating func reset() { self = Self() }

    static func label(seconds: TimeInterval) -> String {
        let seconds = Int(ceil(max(0, seconds)))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

enum UtilityPreferences {
    static func load<Value: Codable>(_ type: Value.Type, key: String, default fallback: Value, from defaults: UserDefaults = .standard) -> Value {
        guard let data = defaults.data(forKey: "sidepulse.utility.\(key).v1"),
              let value = try? JSONDecoder().decode(type, from: data)
        else { return fallback }
        return value
    }

    static func save<Value: Codable>(_ value: Value, key: String, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: "sidepulse.utility.\(key).v1")
    }
}

enum UtilityLightingScenes {
    static func program(style: StateLightStyle, ledCount: Int, fraction: Double? = nil) -> String {
        let count = max(1, min(8, ledCount))
        let litCount = fraction.map { Int(ceil(max(0, min(1, $0.isFinite ? $0 : 0)) * Double(count))) } ?? count
        guard litCount > 0 else { return "off" }
        var style = style
        style.state = .working
        let profile = LightingProfile(id: UUID(), name: "Indicator", symbol: "lightbulb", strategy: .adaptiveOccupancy, deviceBrightness: 1, styles: [style])
        let agent = AgentSession(id: "indicator", provider: .unknown, sessionID: "indicator", name: "Indicator", project: "SidePulse", cwd: nil, state: .working, eventName: "Indicator", toolName: nil, updatedAt: .distantPast, message: nil)
        var allocator = StableSlotAllocator()
        let program = LightingSceneCompiler().compile(profile: profile, agents: [agent], allocator: &allocator, ledCount: litCount).program
        // Clear LEDs outside the filled portion before the compiler's indexed
        // program starts. This keeps the same motion and color editor on 2/8 LEDs.
        return litCount == count ? program : "off\n" + program
    }
}
