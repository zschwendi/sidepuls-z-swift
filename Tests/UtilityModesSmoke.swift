import Foundation

@main
enum UtilityModesSmoke {
    static func main() throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var timer = CountdownState()
        timer.start(seconds: 120, now: start)
        precondition(timer.phase == .running && timer.remaining(at: start) == 120)
        timer.pause(now: start.addingTimeInterval(30))
        precondition(timer.phase == .paused && timer.remaining(at: start.addingTimeInterval(300)) == 90)
        timer.resume(now: start.addingTimeInterval(300))
        precondition(timer.remaining(at: start.addingTimeInterval(330)) == 60)
        // Wall-clock deadline catches up after sleep instead of counting ticks.
        timer.tick(now: start.addingTimeInterval(400))
        precondition(timer.phase == .finished && timer.remaining(at: start.addingTimeInterval(400)) == 0)
        timer.reset()
        precondition(!timer.isActive && timer.phase == .idle)
        timer.start(seconds: 1, now: start)
        timer.pause(now: start.addingTimeInterval(2))
        precondition(timer.phase == .finished)
        precondition(CountdownState.label(seconds: 65.1) == "01:06")
        precondition(CountdownState.label(seconds: 3600) == "1:00:00")

        let suite = "sidepulse.utility-smoke.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = LightingProfile.factoryDefault
        ProfileLibrary.save(profiles: [profile], selectedProfileID: profile.id, to: defaults)
        AppPreferences.saveFlashlightMode(.behindAnimations, to: defaults)
        AppPreferences.saveBatteryIndicatorSettings(BatteryIndicatorSettings(), to: defaults)
        let before = defaults.dictionaryRepresentation()
        var timerSettings = TimerIndicatorSettings()
        timerSettings.durationSeconds = 75
        timerSettings.runningStyle.colorHex = "#123456"
        timerSettings.runningStyle.colorMode = .colorway
        timerSettings.runningStyle.motion = .chase
        UtilityPreferences.save(timerSettings, key: "timer", to: defaults)
        precondition(UtilityPreferences.load(TimerIndicatorSettings.self, key: "timer", default: TimerIndicatorSettings(), from: defaults) == timerSettings)
        let mic = MicrophoneIndicatorSettings()
        UtilityPreferences.save(mic, key: "microphone", to: defaults)
        precondition(UtilityPreferences.load(MicrophoneIndicatorSettings.self, key: "microphone", default: MicrophoneIndicatorSettings(), from: defaults) == mic)
        let progress = ProgressIndicatorSettings()
        UtilityPreferences.save(progress, key: "progress", to: defaults)
        precondition(UtilityPreferences.load(ProgressIndicatorSettings.self, key: "progress", default: ProgressIndicatorSettings(), from: defaults) == progress)
        for (key, value) in before {
            precondition(NSDictionary(dictionary: [key: value]).isEqual(to: [key: defaults.object(forKey: key)!]))
        }

        let style = StateLightStyle(state: .working, colorHex: "#FF0000", motion: .solid, cycleSeconds: 1, intensity: 1)
        for count in [2, 8] {
            for fraction in [0.0, 0.125, 0.5, 1.0] {
                let program = UtilityLightingScenes.program(style: style, ledCount: count, fraction: fraction)
                let frame = LEDFirmwareProgram(program: program, ledCount: count).frame(at: 1)
                let filled = Int(ceil(fraction * Double(count)))
                precondition(frame.colors.filter { $0.red > 0.1 }.count == filled, "Incorrect gauge: \(program)")
                precondition(frame.colors.dropFirst(filled).allSatisfy { $0.peak == 0 })
            }
            for motion in LightMotion.allCases {
                for colorMode in LightColorMode.allCases {
                    var custom = style
                    custom.motion = motion
                    custom.colorMode = colorMode
                    for fraction in [0.125, 0.5, 1.0] {
                        let program = UtilityLightingScenes.program(style: custom, ledCount: count, fraction: fraction)
                        precondition(program.utf8.count <= 512 && program.split(separator: "\n").count <= 20)
                        let firmware = LEDFirmwareProgram(program: program, ledCount: count)
                        for time in [0.0, 0.25, 0.75, 1.5, 4] {
                            let frame = firmware.frame(at: time)
                            let filled = Int(ceil(fraction * Double(count)))
                            precondition(frame.colors.dropFirst(filled).allSatisfy { $0.peak == 0 }, "Motion lit empty gauge cells")
                        }
                    }
                }
            }
        }
        print("Utility modes smoke passed: countdown, sleep, pause, preference isolation, gauge geometry and all animation/color modes")
    }
}
