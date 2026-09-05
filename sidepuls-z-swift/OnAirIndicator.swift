import Foundation

/// User-facing indicator settings for screen capture signals.
///
/// Both capture sources are enabled by default so an active recording or
/// screenshot can be surfaced without requiring additional setup. The owning
/// store decides whether a source is available and how these styles are routed.
struct CaptureIndicatorSettings: Codable, Equatable, Sendable {
    var screenRecordingEnabled = true
    var screenshotEnabled = true
    var recordingStyle = StateLightStyle(
        state: .working,
        colorHex: "#FF9F0A",
        motion: .converge,
        cycleSeconds: 1.8,
        intensity: 0.9
    )
    var screenshotStyle = StateLightStyle(
        state: .working,
        colorHex: "#FFFFFF",
        motion: .converge,
        cycleSeconds: 0.7,
        intensity: 1
    )
}

/// The highest-priority live signal that may own the indicator.
enum OnAirSignal: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case microphone
    case hardwareMuted
    case screenRecording
    case screenshot

    var id: String { rawValue }

    /// Resolves simultaneous capture facts in display-priority order.
    /// Hardware mute only has meaning for an active microphone input.
    static func resolve(
        screenshotActive: Bool,
        microphoneActive: Bool,
        hardwareMuted: Bool,
        screenRecording: Bool
    ) -> Self {
        if screenshotActive { return .screenshot }
        if microphoneActive, !hardwareMuted { return .microphone }
        if screenRecording { return .screenRecording }
        if microphoneActive, hardwareMuted { return .hardwareMuted }
        return .none
    }
}
