import Foundation

@main
enum SceneCompilerSmoke {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let compiler = LightingSceneCompiler()

        var emptyAllocator = StableSlotAllocator()
        let empty = compiler.compile(
            profile: .commandCenter,
            agents: [],
            allocator: &emptyAllocator,
            now: now
        )
        precondition(empty.program == "off", "No agents must turn the array off")

        let profile = LightingProfile.factoryDefault
        precondition(profile.style(for: .idle).motion == .off)
        precondition(profile.style(for: .idle).intensity == 0)
        precondition(profile.style(for: .working).colorHex == "#FF2BD6")
        precondition(profile.style(for: .working).motion == .breathe)
        precondition(profile.style(for: .working).cycleSeconds == 1.0340260549065254)
        precondition(profile.style(for: .working).intensity == 0.41507945559610704)
        precondition(profile.style(for: .toolRunning).colorHex == "#0018FF")
        precondition(profile.style(for: .toolRunning).motion == profile.style(for: .working).motion)
        precondition(profile.style(for: .toolRunning).cycleSeconds == profile.style(for: .working).cycleSeconds)
        precondition(profile.style(for: .toolRunning).intensity == profile.style(for: .working).intensity)
        precondition(profile.style(for: .waiting).colorHex == "#FFD60A")
        precondition(profile.style(for: .waiting).motion == .flash)
        precondition(profile.style(for: .waiting).cycleSeconds == 0.7369829683698299)
        precondition(profile.style(for: .completed).colorHex == "#00D300")
        precondition(profile.style(for: .completed).motion == .solid)
        precondition(profile.style(for: .error).colorHex == "#FF0000")
        precondition(profile.style(for: .error).motion == .solid)
        precondition(!AgentState.allCases.contains(where: { $0.rawValue == "progress" }))

        assertSimpleDisplayPolicy(now: now, compiler: compiler)

        var breatheAllocator = StableSlotAllocator()
        let breathe = compiler.compile(
            profile: profile,
            agents: [session("thinking", updatedAt: now)],
            allocator: &breatheAllocator,
            now: now
        )
        precondition(breathe.program.contains("\noff\n"), "Animated scenes must seed a dark base")
        precondition(breathe.program.contains("0:#6A1259 600ms pulse"), "Thinking breathe must begin at LED 1")
        precondition(breathe.program.contains("7:#6A1259 600ms pulse 430ms"), "Thinking breathe must travel through LED 8")
        precondition(breathe.program.contains("repeat"))

        assertMotionPrograms(now: now, compiler: compiler)
        assertColorPrograms(now: now, compiler: compiler)
        assertLegacyStyleDecoding()

        precondition(SystemLightingScenes.illuminatedLEDCount(chargeFraction: 0, ledCount: 8) == 1)
        precondition(SystemLightingScenes.illuminatedLEDCount(chargeFraction: 0.125, ledCount: 8) == 1)
        precondition(SystemLightingScenes.illuminatedLEDCount(chargeFraction: 0.1875, ledCount: 8) == 2)
        precondition(SystemLightingScenes.illuminatedLEDCount(chargeFraction: 0.9374, ledCount: 8) == 7)
        precondition(SystemLightingScenes.illuminatedLEDCount(chargeFraction: 0.9375, ledCount: 8) == 8)

        let batteryGauge = SystemLightingScenes.batteryGauge(chargeFraction: 0.45, ledCount: 8)
        precondition(batteryGauge.program.hasPrefix("brightness 255\n#4D4D4D\n"))
        precondition(batteryGauge.program.contains("0:#FF9F0A 120ms cosine"))
        precondition(batteryGauge.program.contains("3:#FF9F0A 120ms cosine 378ms"))
        precondition(batteryGauge.program.contains("3:#FF9F0A 1500ms none"))
        precondition(batteryGauge.program.contains("4:#4D4D4D 1500ms none"), "Unfilled battery LEDs must remain dim white")
        precondition(batteryGauge.duration == 2, "Battery gauge must animate for 0.5s and hold for 1.5s")
        precondition(batteryGauge.program.utf8.count <= 512)

