import Foundation

enum LEDProgramOutputCalibration {
    static func applying(
        to program: String,
        brightnessScale: Double,
        blueScale: Double,
        colorBalance: OutputColorBalance = .neutral
    ) -> String {
        let balance = colorBalance.normalized
        return scalingColors(
            in: scalingBrightness(in: program, by: brightnessScale),
            redScale: balance.red,
            greenScale: balance.green,
            blueScale: balance.blue * blueScale
        )
    }

    static func scalingBrightness(in program: String, by scale: Double) -> String {
        let clampedScale = max(0, min(1.5, scale))
        guard clampedScale != 1, program != "off" else { return program }

        var lines = program.components(separatedBy: "\n")
        if let brightnessIndex = lines.firstIndex(where: { $0.hasPrefix("brightness ") }),
           let brightness = Int(lines[brightnessIndex].dropFirst("brightness ".count)) {
            let calibrated = Int((Double(brightness) * clampedScale).rounded())
            lines[brightnessIndex] = "brightness \(max(0, min(255, calibrated)))"
        } else {
            let calibrated = Int((255 * clampedScale).rounded())
            lines.insert("brightness \(max(0, min(255, calibrated)))", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    static func settingBrightness(in program: String, to brightness: Int) -> String {
        guard program != "off" else { return program }
        let clampedBrightness = max(0, min(255, brightness))
        var lines = program.components(separatedBy: "\n")
        if let brightnessIndex = lines.firstIndex(where: { $0.hasPrefix("brightness ") }) {
            lines[brightnessIndex] = "brightness \(clampedBrightness)"
        } else {
            lines.insert("brightness \(clampedBrightness)", at: 0)
        }
        return lines.joined(separator: "\n")
    }

    static func scalingBlue(in program: String, by scale: Double) -> String {
        scalingColors(in: program, redScale: 1, greenScale: 1, blueScale: scale)
    }

    static func scalingColors(
        in program: String,
        redScale: Double,
        greenScale: Double,
        blueScale: Double
    ) -> String {
        let redScale = max(0, min(1.5, redScale))
        let greenScale = max(0, min(1.5, greenScale))
        let blueScale = max(0, min(1.5, blueScale))
        guard redScale != 1 || greenScale != 1 || blueScale != 1 else { return program }

        var result = ""
        var cursor = program.startIndex
        while let hash = program[cursor...].firstIndex(of: "#") {
            result += program[cursor..<hash]
            guard let end = program.index(hash, offsetBy: 7, limitedBy: program.endIndex) else {
                result += program[hash...]
                return result
            }
            let token = program[program.index(after: hash)..<end]
            guard token.count == 6,
                  token.allSatisfy({ $0.isHexDigit }),
                  let raw = Int(token, radix: 16)
            else {
                result.append("#")
                cursor = program.index(after: hash)
                continue
            }

            let red = Int((Double((raw >> 16) & 0xFF) * redScale).rounded())
            let green = Int((Double((raw >> 8) & 0xFF) * greenScale).rounded())
            let blue = Int((Double(raw & 0xFF) * blueScale).rounded())
            result += String(
                format: "#%02X%02X%02X",
                max(0, min(255, red)),
                max(0, min(255, green)),
                max(0, min(255, blue))
            )
            cursor = end
        }
        result += program[cursor...]
        return result
    }
}

enum FlashlightLighting {
    static let maximumFlashlightProgram = "brightness 255\n#FFFFFF"
    private static let maximumProgramBytes = 512
    private static let maximumProgramLines = 20

    static func applying(
        to program: String,
        mode: FlashlightMode,
        ledCount: Int = 8
    ) -> String {
        switch mode {
        case .overrideEverything:
            return maximumFlashlightProgram
        case .behindAnimations:
            let source = program.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "off"
                : program
            var lines = source
                .components(separatedBy: "\n")
                .map { replacingOffSegmentsWithWhite($0) }
            if let firstStepIndex = lines.firstIndex(where: { isLightingStep($0) }) {
                lines[firstStepIndex] = replacingBlackBaseColorsWithWhite(
                    lines[firstStepIndex]
                )
                if !hasFullInitialCoverage(lines[firstStepIndex], ledCount: ledCount) {
                    lines.insert("#FFFFFF", at: firstStepIndex)
                }
            } else {
                let repeatIndex = lines.firstIndex(where: { isRepeat($0) }) ?? lines.endIndex
                lines.insert("#FFFFFF", at: repeatIndex)
            }
            let result = LEDProgramOutputCalibration.settingBrightness(
                in: lines.joined(separator: "\n"),
                to: 255
            )
            guard result.utf8.count <= maximumProgramBytes,
                  result.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
                    <= maximumProgramLines
            else { return maximumFlashlightProgram }
            return result
        }
    }

    private static func replacingOffSegmentsWithWhite(_ line: String) -> String {
        line.split(separator: ";", omittingEmptySubsequences: false)
            .map { rawSegment in
                let segment = String(rawSegment)
                let leadingWhitespace = segment.prefix(while: \.isWhitespace)
                let body = segment.dropFirst(leadingWhitespace.count)
                guard body == "off" || body.hasPrefix("off ") else { return segment }
                return String(leadingWhitespace)
                    + "#FFFFFF"
                    + String(body.dropFirst("off".count))
            }
            .joined(separator: ";")
    }

    /// Black in an untimed base frame is physically the same as an off LED, so
    /// the flashlight underlay replaces it with white. Timed black animation
    /// targets remain untouched.
    private static func replacingBlackBaseColorsWithWhite(_ line: String) -> String {
        let segments = line.split(separator: ";", omittingEmptySubsequences: false)
        if segments.count == 1 {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard !tokens.isEmpty, tokens.allSatisfy({ isHexColor($0) }) else { return line }
            return tokens.map { $0 == "#000000" ? "#FFFFFF" : String($0) }
                .joined(separator: " ")
        }

        guard segments.count > 1,
              segments.allSatisfy({ segment in
                  let tokens = segment.split(whereSeparator: \.isWhitespace)
                  guard tokens.count == 1, let token = tokens.first,
                        let colon = token.firstIndex(of: ":")
                  else { return false }
                  let colorStart = token.index(after: colon)
                  return Int(token[..<colon]) != nil
                      && colorStart < token.endIndex
                      && token[colorStart] == "#"
              })
        else { return line }

        return segments.map { rawSegment in
            let segment = String(rawSegment)
            guard segment.hasSuffix(":#000000") else { return segment }
            return String(segment.dropLast("#000000".count)) + "#FFFFFF"
        }
        .joined(separator: ";")
    }

    private static func isHexColor(_ token: Substring) -> Bool {
        guard token.count == 7, token.first == "#" else { return false }
        return token.dropFirst().allSatisfy(\.isHexDigit)
    }

    private static func isLightingStep(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
            && !trimmed.hasPrefix("brightness ")
            && !trimmed.hasPrefix("//")
            && !trimmed.hasPrefix(";")
            && !trimmed.hasPrefix("# ")
            && !isRepeat(trimmed)
    }

    private static func isRepeat(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "repeat" || trimmed.hasPrefix("repeat ")
    }

    private static func hasFullInitialCoverage(_ line: String, ledCount: Int) -> Bool {
        let count = max(1, min(8, ledCount))
        let segments = line.split(separator: ";", omittingEmptySubsequences: true)
        guard !segments.isEmpty else { return false }
        if segments.count == 1 {
            let tokens = segments[0].split(whereSeparator: \.isWhitespace)
            guard let first = tokens.first else { return false }
            if first.hasPrefix("#") {
                let colorCount = tokens.prefix(while: { $0.hasPrefix("#") }).count
                return colorCount == 1 || colorCount >= count
            }
        }

        let coveredIndices = Set(segments.compactMap { segment -> Int? in
            guard let token = segment.split(whereSeparator: \.isWhitespace).first,
                  let colon = token.firstIndex(of: ":")
            else { return nil }
            return Int(token[..<colon])
        })
        return (0..<count).allSatisfy(coveredIndices.contains)
    }
}

struct AdaptiveOccupancyAllocator: Sendable {
    private(set) var residentOrder: [String] = []

    mutating func reset() {
        residentOrder.removeAll()
    }

    mutating func assign(_ agents: [AgentSession], ledCount: Int) -> [AgentLEDSlot] {
        let count = max(1, min(8, ledCount))
        let latest = Dictionary(agents.map { ($0.id, $0) }) { current, replacement in
            replacement.updatedAt > current.updatedAt ? replacement : current
        }
        let rankedIDs = latest.values.sorted { left, right in
            if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            if left.state.priority != right.state.priority { return left.state.priority < right.state.priority }
            return left.id < right.id
        }.map(\.id)

        let visible = Set(latest.keys)
        residentOrder.removeAll(where: { !visible.contains($0) })
        while residentOrder.count > count {
            guard let victim = residentOrder.indices.min(by: {
                let left = latest[residentOrder[$0]]?.updatedAt ?? .distantPast
                let right = latest[residentOrder[$1]]?.updatedAt ?? .distantPast
                return left < right
            }) else { break }
            residentOrder.remove(at: victim)
        }

        for candidate in rankedIDs where !residentOrder.contains(candidate) {
            if residentOrder.count < count {
                residentOrder.append(candidate)
                continue
            }
            guard let candidateSession = latest[candidate],
                  let victim = residentOrder.indices.min(by: {
                      let left = latest[residentOrder[$0]]?.updatedAt ?? .distantPast
                      let right = latest[residentOrder[$1]]?.updatedAt ?? .distantPast
                      return left < right
                  }),
                  let victimSession = latest[residentOrder[victim]],
                  candidateSession.updatedAt > victimSession.updatedAt
            else { continue }
            residentOrder[victim] = candidate
        }

        let selected = residentOrder.compactMap { latest[$0] }
        var result = (0..<count).map { AgentLEDSlot(index: $0, agent: nil) }
        guard !selected.isEmpty else { return result }

        let blockSize: Int
        if count == 8 {
            switch selected.count {
            case 1: blockSize = 8
            case 2: blockSize = 4
            case 3...4: blockSize = 2
            default: blockSize = 1
            }
        } else if count == 2 {
            blockSize = selected.count == 1 ? 2 : 1
        } else {
            blockSize = selected.count == 1 ? count : max(1, count / selected.count)
        }

        var cursor = count - 1
        for agent in selected {
            for _ in 0..<blockSize where cursor >= 0 {
                result[cursor].agent = agent
                cursor -= 1
            }
        }
        return result
    }
}

struct StableSlotAllocator: Sendable {
    private(set) var assignments: [String: Int] = [:]
    private(set) var lastSeen: [String: Date] = [:]
    private var adaptiveAllocator = AdaptiveOccupancyAllocator()
    var reservationSeconds: TimeInterval = 300

    mutating func reset() {
        assignments.removeAll()
        lastSeen.removeAll()
        adaptiveAllocator.reset()
    }

    mutating func assignAdaptive(_ agents: [AgentSession], ledCount: Int) -> [AgentLEDSlot] {
        adaptiveAllocator.assign(agents, ledCount: ledCount)
    }

    mutating func assign(_ agents: [AgentSession], ledCount: Int, now: Date = .now) -> [AgentLEDSlot] {
        let count = max(1, min(8, ledCount))
        let latest = Dictionary(agents.map { ($0.id, $0) }) { current, replacement in
            replacement.updatedAt > current.updatedAt ? replacement : current
        }
        let visible = Set(latest.keys)
        for key in visible { lastSeen[key] = now }

        for key in Array(assignments.keys) where !visible.contains(key) {
            if now.timeIntervalSince(lastSeen[key] ?? .distantPast) >= reservationSeconds {
                assignments[key] = nil
                lastSeen[key] = nil
            }
        }

        var selected = assignments
            .filter { visible.contains($0.key) }
            .sorted { $0.value < $1.value }
            .map(\.key)
        let newcomers = visible.filter { assignments[$0] == nil }.sorted { lhs, rhs in
            guard let left = latest[lhs], let right = latest[rhs] else { return lhs < rhs }
            if left.state.priority != right.state.priority { return left.state.priority < right.state.priority }
            if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
            return lhs < rhs
        }
        selected.append(contentsOf: newcomers)
        selected = Array(selected.prefix(count))

        for key in selected where assignments[key] == nil {
            let used = Set(assignments.values)
            if let free = (0..<count).first(where: { !used.contains($0) }) {
                assignments[key] = free
            } else if let victim = assignments.keys
                .filter({ !visible.contains($0) })
                .min(by: { (lastSeen[$0] ?? .distantPast) < (lastSeen[$1] ?? .distantPast) }),
                let slot = assignments.removeValue(forKey: victim) {
                lastSeen[victim] = nil
                assignments[key] = slot
            }
        }

        var result = (0..<count).map { AgentLEDSlot(index: $0, agent: nil) }
        for key in selected {
            guard let index = assignments[key], let agent = latest[key], index < result.count else { continue }
            result[index].agent = agent
        }
        return result
    }
}

struct LightingSceneCompiler: Sendable {
    static let dotDirectionalBreatheCycleSeconds: TimeInterval = 1

    private struct RenderedSlot {
        var index: Int
        var style: StateLightStyle
        var position: Int
        var count: Int
    }

    func compile(
        profile: LightingProfile,
        agents: [AgentSession],
        allocator: inout StableSlotAllocator,
        ledCount: Int = 8,
        now: Date = .now
    ) -> CompiledScene {
        var arranged = agents
        switch profile.strategy {
        case .adaptiveOccupancy:
            break
        case .stableAgents:
            break
        case .providerLanes:
            arranged.sort {
                $0.provider.rawValue == $1.provider.rawValue
                    ? $0.updatedAt > $1.updatedAt
                    : $0.provider.rawValue < $1.provider.rawValue
            }
        case .priorityStack:
            arranged.sort {
                $0.state.priority == $1.state.priority
                    ? $0.updatedAt > $1.updatedAt
                    : $0.state.priority < $1.state.priority
            }
            allocator.reset()
        }

        let slots: [AgentLEDSlot]
        if profile.strategy == .adaptiveOccupancy {
            slots = allocator.assignAdaptive(arranged, ledCount: ledCount)
        } else {
            slots = allocator.assign(arranged, ledCount: ledCount, now: now)
        }
        guard slots.contains(where: { $0.agent != nil }) else {
            return CompiledScene(program: "off", slots: slots)
        }

        var indicesByAgent: [String: [Int]] = [:]
        for slot in slots {
            guard let agent = slot.agent else { continue }
            indicesByAgent[agent.id, default: []].append(slot.index)
        }
        for key in indicesByAgent.keys {
            indicesByAgent[key]?.sort()
        }

        let rendered = slots.compactMap { slot -> RenderedSlot? in
            guard let agent = slot.agent,
                  let indices = indicesByAgent[agent.id],
                  let position = indices.firstIndex(of: slot.index)
            else { return nil }
            return RenderedSlot(
                index: slot.index,
                style: profile.style(for: agent.state),
                position: position,
                count: indices.count
            )
        }

        let needsSecondPhase = rendered.contains { slot in
            slot.style.colorMode == .rotatingColorway
                || slot.style.motion == .flash
                || (slot.style.motion == .chase && slot.count > 1)
        }
        let renderedByIndex = Dictionary(uniqueKeysWithValues: rendered.map { ($0.index, $0) })
        let baseSegments = slots.map { slot -> String in
            guard let renderedSlot = renderedByIndex[slot.index] else { return "\(slot.index):#000000" }
            let style = renderedSlot.style
            switch style.motion {
            case .solid:
                return "\(slot.index):\(color(for: renderedSlot, phase: 0))"
            default:
                return "\(slot.index):#000000"
            }
        }
        let baseLine = baseSegments.allSatisfy({ $0.hasSuffix("#000000") })
            ? "off"
            : baseSegments.joined(separator: ";")

        let phaseOne = rendered.compactMap {
            animatedSegment(for: $0, phase: 1, reverse: false, splitCycle: needsSecondPhase)
        }
        let phaseTwo = needsSecondPhase ? rendered.compactMap {
            animatedSegment(for: $0, phase: 2, reverse: true, splitCycle: true)
        } : []
        let dotDirectionalBreathe = dotDirectionalBreatheLines(
            for: rendered,
            agentCount: indicesByAgent.count,
            ledCount: ledCount
        )
        let animated = dotDirectionalBreathe != nil || !phaseOne.isEmpty || !phaseTwo.isEmpty
        var lines: [String] = []
        let brightness = Int(max(0, min(1, profile.deviceBrightness)) * 255)
        if brightness < 255 { lines.append("brightness \(brightness)") }
        lines.append(baseLine)
        if animated {
            if let dotDirectionalBreathe {
                lines.append(contentsOf: dotDirectionalBreathe)
            } else {
                if !phaseOne.isEmpty { lines.append(phaseOne.joined(separator: ";")) }
                if !phaseTwo.isEmpty { lines.append(phaseTwo.joined(separator: ";")) }
            }
            lines.append("repeat")
        }
        let program = lines.joined(separator: "\n")
        precondition(program.utf8.count <= 512, "Compiled LED program exceeds the firmware limit")
        return CompiledScene(program: program, slots: slots)
    }

    private func dotDirectionalBreatheLines(
        for rendered: [RenderedSlot],
        agentCount: Int,
        ledCount: Int
    ) -> [String]? {
        guard ledCount == 2,
              agentCount == 1,
              rendered.count == 2,
              rendered.allSatisfy({
                  $0.style.motion == .breathe && $0.style.colorMode != .rotatingColorway
              })
        else { return nil }

        let ordered = rendered.sorted { $0.index < $1.index }
        let lower = ordered[0]
        let upper = ordered[1]
        let step = Self.dotDirectionalBreatheCycleSeconds / 4
        return [
            "\(lower.index):\(color(for: lower, phase: 0)) \(time(step)) cosine",
            "\(upper.index):\(color(for: upper, phase: 0)) \(time(step)) cosine",
            "\(lower.index):#000000 \(time(step)) cosine",
            "\(upper.index):#000000 \(time(step)) cosine",
        ]
    }

    private func animatedSegment(
        for slot: RenderedSlot,
        phase: Int,
        reverse: Bool,
        splitCycle: Bool
    ) -> String? {
        let style = slot.style
        guard style.motion.isAnimated || (style.motion == .solid && style.colorMode == .rotatingColorway) else {
            return nil
        }

        let cycle = max(0.2, min(30, style.cycleSeconds)) / (splitCycle ? 2 : 1)
        let targetPhase = style.colorMode == .rotatingColorway ? phase : 0
        let color = color(for: slot, phase: targetPhase)

        switch style.motion {
        case .off:
            return nil
        case .solid:
            let target = phase == 2 ? self.color(for: slot, phase: 0) : color
            return "\(slot.index):\(target) \(time(cycle)) cosine"
        case .flash:
            let target = phase == 2 ? "#000000" : color
            return "\(slot.index):\(target) \(time(cycle)) none"
        case .pulse:
            return pulseSegment(index: slot.index, color: color, duration: cycle, delay: 0)
        case .breathe:
            return travelingSegment(for: slot, color: color, total: cycle, step: slot.position)
        case .chase:
            let step = reverse ? slot.count - 1 - slot.position : slot.position
            return travelingSegment(for: slot, color: color, total: cycle, step: step)
        case .converge:
            let step = min(slot.position, slot.count - 1 - slot.position)
            return travelingSegment(for: slot, color: color, total: cycle, step: step)
        case .diverge:
            let leftCenter = (slot.count - 1) / 2
            let rightCenter = slot.count / 2
            let step = min(abs(slot.position - leftCenter), abs(slot.position - rightCenter))
            return travelingSegment(for: slot, color: color, total: cycle, step: step)
        }
    }

    private func travelingSegment(
        for slot: RenderedSlot,
        color: String,
        total: Double,
        step: Int
    ) -> String {
        let maxStep: Int
        switch slot.style.motion {
        case .converge:
            maxStep = max(0, (slot.count - 1) / 2)
        case .diverge:
            maxStep = max(0, (slot.count - 1) / 2)
        default:
            maxStep = max(0, slot.count - 1)
        }
        guard maxStep > 0 else {
            return pulseSegment(index: slot.index, color: color, duration: total, delay: 0)
        }
        let duration = max(0.16, total * 0.58)
        let delay = max(0, total - duration) * Double(step) / Double(maxStep)
        return pulseSegment(index: slot.index, color: color, duration: duration, delay: delay)
    }

    private func pulseSegment(index: Int, color: String, duration: Double, delay: Double) -> String {
        var segment = "\(index):\(color) \(time(duration)) pulse"
        if delay >= 0.005 { segment += " \(time(delay))" }
        return segment
    }

    private func color(for slot: RenderedSlot, phase: Int) -> String {
        let style = slot.style
        let primary = rgb(style.colorHex)
        let secondary = rgb(style.secondaryColorHex)
        let value: (Double, Double, Double)
        switch style.colorMode {
        case .single:
            value = primary
        case .colorway:
            let amount = slot.count <= 1 ? 0 : Double(slot.position) / Double(slot.count - 1)
            value = interpolate(primary, secondary, amount: amount)
        case .rainbow:
            let divisor = Double(max(2, slot.count))
            let offset = slot.count <= 1 ? Double(slot.index) / 8 : Double(slot.position) / divisor
            value = hsv(hue: offset, saturation: 0.9, value: 1)
        case .rotatingColorway:
            if slot.count <= 1 {
                value = phase.isMultiple(of: 2) ? primary : secondary
            } else {
                let offset = Double((slot.position + phase) % slot.count) / Double(slot.count)
                let amount = 1 - abs((offset * 2) - 1)
                value = interpolate(primary, secondary, amount: amount)
            }
        }
        return hex(value, factor: style.intensity)
    }

    private func rgb(_ value: String) -> (Double, Double, Double) {
        let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, let raw = Int(clean, radix: 16) else { return (1, 1, 1) }
        return (
            Double((raw >> 16) & 0xFF) / 255,
            Double((raw >> 8) & 0xFF) / 255,
            Double(raw & 0xFF) / 255
        )
    }

    private func interpolate(
        _ first: (Double, Double, Double),
        _ second: (Double, Double, Double),
        amount: Double
    ) -> (Double, Double, Double) {
        let t = max(0, min(1, amount))
        return (
            first.0 + ((second.0 - first.0) * t),
            first.1 + ((second.1 - first.1) * t),
            first.2 + ((second.2 - first.2) * t)
        )
    }

    private func hsv(hue: Double, saturation: Double, value: Double) -> (Double, Double, Double) {
        let h = (hue - floor(hue)) * 6
        let i = Int(floor(h))
        let fraction = h - floor(h)
        let p = value * (1 - saturation)
        let q = value * (1 - (saturation * fraction))
        let t = value * (1 - (saturation * (1 - fraction)))
        switch i % 6 {
        case 0: return (value, t, p)
        case 1: return (q, value, p)
        case 2: return (p, value, t)
        case 3: return (p, q, value)
        case 4: return (t, p, value)
        default: return (value, p, q)
        }
    }

    private func hex(_ value: (Double, Double, Double), factor: Double) -> String {
        let amount = max(0, min(1, factor))
        let red = Int((max(0, min(1, value.0)) * amount * 255).rounded())
        let green = Int((max(0, min(1, value.1)) * amount * 255).rounded())
        let blue = Int((max(0, min(1, value.2)) * amount * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private func time(_ seconds: Double) -> String {
        let milliseconds = max(1, Int((seconds * 1_000 / 10).rounded()) * 10)
        if milliseconds.isMultiple(of: 1_000) { return "\(milliseconds / 1_000)s" }
        if milliseconds >= 1_000 {
            let value = String(format: "%.2f", Double(milliseconds) / 1_000)
                .replacingOccurrences(of: "0$", with: "", options: .regularExpression)
            return "\(value)s"
        }
        return "\(milliseconds)ms"
    }
}

struct TimedLightingScene: Equatable, Sendable {
    var program: String
    var duration: TimeInterval
}

enum SystemLightingScenes {
    private static let fillMilliseconds = 500
    private static let batteryHoldMilliseconds = 1_500
    private static let batteryGreen = "#66FF5F"
    private static let batteryOrange = "#FF9F0A"
    private static let batteryRed = "#FF3B30"
    private static let batteryRemainder = "#4D4D4D"

    static func illuminatedLEDCount(chargeFraction: Double, ledCount: Int) -> Int {
        let count = max(1, min(8, ledCount))
        let normalized = max(0, min(1, chargeFraction))
        let step = 1 / Double(count)
        let rounded = Int(floor((normalized + (step / 2)) / step))
        return max(1, min(count, rounded))
    }

    static func batteryGauge(
        chargeFraction: Double,
        ledCount: Int,
        mode: BatteryIndicatorMode = .levelColorOutline,
        lowBatteryThresholdPercent: Int = 25
    ) -> TimedLightingScene {
        let count = max(1, min(8, ledCount))
        if mode == .statusArray || mode == .statusBottom {
            return statusScene(
                chargeFraction: chargeFraction,
                ledCount: count,
                mode: mode,
                lowBatteryThresholdPercent: lowBatteryThresholdPercent
            )
        }

        let illuminated = illuminatedLEDCount(chargeFraction: chargeFraction, ledCount: count)
        let litColors = (0..<illuminated).map { index in
            (
                index: index,
                color: barColor(
                    at: index,
                    illuminated: illuminated,
                    ledCount: count,
                    mode: mode
                )
            )
        }
        let remainder = remainderColor(for: mode)
        let sweep = fillSegments(litColors)
        let hold = (0..<count).map { index in
            let color = litColors.first(where: { $0.index == index })?.color ?? remainder
            return "\(index):\(color) \(batteryHoldMilliseconds)ms none"
        }
        let program = [
            "brightness 255",
            remainder == "#000000" ? "off" : remainder,
            sweep.joined(separator: ";"),
            hold.joined(separator: ";"),
        ].joined(separator: "\n")
        precondition(program.utf8.count <= 512, "Battery gauge exceeds the firmware limit")
        return TimedLightingScene(
            program: program,
            duration: Double(fillMilliseconds + batteryHoldMilliseconds) / 1_000
        )
    }

    private static func statusScene(
        chargeFraction: Double,
        ledCount: Int,
        mode: BatteryIndicatorMode,
        lowBatteryThresholdPercent: Int
    ) -> TimedLightingScene {
        let threshold = Double(max(5, min(100, lowBatteryThresholdPercent))) / 100
        let color = chargeFraction <= threshold ? batteryOrange : batteryGreen
        let durationMilliseconds = fillMilliseconds + batteryHoldMilliseconds
        let status = mode == .statusBottom
            ? "0:\(color) \(durationMilliseconds / 1_000)s none"
            : "\(color) \(durationMilliseconds / 1_000)s none"
        let program = ["brightness 255", "off", status].joined(separator: "\n")
        precondition(program.utf8.count <= 512, "Battery status exceeds the firmware limit")
        return TimedLightingScene(
            program: program,
            duration: Double(durationMilliseconds) / 1_000
        )
    }

    private static func barColor(
        at index: Int,
        illuminated: Int,
        ledCount: Int,
        mode: BatteryIndicatorMode
    ) -> String {
        switch mode {
        case .levelColorOutline, .levelColor:
            batteryLevelColor(illuminated: illuminated, ledCount: ledCount)
        case .greenOutline, .green:
            batteryGreen
        case .splitGreenOrange:
            index < max(1, ledCount / 2) ? batteryGreen : batteryOrange
        case .statusArray, .statusBottom:
            batteryGreen
        }
    }

    private static func remainderColor(for mode: BatteryIndicatorMode) -> String {
        switch mode {
        case .levelColorOutline, .greenOutline: batteryRemainder
        case .levelColor, .green, .splitGreenOrange, .statusArray, .statusBottom: "#000000"
        }
    }

    private static func batteryLevelColor(illuminated: Int, ledCount: Int) -> String {
        let count = max(1, ledCount)
        if illuminated * 8 >= count * 5 { return batteryGreen }
        if illuminated * 8 >= count * 3 { return batteryOrange }
        return batteryRed
    }

    private static func fillSegments(
        _ assignments: [(index: Int, color: String)]
    ) -> [String] {
        guard !assignments.isEmpty else { return [] }
        let transitionMilliseconds = assignments.count == 1 ? fillMilliseconds : 120
        let staggerMilliseconds = assignments.count == 1
            ? 0
            : (fillMilliseconds - transitionMilliseconds) / (assignments.count - 1)
        return assignments.enumerated().map { position, assignment in
            let delay = position * staggerMilliseconds
            return delay == 0
                ? "\(assignment.index):\(assignment.color) \(transitionMilliseconds)ms cosine"
                : "\(assignment.index):\(assignment.color) \(transitionMilliseconds)ms cosine \(delay)ms"
        }
    }
}
