import Foundation

struct LEDProgramColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = LEDProgramColor(red: 0, green: 0, blue: 0)

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    var peak: Double { max(red, green, blue) }

    func scaled(by factor: Double) -> LEDProgramColor {
        let amount = max(0, min(1, factor))
        return LEDProgramColor(
            red: red * amount,
            green: green * amount,
            blue: blue * amount
        )
    }

    func mixed(with target: LEDProgramColor, amount: Double) -> LEDProgramColor {
        let progress = max(0, min(1, amount))
        return LEDProgramColor(
            red: red + ((target.red - red) * progress),
            green: green + ((target.green - green) * progress),
            blue: blue + ((target.blue - blue) * progress)
        )
    }

    fileprivate init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, let raw = Int(clean, radix: 16) else {
            self = .black
            return
        }
        red = Double((raw >> 16) & 0xFF) / 255
        green = Double((raw >> 8) & 0xFF) / 255
        blue = Double(raw & 0xFF) / 255
    }
}

struct LEDProgramFrame: Equatable, Sendable {
    var colors: [LEDProgramColor]
    var brightness: Double
}

/// Renders the same LEDS.LED program that was written to the physical device.
/// The app preview intentionally consumes firmware text instead of rebuilding a
/// separate approximation from profile settings.
struct LEDFirmwareProgram: Equatable, Sendable {
    private static let untimedFrameDuration = 1.0 / 60.0

    private enum Easing: String, Equatable, Sendable {
        case linear
        case ease
        case easeIn = "ease-in"
        case easeOut = "ease-out"
        case easeInOut = "ease-in-out"
        case cosine
        case pulse
        case none

        func amount(at progress: Double) -> Double {
            let value = max(0, min(1, progress))
            switch self {
            case .linear:
                return value
            case .ease:
                return value * value * (3 - (2 * value))
            case .easeIn:
                return value * value
            case .easeOut:
                return 1 - pow(1 - value, 2)
            case .easeInOut, .cosine:
                return 0.5 - (0.5 * cos(.pi * value))
            case .pulse:
                return 0.5 - (0.5 * cos(2 * .pi * value))
            case .none:
                return 1
            }
        }
    }

    private struct Assignment: Equatable, Sendable {
        var index: Int
        var target: LEDProgramColor
        var duration: TimeInterval
        var delay: TimeInterval
        var easing: Easing
        var isUntimed: Bool

        func color(from start: LEDProgramColor, elapsed: TimeInterval) -> LEDProgramColor {
            guard elapsed >= delay else { return start }
            if easing == .none { return target }
            let progress = duration <= 0 ? 1 : (elapsed - delay) / duration
            if easing == .pulse, progress >= 1 { return start }
            return start.mixed(with: target, amount: easing.amount(at: progress))
        }

        func finalColor(from start: LEDProgramColor) -> LEDProgramColor {
            easing == .pulse ? start : target
        }
    }

    private struct Step: Equatable, Sendable {
        var assignments: [Assignment]
        var duration: TimeInterval

        func colors(from start: [LEDProgramColor], elapsed: TimeInterval) -> [LEDProgramColor] {
            var result = start
            for assignment in assignments where result.indices.contains(assignment.index) {
                result[assignment.index] = assignment.color(
                    from: start[assignment.index],
                    elapsed: elapsed
                )
            }
            return result
        }

        func finalColors(from start: [LEDProgramColor]) -> [LEDProgramColor] {
            var result = start
            for assignment in assignments where result.indices.contains(assignment.index) {
                result[assignment.index] = assignment.finalColor(from: start[assignment.index])
            }
            return result
        }
    }

    private let ledCount: Int
    private let brightness: Double
    private let steps: [Step]
    private let repeats: Bool
    private let cycleDuration: TimeInterval

    var isRepeatingAnimation: Bool {
        repeats && cycleDuration > 0
    }

    func needsAnimationFrame(at elapsed: TimeInterval) -> Bool {
        isRepeatingAnimation || max(0, elapsed) < cycleDuration
    }

    init(program: String, ledCount: Int) {
        let count = max(1, min(8, ledCount))
        self.ledCount = count

        var parsedBrightness = 1.0
        var parsedSteps: [Step] = []
        var parsedRepeats = false

        for rawLine in program.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  !line.hasPrefix("//"),
                  !line.hasPrefix(";"),
                  !line.hasPrefix("# ")
            else { continue }

            if line.hasPrefix("brightness ") {
                let value = line.dropFirst("brightness ".count)
                    .trimmingCharacters(in: .whitespaces)
                parsedBrightness = Double(Int(value) ?? 255) / 255
                continue
            }
            if line == "repeat" || line.hasPrefix("repeat ") {
                parsedRepeats = true
                break
            }
            if let step = Self.parseStep(line, ledCount: count) {
                parsedSteps.append(step)
            }
        }