        let greenBattery = SystemLightingScenes.batteryGauge(chargeFraction: 0.625, ledCount: 8)
        precondition(greenBattery.program.contains("4:#66FF5F 1500ms none"))
        let redBattery = SystemLightingScenes.batteryGauge(chargeFraction: 0.25, ledCount: 8)
        precondition(redBattery.program.contains("1:#FF3B30 1500ms none"))
        let dotFullBattery = SystemLightingScenes.batteryGauge(chargeFraction: 1, ledCount: 2)
        precondition(dotFullBattery.program.contains("1:#66FF5F 1500ms none"))
        let dotHalfBattery = SystemLightingScenes.batteryGauge(chargeFraction: 0.5, ledCount: 2)
        precondition(dotHalfBattery.program.contains("0:#FF9F0A 1500ms none"))

        let levelWithoutOutline = SystemLightingScenes.batteryGauge(
            chargeFraction: 0.45,
            ledCount: 8,
            mode: .levelColor
        )
        precondition(levelWithoutOutline.program.hasPrefix("brightness 255\noff\n"))
        precondition(levelWithoutOutline.program.contains("3:#FF9F0A 1500ms none"))
        precondition(levelWithoutOutline.program.contains("4:#000000 1500ms none"))

        let greenOutline = SystemLightingScenes.batteryGauge(
            chargeFraction: 0.25,
            ledCount: 8,
            mode: .greenOutline
        )
        precondition(greenOutline.program.contains("1:#66FF5F 1500ms none"))
        precondition(greenOutline.program.contains("2:#4D4D4D 1500ms none"))

        let greenWithoutOutline = SystemLightingScenes.batteryGauge(
            chargeFraction: 0.25,
            ledCount: 8,
            mode: .green
        )
        precondition(greenWithoutOutline.program.contains("1:#66FF5F 1500ms none"))
        precondition(greenWithoutOutline.program.contains("2:#000000 1500ms none"))

        let splitBar = SystemLightingScenes.batteryGauge(
            chargeFraction: 1,
            ledCount: 8,
            mode: .splitGreenOrange
        )
        precondition(splitBar.program.contains("3:#66FF5F 1500ms none"))
        precondition(splitBar.program.contains("4:#FF9F0A 1500ms none"))
        precondition(splitBar.program.contains("7:#FF9F0A 1500ms none"))

        let statusCharged = SystemLightingScenes.batteryGauge(
            chargeFraction: 0.72,
            ledCount: 8,
            mode: .statusArray,
            lowBatteryThresholdPercent: 25
        )
        precondition(statusCharged.program == "brightness 255\noff\n#66FF5F 2s none")
        let statusLow = SystemLightingScenes.batteryGauge(
            chargeFraction: 0.25,
            ledCount: 8,
            mode: .statusArray,
            lowBatteryThresholdPercent: 25
        )
        precondition(statusLow.program == "brightness 255\noff\n#FF9F0A 2s none")
        let statusBottom = SystemLightingScenes.batteryGauge(
            chargeFraction: 0.25,
            ledCount: 8,
            mode: .statusBottom,
            lowBatteryThresholdPercent: 25
        )
        precondition(statusBottom.program == "brightness 255\noff\n0:#FF9F0A 2s none")

        for mode in BatteryIndicatorMode.allCases {
            let scene = SystemLightingScenes.batteryGauge(
                chargeFraction: 0.25,
                ledCount: 8,
                mode: mode
            )
            precondition(scene.duration == 2)
            precondition(scene.program.utf8.count <= 512, "\(mode.title) exceeds the firmware limit")
        }

        let brightnessPreview = LEDFirmwareProgram(
            program: "brightness 128\n0:#FF0000;1:#00FF00",
            ledCount: 2
        ).frame(at: 0)
        precondition(approximately(brightnessPreview.colors[0].red, 128.0 / 255))
        precondition(approximately(brightnessPreview.colors[0].green, 0))
        precondition(approximately(brightnessPreview.colors[1].green, 128.0 / 255))

