import SwiftUI

/// The lightweight interactive surface that expands below the native LED
/// stripe. The panel that owns this view is responsible for hover detection,
/// placement, and any presentation animation.
struct NotchIslandView: View {
    @Bindable var store: CommandCenterStore

    let openAgent: (AgentSession) -> Void
    let openCommandCenter: () -> Void
    let togglePower: () -> Void

    static func contentHeight(agentCount: Int) -> CGFloat {
        let count = max(0, agentCount)
        if count == 0 { return 130 }
        return CGFloat(81 + count * 37)
    }

    private static let fixedChromeHeight: CGFloat = 82
    private static let emptyStateHeight: CGFloat = 48
    private static let agentRowHeight: CGFloat = 34
    private static let agentRowSpacing: CGFloat = 3

    private var drivingAgents: [AgentSession] {
        store.notchDrivingAgents
    }

    private var statusColor: Color {
        guard let agent = drivingAgents.first else {
            if store.outputPowerIsOn, store.displayedUtilityMode == .microphone {
                return Color(hex: store.onAirStyle?.colorHex ?? "#FF9F0A")
            }
            return store.outputPowerIsOn ? .white : .orange
        }
        return color(for: agent)
    }

    private var keepAwakeTint: Color {
        Color(red: 0.96, green: 0.63, blue: 0.2)
    }

    private var keepAwakeHelp: String {
        let status = store.keepAwakeStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty { return status }
        return store.keepAwakeEnabled ? "Turn off Keep Awake" : "Turn on Keep Awake"
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 4) {
                statusHeader

                if drivingAgents.isEmpty {
                    emptyState
                } else {
                    agentList(availableHeight: proxy.size.height)
                }

                Spacer(minLength: 0)
                actionBar
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: 0, alignment: .topLeading)
        .background(Color.black, in: .rect(cornerRadius: 14))
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
    }

    private var statusHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .shadow(color: statusColor.opacity(0.5), radius: 3)

            VStack(alignment: .leading, spacing: 0) {
                Text(store.notchStatusTitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                Text(drivingAgents.isEmpty ? (store.utilityStatusTitle == nil ? "Live LED status" : store.utilityStatusDetail) : store.notchStatusDetail)
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            Button(action: store.toggleKeepAwake) {
                Image(systemName: store.keepAwakeEnabled ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(store.keepAwakeEnabled ? keepAwakeTint : .white.opacity(0.5))
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NotchIslandActionStyle(tint: keepAwakeTint))
            .help(keepAwakeHelp)
            .accessibilityLabel("Keep Awake")
            .accessibilityValue(store.keepAwakeEnabled ? "On" : "Off")
        }
        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 24)
    }

    @ViewBuilder
    private func agentList(availableHeight: CGFloat) -> some View {
        let naturalListHeight = Self.agentListHeight(agentCount: drivingAgents.count)
        let availableListHeight = max(0, availableHeight - Self.fixedChromeHeight)

        if availableListHeight + 0.5 < naturalListHeight {
            ScrollView(.vertical) {
                agentRows
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity)
            .frame(height: availableListHeight)
        } else {
            agentRows
        }
    }

    @ViewBuilder
    private var agentRows: some View {
        VStack(spacing: Self.agentRowSpacing) {
            ForEach(drivingAgents) { agent in
                agentRow(agent)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private static func agentListHeight(agentCount: Int) -> CGFloat {
        let count = max(0, agentCount)
        guard count > 0 else { return 0 }
        return CGFloat(count) * agentRowHeight
            + CGFloat(max(0, count - 1)) * agentRowSpacing
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: emptyStateSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
                .frame(width: 18, height: 18)

            Text(store.notchStatusDetail)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: Self.emptyStateHeight, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(store.notchStatusDetail)
    }

    private func agentRow(_ agent: AgentSession) -> some View {
        NotchIslandAgentRow(
            agent: agent,
            color: color(for: agent),
            action: { openAgent(agent) }
        )
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button(action: openCommandCenter) {
                Label("Command Center", systemImage: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(NotchIslandActionStyle(tint: .white))
            .foregroundStyle(.white.opacity(0.86))
            .accessibilityLabel("Open Command Center")

            Button(action: togglePower) {
                Label(
                    store.outputPowerIsOn ? "Power Off" : "Power On",
                    systemImage: store.outputPowerIsOn ? "power" : "power.circle"
                )
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(NotchIslandActionStyle(tint: store.outputPowerIsOn ? .red : .green))
            .foregroundStyle(store.outputPowerIsOn ? .red : .green)
            .accessibilityLabel(store.outputPowerIsOn ? "Power Off" : "Power On")
            .accessibilityValue(store.outputPowerIsOn ? "On" : "Off")
        }
        .frame(maxWidth: .infinity).frame(height: 28)
    }

    private var emptyStateSymbol: String {
        if !store.outputPowerIsOn { return "power" }
        switch store.displayedUtilityMode {
        case .agents: return "moon.stars"
        case .microphone: return store.onAirSymbol
        case .timer: return store.timerState.isActive ? "timer" : "moon.stars"
        case .progress: return "chart.bar"
        }
    }

    private func color(for agent: AgentSession) -> Color {
        let state = store.agentDisplayMode == .simple && agent.state == .toolRunning ? AgentState.working : agent.state
        return Color(hex: store.selectedProfile.style(for: state).colorHex)
    }
}

private struct NotchIslandActionStyle: ButtonStyle {
    let tint: Color
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(tint.opacity(configuration.isPressed ? 0.3 : (isHovered ? 0.22 : 0.12)),
                        in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(tint.opacity(isHovered ? 0.3 : 0), lineWidth: 1)
            }
            .onHover { isHovered = $0 }
    }
}

private struct NotchIslandAgentRow: View {
    let agent: AgentSession
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    private var displayName: String {
        agent.name.isEmpty ? agent.provider.title : agent.name
    }

    private var detail: String {
        let subtitle = agent.subtitle
        return subtitle.isEmpty ? agent.provider.title : subtitle
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 4, height: 14)

                VStack(alignment: .leading, spacing: 0) {
                    Text(displayName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)

                    Text(detail)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                Text(agent.state.title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(isHovered ? 0.82 : 0.4))
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            color.opacity(isHovered ? 0.19 : 0.075),
            in: .rect(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.white.opacity(isHovered ? 0.16 : 0.04), lineWidth: 1)
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel("Open \(displayName)")
        .accessibilityValue("\(agent.state.title), \(agent.subtitle)")
    }
}
