#if PEEL_HOST_INTEGRATION
import Foundation

/// A host-provided system-pressure signal that can take over an otherwise
/// idle local SidePulse display. It deliberately carries no sampler, process,
/// or agent state so it cannot become a second activity source.
enum SidePulseSystemPressureIndicator: Equatable, Sendable {
    case memoryWarning
    case memoryCritical
    case heldApp(String)

    var title: String {
        switch self {
        case .memoryWarning:
            return "Memory pressure"
        case .memoryCritical:
            return "Critical memory pressure"
        case .heldApp:
            return "App held"
        }
    }

    var detail: String {
        switch self {
        case .memoryWarning:
            return "System memory pressure is elevated."
        case .memoryCritical:
            return "System memory pressure is critical."
        case .heldApp(let name):
            let displayName = Self.displayName(for: name)
            return displayName.isEmpty
                ? "An app is paused in App Mechanic."
                : "\(displayName) is paused in App Mechanic."
        }
    }

    var colorHex: String {
        switch self {
        case .memoryWarning:
            return "#FF9F0A"
        case .memoryCritical, .heldApp:
            return "#FF453A"
        }
    }

    /// Slow pulses keep the warning visible without competing with an agent
    /// signal. A held app uses the critical cadence.
    var cycleMilliseconds: Int {
        switch self {
        case .memoryWarning:
            return 4_000
        case .memoryCritical:
            return 2_000
        case .heldApp:
            return 1_600
        }
    }

    private static func displayName(for value: String) -> String {
        let printableScalars = value.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
        let trimmed = String(String.UnicodeScalarView(printableScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(80))
    }
}
#endif