        let pulsePreview = LEDFirmwareProgram(
            program: "off\n0:#FF0000 1s pulse\nrepeat",
            ledCount: 1
        )
        precondition(approximately(pulsePreview.frame(at: (1.0 / 60) + 0.5).colors[0].red, 1))
        precondition(approximately(pulsePreview.frame(at: (1.0 / 60) + 1).colors[0].red, 0))

        let staggeredPreview = LEDFirmwareProgram(
            program: "off\n0:#FF0000 500ms cosine;1:#00FF00 500ms cosine 250ms",
            ledCount: 2
        ).frame(at: (1.0 / 60) + 0.25)
        precondition(approximately(staggeredPreview.colors[0].red, 0.5))
        precondition(approximately(staggeredPreview.colors[1].green, 0))

        let batteryPreview = LEDFirmwareProgram(
            program: batteryGauge.program,
            ledCount: 8
        ).frame(at: (1.0 / 60) + 0.7)
        precondition(approximately(batteryPreview.colors[0].red, 1))
        precondition(approximately(batteryPreview.colors[0].green, 159.0 / 255))
        precondition(approximately(batteryPreview.colors[0].blue, 10.0 / 255))
        precondition(approximately(batteryPreview.colors[4].red, 77.0 / 255))
        precondition(approximately(batteryPreview.colors[4].green, 77.0 / 255))
        precondition(approximately(batteryPreview.colors[4].blue, 77.0 / 255))

        var linkedProfile = profile
        var linkedThinking = linkedProfile.style(for: .working)
        linkedThinking.motion = .chase
        linkedThinking.cycleSeconds = 3.4
        linkedThinking.intensity = 0.64
        linkedProfile.updateStyle(linkedThinking)
        let linkedTool = linkedProfile.style(for: .toolRunning)
        precondition(linkedTool.motion == .chase)
        precondition(linkedTool.cycleSeconds == 3.4)
        precondition(linkedTool.intensity == 0.64)
        precondition(linkedTool.colorHex == "#0018FF", "Tool Running must retain its own palette")
        precondition(AgentStateTransitionPolicy.defersToAnimationBoundary(
            from: ["agent": .working],
            to: ["agent": .toolRunning]
        ))
        precondition(AgentStateTransitionPolicy.defersToAnimationBoundary(
            from: ["agent": .toolRunning],
            to: ["agent": .working]
        ))
        precondition(!AgentStateTransitionPolicy.defersToAnimationBoundary(
            from: ["agent": .working],
            to: ["agent": .completed]
        ), "Done must switch immediately")
        precondition(!AgentStateTransitionPolicy.defersToAnimationBoundary(
            from: ["agent": .toolRunning],
            to: ["agent": .waiting]
        ), "Needs Approval must switch immediately")
        precondition(!AgentStateTransitionPolicy.defersToAnimationBoundary(
            from: ["agent": .working],
            to: ["agent": .error]
        ), "Error must switch immediately")

        assertProLayout(agentCount: 1, expectedOccupancy: [8], now: now, compiler: compiler)
        assertProLayout(agentCount: 2, expectedOccupancy: [4, 4], now: now, compiler: compiler)
        assertProLayout(agentCount: 3, expectedOccupancy: [2, 2, 2], now: now, compiler: compiler)
        assertProLayout(agentCount: 4, expectedOccupancy: [2, 2, 2, 2], now: now, compiler: compiler)
        assertProLayout(agentCount: 5, expectedOccupancy: [1, 1, 1, 1, 1], now: now, compiler: compiler)
        assertProLayout(agentCount: 8, expectedOccupancy: Array(repeating: 1, count: 8), now: now, compiler: compiler)

