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

        let profile = LightingProfile.commandCenter
        precondition(profile.style(for: .working).colorHex == "#FF2BD6")
        precondition(profile.style(for: .working).motion == .breathe)
        precondition(profile.style(for: .toolRunning).colorHex == "#00D5C8")
        precondition(profile.style(for: .waiting).colorHex == "#FFD60A")
        precondition(profile.style(for: .waiting).motion == .solid)
        precondition(profile.style(for: .completed).colorHex == "#30D158")
        precondition(profile.style(for: .completed).motion == .solid)
        precondition(profile.style(for: .error).colorHex == "#FF3B30")
        precondition(profile.style(for: .error).motion == .solid)
        precondition(!AgentState.allCases.contains(where: { $0.rawValue == "progress" }))

        var breatheAllocator = StableSlotAllocator()
        let breathe = compiler.compile(
            profile: profile,
            agents: [session("thinking", updatedAt: now)],
            allocator: &breatheAllocator,
            now: now
        )
        precondition(breathe.program.contains("\noff\n"), "Animated scenes must seed a dark base")
        precondition(breathe.program.contains("0:#D123AF 1.51s pulse"), "Thinking breathe must begin at LED 1")
        precondition(breathe.program.contains("7:#D123AF 1.51s pulse 1.09s"), "Thinking breathe must travel through LED 8")
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
        precondition(batteryGauge.program.hasPrefix("brightness 255\noff\n"))
        precondition(batteryGauge.program.contains("0:#FFFFFF 120ms cosine"))
        precondition(batteryGauge.program.contains("3:#FFFFFF 120ms cosine 378ms"))
        precondition(batteryGauge.program.contains("3:#FFFFFF 1s none"))
        precondition(batteryGauge.program.contains("4:#000000 1s none"), "Unfilled battery LEDs must remain off")
        precondition(batteryGauge.duration == 1.5, "Battery gauge must animate for 0.5s and hold for 1s")
        precondition(batteryGauge.program.utf8.count <= 512)

        let lowBattery = SystemLightingScenes.lowBatteryAlert(ledCount: 8)
        precondition(lowBattery.program.hasPrefix("brightness 255\noff\n"))
        precondition(lowBattery.program.contains("0:#30D158 120ms cosine"))
        precondition(lowBattery.program.contains("1:#30D158 120ms cosine 380ms"))
        precondition(lowBattery.program.contains("2:#260000 500ms cosine"))
        precondition(lowBattery.program.contains("1:#30D158 1s none"))
        precondition(lowBattery.program.contains("7:#260000 1s none"))
        precondition(lowBattery.duration == 1.5)
        precondition(lowBattery.program.utf8.count <= 512)

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

        precondition(capped.program.utf8.count <= 512, "Firmware program exceeds the device limit")
        precondition(capped.program.contains("repeat"), "Animated active scene must repeat")
        if ProcessInfo.processInfo.environment["SIDEPULSE_DUMP_PROGRAMS"] == "1" {
            dumpFirmwarePrograms(now: now, compiler: compiler)
        }
        print("Scene compiler smoke passed: battery lid gauge, low-battery alert, motion geometry, color modes, adaptive stable layouts")
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
            let scene = SystemLightingScenes.batteryGauge(chargeFraction: chargeFraction, ledCount: 8)
            print("battery-\(chargeFraction)\t\(Data(scene.program.utf8).base64EncodedString())")
        }
        let alert = SystemLightingScenes.lowBatteryAlert(ledCount: 8)
        print("battery-low\t\(Data(alert.program.utf8).base64EncodedString())")
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
}