        brightness = max(0, min(1, parsedBrightness))
        steps = parsedSteps
        repeats = parsedRepeats
        cycleDuration = parsedSteps.reduce(0) { $0 + $1.duration }
    }

    func frame(at elapsed: TimeInterval) -> LEDProgramFrame {
        guard !steps.isEmpty else {
            return LEDProgramFrame(
                colors: Array(repeating: .black, count: ledCount),
                brightness: brightness
            )
        }

        var remaining = max(0, elapsed)
        if repeats, cycleDuration > 0 {
            remaining = remaining.truncatingRemainder(dividingBy: cycleDuration)
        }

        var colors = Array(repeating: LEDProgramColor.black, count: ledCount)
        for step in steps {
            if remaining < step.duration {
                colors = step.colors(from: colors, elapsed: remaining)
                return scaledFrame(colors)
            }
            colors = step.finalColors(from: colors)
            remaining -= step.duration
        }
        return scaledFrame(colors)
    }

    private func scaledFrame(_ colors: [LEDProgramColor]) -> LEDProgramFrame {
        LEDProgramFrame(
            colors: colors.map { $0.scaled(by: brightness) },
            brightness: brightness
        )
    }

    private static func parseStep(_ line: String, ledCount: Int) -> Step? {
        let rawSegments = line.split(separator: ";", omittingEmptySubsequences: true)
        var assignmentsByIndex: [Int: Assignment] = [:]

        for rawSegment in rawSegments {
            let segment = rawSegment.trimmingCharacters(in: .whitespaces)
            let tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let first = tokens.first else { continue }

            if first == "off" {
                let timing = parseTiming(Array(tokens.dropFirst()))
                for index in 0..<ledCount {
                    assignmentsByIndex[index] = assignment(
                        index: index,
                        color: .black,
                        timing: timing
                    )
                }
                continue
            }

            if first.hasPrefix("#"), rawSegments.count == 1 {
                let colors = tokens.prefix(while: { $0.hasPrefix("#") })
                if colors.count > 1 {
                    for (index, color) in colors.prefix(ledCount).enumerated() {
                        assignmentsByIndex[index] = assignment(
                            index: index,
                            color: LEDProgramColor(hex: color),
                            timing: .untimed
                        )
                    }
                } else {
                    let timing = parseTiming(Array(tokens.dropFirst()))
                    for index in 0..<ledCount {
                        assignmentsByIndex[index] = assignment(
                            index: index,
                            color: LEDProgramColor(hex: first),
                            timing: timing
                        )
                    }
                }
                continue
            }

            let target = first.split(separator: ":", maxSplits: 1).map(String.init)
            guard target.count == 2,
                  let index = Int(target[0]),
                  (0..<ledCount).contains(index)
            else { continue }
            assignmentsByIndex[index] = assignment(
                index: index,
                color: LEDProgramColor(hex: target[1]),
                timing: parseTiming(Array(tokens.dropFirst()))
            )
        }

        let assignments = assignmentsByIndex.values.sorted { $0.index < $1.index }
        guard !assignments.isEmpty else { return nil }
        let duration = assignments.map { assignment in
            assignment.delay + (assignment.isUntimed ? untimedFrameDuration : assignment.duration)
        }.max() ?? untimedFrameDuration
        return Step(assignments: assignments, duration: max(untimedFrameDuration, duration))
    }

    private struct Timing {
        var duration: TimeInterval
        var delay: TimeInterval
        var easing: Easing
        var isUntimed: Bool

        static let untimed = Timing(
            duration: 1.0 / 60.0,
            delay: 0,
            easing: .none,
            isUntimed: true
        )
    }

    private static func parseTiming(_ tokens: [String]) -> Timing {
        guard !tokens.isEmpty else { return .untimed }

        var easing: Easing?
        var times: [TimeInterval] = []
        for token in tokens {
            if let parsedEasing = Easing(rawValue: token) {
                easing = parsedEasing
            } else if let time = parseTime(token) {
                times.append(time)
            }
        }
        let duration = times.first ?? 0.33
        let delay = times.dropFirst().first ?? 0
        return Timing(
            duration: duration,
            delay: delay,
            easing: easing ?? .linear,
            isUntimed: false
        )
    }

    private static func parseTime(_ token: String) -> TimeInterval? {
        if token.hasSuffix("ms") {
            return Double(token.dropLast(2)).map { $0 / 1_000 }
        }
        if token.hasSuffix("s") {
            return Double(token.dropLast())
        }
        return nil
    }

    private static func assignment(
        index: Int,
        color: LEDProgramColor,
        timing: Timing
    ) -> Assignment {
        Assignment(
            index: index,
            target: color,
            duration: timing.duration,
            delay: timing.delay,
            easing: timing.easing,
            isUntimed: timing.isUntimed
        )
    }
}