        let nineAgents = makeAgents(9, now: now)
        var cappedAllocator = StableSlotAllocator()
        let capped = compiler.compile(
            profile: .commandCenter,
            agents: nineAgents,
            allocator: &cappedAllocator,
            now: now
        )
        precondition(capped.placementsTopToBottom.count == 8)
        precondition(capped.placementsTopToBottom.first?.agent.id == "agent:0", "Newest agent must enter at LED 8")
        precondition(!capped.placementsTopToBottom.map(\.agent.id).contains("agent:8"), "Oldest ninth agent must be omitted")

        var stableAllocator = StableSlotAllocator()
        let initialAgents = makeAgents(2, now: now)
        let initial = compiler.compile(
            profile: .commandCenter,
            agents: initialAgents,
            allocator: &stableAllocator,
            now: now
        )
        var updatedAgents = initialAgents
        updatedAgents[1].updatedAt = now.addingTimeInterval(10)
        let updated = compiler.compile(
            profile: .commandCenter,
            agents: updatedAgents,
            allocator: &stableAllocator,
            now: now.addingTimeInterval(10)
        )
        precondition(
            updated.placementsTopToBottom.map(\.agent.id) == initial.placementsTopToBottom.map(\.agent.id),
            "Activity updates must not reshuffle resident agents"
        )
        let newcomer = session("agent:2", updatedAt: now.addingTimeInterval(20))
        let expanded = compiler.compile(
            profile: .commandCenter,
            agents: updatedAgents + [newcomer],
            allocator: &stableAllocator,
            now: now.addingTimeInterval(20)
        )
        precondition(expanded.placementsTopToBottom.map(\.agent.id) == ["agent:0", "agent:1", "agent:2"])

        var fullAllocator = StableSlotAllocator()
        let fullAgents = makeAgents(8, now: now)
        let full = compiler.compile(
            profile: .commandCenter,
            agents: fullAgents,
            allocator: &fullAllocator,
            now: now
        )
        let replacement = session("agent:new", updatedAt: now.addingTimeInterval(30))
        let replaced = compiler.compile(
            profile: .commandCenter,
            agents: fullAgents + [replacement],
            allocator: &fullAllocator,
            now: now.addingTimeInterval(30)
        )
        let beforeIDs = full.placementsTopToBottom.map(\.agent.id)
        let afterIDs = replaced.placementsTopToBottom.map(\.agent.id)
        precondition(Array(afterIDs.prefix(7)) == Array(beforeIDs.prefix(7)), "Full-array replacement must not move other residents")
        precondition(afterIDs.last == "agent:new", "Newest newcomer must replace the least-recent resident in place")

        var dotAllocator = StableSlotAllocator()
        let oneDotAgent = compiler.compile(
            profile: .commandCenter,
            agents: [session("dot:0", updatedAt: now)],
            allocator: &dotAllocator,
            ledCount: 2,
            now: now
        )
        precondition(oneDotAgent.placementsTopToBottom.map(\.ledIndices.count) == [2])
        dotAllocator.reset()
        let dotAgents = makeAgents(3, now: now)
        let cappedDot = compiler.compile(
            profile: .commandCenter,
            agents: dotAgents,
            allocator: &dotAllocator,
            ledCount: 2,
            now: now
        )
        precondition(cappedDot.placementsTopToBottom.map(\.ledIndices.count) == [1, 1])
        precondition(cappedDot.placementsTopToBottom.map(\.agent.id) == ["agent:0", "agent:1"])

