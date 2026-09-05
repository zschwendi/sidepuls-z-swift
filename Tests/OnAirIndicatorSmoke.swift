import Foundation

@main
enum OnAirIndicatorSmoke {
    static func main() throws {
        assertSignalPriority()
        try assertSettingsRoundTrip()
        assertScreenshotGeometry()
        print("On-air indicator smoke passed: signal priority, settings round-trip and screenshot converge geometry")
    }

    private static func assertSignalPriority() {
        precondition(
            OnAirSignal.resolve(
                screenshotActive: true,
                microphoneActive: true,
                hardwareMuted: true,
                screenRecording: true
            ) == .screenshot,
            "Screenshot must win over every simultaneous signal"
        )
        precondition(
            OnAirSignal.resolve(
                screenshotActive: false,
                microphoneActive: true,
                hardwareMuted: false,
                screenRecording: true
            ) == .microphone,
            "Live unmuted microphone must win over recording"
        )
        precondition(
            OnAirSignal.resolve(
                screenshotActive: false,
                microphoneActive: true,
                hardwareMuted: true,
                screenRecording: true
            ) == .screenRecording,
            "Recording must win over a hardware-muted microphone"
        )
        precondition(
            OnAirSignal.resolve(
                screenshotActive: false,
                microphoneActive: true,
                hardwareMuted: true,
                screenRecording: false
            ) == .hardwareMuted,
            "Hardware mute applies only to an active microphone"
        )
        precondition(
            OnAirSignal.resolve(
                screenshotActive: false,
                microphoneActive: false,
                hardwareMuted: true,
                screenRecording: false
            ) == .none,
            "A stale mute fact without microphone activity must fall back to none"
        )
        precondition(
            OnAirSignal.resolve(
                screenshotActive: false,
                microphoneActive: false,
                hardwareMuted: false,
                screenRecording: true
            ) == .screenRecording
        )
        precondition(
            OnAirSignal.resolve(
                screenshotActive: false,
                microphoneActive: false,
                hardwareMuted: false,
                screenRecording: false
            ) == .none,
            "No live source must leave the agent signal available"
        )
    }

    private static func assertSettingsRoundTrip() throws {
        let defaults = CaptureIndicatorSettings()
        precondition(defaults.screenRecordingEnabled)
        precondition(defaults.screenshotEnabled)
        precondition(defaults.recordingStyle.state == .working)
        precondition(defaults.recordingStyle.colorHex == "#FF9F0A")
        precondition(defaults.recordingStyle.motion == .converge)
        precondition(defaults.recordingStyle.cycleSeconds == 1.8)
        precondition(defaults.recordingStyle.intensity == 0.9)
        precondition(defaults.screenshotStyle.state == .working)
        precondition(defaults.screenshotStyle.colorHex == "#FFFFFF")
        precondition(defaults.screenshotStyle.motion == .converge)
        precondition(defaults.screenshotStyle.cycleSeconds == 0.7)
        precondition(defaults.screenshotStyle.intensity == 1)

        var custom = defaults
        custom.screenRecordingEnabled = false
        custom.screenshotEnabled = false
        custom.recordingStyle.secondaryColorHex = "#123456"
        custom.recordingStyle.cycleSeconds = 3.25
        custom.screenshotStyle.intensity = 0.8
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(CaptureIndicatorSettings.self, from: data)
        precondition(decoded == custom, "Capture indicator settings did not round-trip")
    }

    private static func assertScreenshotGeometry() {
        let style = CaptureIndicatorSettings().screenshotStyle
        let profile = LightingProfile(
            id: UUID(),
            name: "Screenshot",
            symbol: "camera",
            strategy: .adaptiveOccupancy,
            deviceBrightness: 1,
            styles: [style]
        )
        let agent = AgentSession(
            id: "screenshot",
            provider: .unknown,
            sessionID: "screenshot",
            name: "Screenshot",
            project: "SidePulse",
            cwd: nil,
            state: .working,
            eventName: "Screenshot",
            toolName: nil,
            updatedAt: .distantPast,
            message: nil
        )
        let compiler = LightingSceneCompiler()

        for ledCount in [8, 2] {
            var allocator = StableSlotAllocator()
            let scene = compiler.compile(
                profile: profile,
                agents: [agent],
                allocator: &allocator,
                ledCount: ledCount
            )
            precondition(scene.program.utf8.count <= 512, "Screenshot program exceeds firmware limit")
            precondition(scene.program.contains("#FFFFFF"), "Screenshot program must remain white")
            let firmware = LEDFirmwareProgram(program: scene.program, ledCount: ledCount)
            precondition(firmware.frame(at: 0.11).colors.count == ledCount)
            precondition(firmware.frame(at: 0.11).colors.allSatisfy {
                abs($0.red - $0.green) < 0.001 && abs($0.green - $0.blue) < 0.001
            }, "Screenshot animation must remain neutral white")
        }

        var allocator = StableSlotAllocator()
        let scene = compiler.compile(
            profile: profile,
            agents: [agent],
            allocator: &allocator,
            ledCount: 8
        )
        let lines = scene.program.split(separator: "\n").map(String.init)
        precondition(lines.count >= 3)
        let inwardPhase = lines[1]
        precondition(inwardPhase.contains("0:#FFFFFF 410ms pulse"))
        precondition(inwardPhase.contains("7:#FFFFFF 410ms pulse"))
        precondition(inwardPhase.contains("3:#FFFFFF 410ms pulse 290ms"))
        precondition(inwardPhase.contains("4:#FFFFFF 410ms pulse 290ms"))
    }
}