        precondition(SidePulseDeviceKind.detected(fromVolumeName: "SidePulse") == .pro)
        precondition(SidePulseDeviceKind.detected(fromVolumeName: "SidePulse Pro") == .pro)
        precondition(SidePulseDeviceKind.detected(fromVolumeName: "PulseDot") == .dot)
        precondition(SidePulseDeviceKind.detected(fromVolumeName: "SidePulse Dot") == .dot)
        precondition(SidePulseDeviceKind.detected(fromVolumeName: "Macintosh HD") == nil)
        precondition(SidePulseDeviceKind.pro.outputBrightnessScale == 1)
        precondition(SidePulseDeviceKind.dot.outputBrightnessScale == 0.4)
        precondition(SidePulseDeviceKind.pro.outputBlueScale == 1)
        precondition(SidePulseDeviceKind.dot.outputBlueScale == 0.75)
        precondition(
            LEDProgramOutputCalibration.scalingBrightness(
                in: "brightness 183\n0:#00B300;1:#000000",
                by: SidePulseDeviceKind.dot.outputBrightnessScale
            ) == "brightness 73\n0:#00B300;1:#000000"
        )
        precondition(
            LEDProgramOutputCalibration.scalingBrightness(
                in: "0:#FFFFFF;1:#FFFFFF",
                by: SidePulseDeviceKind.dot.outputBrightnessScale
            ) == "brightness 102\n0:#FFFFFF;1:#FFFFFF"
        )
        precondition(LEDProgramOutputCalibration.scalingBrightness(in: "off", by: 0.4) == "off")
        precondition(
            LEDProgramOutputCalibration.applying(
                to: "brightness 183\n0:#6A1259;1:#000A6A",
                brightnessScale: 0.4,
                blueScale: 0.75
            ) == "brightness 73\n0:#6A1243;1:#000A50"
        )
        precondition(
            LEDProgramOutputCalibration.scalingBrightness(in: batteryGauge.program, by: 0.4)
                .hasPrefix("brightness 102\n")
        )

        var proMirrorAllocator = StableSlotAllocator()
        var dotMirrorAllocator = StableSlotAllocator()
        let mirrorAgent = session("mirror:0", updatedAt: now)
        let mirroredPro = compiler.compile(
            profile: profile,
            agents: [mirrorAgent],
            allocator: &proMirrorAllocator,
            ledCount: 8,
            now: now
        )
        let mirroredDot = compiler.compile(
            profile: profile,
            agents: [mirrorAgent],
            allocator: &dotMirrorAllocator,
            ledCount: 2,
            now: now
        )
        precondition(mirroredPro.program.contains("0:#6A1259 600ms pulse"))
        precondition(mirroredPro.program.contains("7:#6A1259 600ms pulse 430ms"))
        precondition(mirroredDot.program.contains("0:#6A1259 250ms cosine"), "Bottom Dot must fade in first")
        precondition(mirroredDot.program.contains("1:#6A1259 250ms cosine"), "Top Dot must fade in second")
        precondition(mirroredDot.program.contains("0:#000000 250ms cosine"), "Bottom Dot must fade out third")
        precondition(mirroredDot.program.contains("1:#000000 250ms cosine"), "Top Dot must fade out fourth")
        precondition(!mirroredDot.program.contains("pulse"), "Dot breathe must not look like alternating police lights")

        let dotBreatheRenderer = LEDFirmwareProgram(program: mirroredDot.program, ledCount: 2)
        let lowerFadeIn = dotBreatheRenderer.frame(at: (1.0 / 60) + 0.125)
        precondition(lowerFadeIn.colors[0].peak > 0 && approximately(lowerFadeIn.colors[1].peak, 0))
        let upperFadeIn = dotBreatheRenderer.frame(at: (1.0 / 60) + 0.375)
        precondition(upperFadeIn.colors[0].peak > upperFadeIn.colors[1].peak)
        let lowerFadeOut = dotBreatheRenderer.frame(at: (1.0 / 60) + 0.625)
        precondition(lowerFadeOut.colors[1].peak > lowerFadeOut.colors[0].peak)
        let upperFadeOut = dotBreatheRenderer.frame(at: (1.0 / 60) + 0.875)
        precondition(approximately(upperFadeOut.colors[0].peak, 0) && upperFadeOut.colors[1].peak > 0)

        proMirrorAllocator.reset()
        dotMirrorAllocator.reset()
        let mirroredAgents = makeAgents(2, now: now)
        let splitPro = compiler.compile(
            profile: profile,
            agents: mirroredAgents,
            allocator: &proMirrorAllocator,
            ledCount: 8,
            now: now
        )
        let splitDot = compiler.compile(
            profile: profile,
            agents: mirroredAgents,
            allocator: &dotMirrorAllocator,
            ledCount: 2,
            now: now
        )
        precondition(splitPro.placementsTopToBottom.map(\.ledIndices.count) == [4, 4])
        precondition(splitDot.placementsTopToBottom.map(\.ledIndices.count) == [1, 1])
        precondition(splitDot.slots[0].agent?.id == splitPro.slots[0].agent?.id, "Bottom Dot must mirror the lower four Pro LEDs")
        precondition(splitDot.slots[1].agent?.id == splitPro.slots[7].agent?.id, "Top Dot must mirror the upper four Pro LEDs")

        precondition(capped.program.utf8.count <= 512, "Firmware program exceeds the device limit")
        precondition(capped.program.contains("repeat"), "Animated active scene must repeat")
        if ProcessInfo.processInfo.environment["SIDEPULSE_DUMP_PROGRAMS"] == "1" {
            dumpFirmwarePrograms(now: now, compiler: compiler)
        }
        print("Scene compiler smoke passed: configurable battery modes, device discovery, motion geometry, color modes, adaptive stable layouts")
    }

    private static func assertSimpleDisplayPolicy(
        now: Date,
        compiler: LightingSceneCompiler
    ) {
        var done = session("simple:done", updatedAt: now.addingTimeInterval(-4))
        done.state = .completed
        var thinking = session("simple:thinking", updatedAt: now.addingTimeInterval(-3))
        thinking.state = .working
        var tool = session("simple:tool", updatedAt: now.addingTimeInterval(-2))
        tool.state = .toolRunning
        var approval = session("simple:approval", updatedAt: now.addingTimeInterval(-1))
        approval.state = .waiting
        var failure = session("simple:failure", updatedAt: now)
        failure.state = .error

        precondition(AgentDisplayPolicy.aggregateState(for: [], mode: .simple) == .idle)
        precondition(AgentDisplayPolicy.lightingSessions(from: [], mode: .simple).isEmpty)
        precondition(AgentDisplayPolicy.aggregateState(for: [done], mode: .simple) == .completed)
        precondition(AgentDisplayPolicy.aggregateState(for: [done, tool], mode: .simple) == .working)
        precondition(AgentDisplayPolicy.aggregateState(for: [done, thinking, tool, approval], mode: .simple) == .waiting)
        precondition(AgentDisplayPolicy.aggregateState(for: [done, thinking, tool, approval, failure], mode: .simple) == .error)

        let source = [done, thinking, tool]
        let simple = AgentDisplayPolicy.lightingSessions(from: source, mode: .simple)
        precondition(simple.count == 1)
        precondition(simple[0].id == "sidepulse:simple-signal")
        precondition(simple[0].state == .working, "Tool activity must use Thinking in Simple mode")
        precondition(simple[0].toolName == nil)
        precondition(AgentDisplayPolicy.lightingSessions(from: source, mode: .perAgent) == source)

        var allocator = StableSlotAllocator()
        let scene = compiler.compile(
            profile: .factoryDefault,
            agents: simple,
            allocator: &allocator,
            ledCount: 8,
            now: now
        )
        precondition(scene.slots.count == 8)
        precondition(scene.slots.allSatisfy { $0.agent?.id == "sidepulse:simple-signal" })
        precondition(scene.placementsTopToBottom.count == 1)
        precondition(scene.placementsTopToBottom[0].ledIndices.count == 8)
        precondition(scene.program.contains("7:#6A1259"), "Simple Thinking must animate the full Pro array")
    }

    private static func dumpFirmwarePrograms(now: Date, compiler: LightingSceneCompiler) {
        for motion in LightMotion.allCases {
            for colorMode in LightColorMode.allCases {
                for agentCount in [1, 2] {
                    var allocator = StableSlotAllocator()
                    let scene = compiler.compile(
                        profile: profile(motion: motion, colorMode: colorMode),
                        agents: (0..<agentCount).map {
                            session("dump:\($0)", updatedAt: now.addingTimeInterval(Double(-$0)))
                        },
                        allocator: &allocator,
                        now: now
                    )
                    let data = Data(scene.program.utf8).base64EncodedString()
                    print("\(motion.rawValue)-\(colorMode.rawValue)-\(agentCount)\t\(data)")
                }
            }
        }
        for chargeFraction in [0.12, 0.45, 0.94] {
            for mode in BatteryIndicatorMode.allCases {
                let scene = SystemLightingScenes.batteryGauge(
                    chargeFraction: chargeFraction,
                    ledCount: 8,
                    mode: mode
                )
                print("battery-\(mode.rawValue)-\(chargeFraction)\t\(Data(scene.program.utf8).base64EncodedString())")
            }
        }
    }

    private static func assertMotionPrograms(now: Date, compiler: LightingSceneCompiler) {
        var programs: [LightMotion: String] = [:]
        for motion in LightMotion.allCases {
            var allocator = StableSlotAllocator()
            let scene = compiler.compile(
                profile: profile(motion: motion),
                agents: [session("motion:\(motion.rawValue)", updatedAt: now)],
                allocator: &allocator,
                now: now
            )
            precondition(scene.program.utf8.count <= 512, "\(motion.title) exceeds the firmware limit")
            programs[motion] = scene.program
        }

        precondition(programs[.off] == "off")
        precondition(programs[.solid]?.contains("0:#FF2BD6") == true)
        precondition(programs[.solid]?.contains("repeat") == false)
        precondition(programs[.flash]?.contains("0:#FF2BD6 1.3s none") == true)
        precondition(programs[.flash]?.contains("0:#000000 1.3s none") == true)

        precondition(programs[.pulse]?.contains("0:#FF2BD6 2.6s pulse") == true)

        let breatheProgram = programs[.breathe] ?? ""
        precondition(breatheProgram.contains("0:#FF2BD6 1.51s pulse"))
        precondition(breatheProgram.contains("7:#FF2BD6 1.51s pulse 1.09s"))

        let chaseLines = programs[.chase]?.split(separator: "\n").map(String.init) ?? []
        precondition(chaseLines.contains(where: { $0.contains("0:#FF2BD6 750ms pulse") && $0.contains("7:#FF2BD6 750ms pulse 550ms") }))
        precondition(chaseLines.contains(where: { $0.contains("0:#FF2BD6 750ms pulse 550ms") && $0.contains("7:#FF2BD6 750ms pulse") }))

        let converge = programs[.converge] ?? ""
        precondition(converge.contains("0:#FF2BD6 1.51s pulse;"))
        precondition(converge.contains("7:#FF2BD6 1.51s pulse"))
        precondition(converge.contains("3:#FF2BD6 1.51s pulse 1.09s"))

        let diverge = programs[.diverge] ?? ""
        precondition(diverge.contains("3:#FF2BD6 1.51s pulse;"))
        precondition(diverge.contains("4:#FF2BD6 1.51s pulse;"))
        precondition(diverge.contains("0:#FF2BD6 1.51s pulse 1.09s"))
    }

    private static func assertColorPrograms(now: Date, compiler: LightingSceneCompiler) {
        for colorMode in LightColorMode.allCases {
            var allocator = StableSlotAllocator()
            let scene = compiler.compile(
                profile: profile(motion: .solid, colorMode: colorMode),
                agents: [session("color:\(colorMode.rawValue)", updatedAt: now)],
                allocator: &allocator,
                now: now
            )
            precondition(scene.program.utf8.count <= 512, "\(colorMode.title) exceeds the firmware limit")
            switch colorMode {
            case .single:
                precondition(scene.program.contains("0:#FF2BD6") && scene.program.contains("7:#FF2BD6"))
            case .colorway:
                precondition(scene.program.contains("0:#FF2BD6") && scene.program.contains("7:#007AFF"))
            case .rainbow:
                precondition(
                    scene.program.contains("0:#FF1919") && scene.program.contains("4:#19FFFF"),
                    "Unexpected rainbow palette: \(scene.program)"
                )
            case .rotatingColorway:
                precondition(scene.program.contains("cosine") && scene.program.contains("repeat"))
            }
        }

        for motion in LightMotion.allCases where motion != .off {
            for colorMode in LightColorMode.allCases {
                var allocator = StableSlotAllocator()
                let scene = compiler.compile(
                    profile: profile(motion: motion, colorMode: colorMode),
                    agents: [session("matrix", updatedAt: now)],
                    allocator: &allocator,
                    now: now
                )
                precondition(scene.program.utf8.count <= 512)

                allocator.reset()
                let splitScene = compiler.compile(
                    profile: profile(motion: motion, colorMode: colorMode),
                    agents: [
                        session("matrix:a", updatedAt: now),
                        session("matrix:b", updatedAt: now.addingTimeInterval(-1)),
                    ],
                    allocator: &allocator,
                    now: now
                )
                precondition(splitScene.program.utf8.count <= 512)
            }
        }
    }

    private static func assertLegacyStyleDecoding() {
        let legacyBreathe = """
        {"state":"working","colorHex":"#FF2BD6","motion":"shimmer","cycleSeconds":2.6,"intensity":0.82}
        """.data(using: .utf8)!
        let decodedBreathe = try! JSONDecoder().decode(StateLightStyle.self, from: legacyBreathe)
        precondition(decodedBreathe.motion == .breathe)
        precondition(decodedBreathe.colorMode == .single)
        precondition(decodedBreathe.secondaryColorHex == "#7C3AED")

        let legacyPulseWaveBuild = """
        {"state":"working","colorHex":"#FF2BD6","motion":"solidFade","cycleSeconds":2.6,"intensity":0.82}
        """.data(using: .utf8)!
        let decodedPulse = try! JSONDecoder().decode(StateLightStyle.self, from: legacyPulseWaveBuild)
        precondition(decodedPulse.motion == .pulse)
    }

    private static func profile(
        motion: LightMotion,
        colorMode: LightColorMode = .single
    ) -> LightingProfile {
        var profile = LightingProfile.commandCenter
        var style = profile.style(for: .working)
        style.motion = motion
        style.colorMode = colorMode
        style.colorHex = "#FF2BD6"
        style.secondaryColorHex = "#007AFF"
        style.intensity = 1
        style.cycleSeconds = 2.6
        profile.deviceBrightness = 1
        profile.updateStyle(style)
        return profile
    }

    private static func assertProLayout(
        agentCount: Int,
        expectedOccupancy: [Int],
        now: Date,
        compiler: LightingSceneCompiler
    ) {
        var allocator = StableSlotAllocator()
        let scene = compiler.compile(
            profile: .commandCenter,
            agents: makeAgents(agentCount, now: now),
            allocator: &allocator,
            now: now
        )
        precondition(scene.placementsTopToBottom.map(\.ledIndices.count) == expectedOccupancy)
        precondition(scene.placementsTopToBottom.first?.ledIndices.max() == 7, "First resident must begin at physical LED 8")
        if agentCount == 3 {
            precondition(scene.slots.filter { $0.agent == nil }.count == 2, "Three agents must leave LEDs 2 and 1 off")
        }
    }

    private static func makeAgents(_ count: Int, now: Date) -> [AgentSession] {
        (0..<count).map { index in
            session("agent:\(index)", updatedAt: now.addingTimeInterval(Double(-index)))
        }
    }

    private static func session(_ id: String, updatedAt: Date) -> AgentSession {
        AgentSession(
            id: id,
            provider: .codex,
            sessionID: id,
            name: id,
            project: "SidePulse",
            cwd: nil,
            state: .working,
            eventName: "Smoke",
            toolName: nil,
            updatedAt: updatedAt,
            message: nil
        )
    }

    private static func approximately(_ value: Double, _ expected: Double) -> Bool {
        abs(value - expected) < 0.000_1
    }
}
