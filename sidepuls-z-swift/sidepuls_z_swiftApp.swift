import AppKit
import SwiftUI

@main
struct SidePulseCommandCenterApp: App {
    @State private var store = CommandCenterStore()

    var body: some Scene {
        WindowGroup("SidePulse Command Center", id: "command-center") {
            ContentView(store: store)
        }
        .defaultSize(width: 1_180, height: 780)

        MenuBarExtra {
            SidePulseMenuBarView(store: store)
        } label: {
            SidePulseMenuBarIcon(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct SidePulseMenuBarIcon: View {
    @Bindable var store: CommandCenterStore

    @ViewBuilder
    var body: some View {
        switch store.menuBarIconStyle {
        case .horizontalEight:
            HStack(spacing: 0.9) {
                ForEach(Array(groups(for: .horizontalEight).enumerated()), id: \.offset) { _, group in
                    dot(for: group, diameter: 2.35)
                }
            }
            .frame(minWidth: 26, minHeight: 14)
            .accessibilityLabel("SidePulse, \(store.aggregateState.title), eight horizontal dots")
        case .verticalEight:
            VStack(spacing: 0.32) {
                ForEach(Array(groups(for: .verticalEight).enumerated()), id: \.offset) { _, group in
                    dot(for: group, diameter: 1.45)
                }
            }
            .frame(minWidth: 14, minHeight: 16)
            .accessibilityLabel("SidePulse, \(store.aggregateState.title), eight vertical dots")
        case .mirroredFour:
            HStack(spacing: 1.25) {
                ForEach(Array(groups(for: .mirroredFour).enumerated()), id: \.offset) { _, group in
                    dot(for: group, diameter: 3.35)
                }
            }
            .frame(minWidth: 19, minHeight: 14)
            .accessibilityLabel("SidePulse, \(store.aggregateState.title), four mirrored dots")
        case .stateSymbol:
            Image(systemName: store.aggregateState.symbol)
                .accessibilityLabel("SidePulse, \(store.aggregateState.title)")
        }
    }

    private func groups(for style: MenuBarIconStyle) -> [[Int]] {
        MenuBarDotLayout.sourceIndices(for: style, ledCount: store.device.ledCount)
    }

    private func dot(for indices: [Int], diameter: CGFloat) -> some View {
        let slot = representativeSlot(for: indices)
        let color = slot.flatMap(\.agent).map {
            Color(hex: store.selectedProfile.style(for: $0.state).colorHex)
        } ?? Color.primary.opacity(0.18)
        return Circle()
            .fill(color)
            .overlay {
                Circle().stroke(.primary.opacity(slot?.agent == nil ? 0.22 : 0.12), lineWidth: 0.35)
            }
            .frame(width: diameter, height: diameter)
            .accessibilityHidden(true)
    }

    private func representativeSlot(for indices: [Int]) -> AgentLEDSlot? {
        let candidates = indices.compactMap { index in
            store.scene.slots.first(where: { $0.index == index })
        }
        let populated = candidates.filter { $0.agent != nil }
        return populated.min { left, right in
            guard let leftAgent = left.agent, let rightAgent = right.agent else { return false }
            if leftAgent.state.priority != rightAgent.state.priority {
                return leftAgent.state.priority < rightAgent.state.priority
            }
            return leftAgent.updatedAt > rightAgent.updatedAt
        } ?? candidates.first
    }
}

struct SidePulseMenuBarView: View {
    @Bindable var store: CommandCenterStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "lightbulb.led.wide.fill").foregroundStyle(.cyan)
                Text("SidePulse").font(.headline)
                Spacer()
                Text(store.aggregateState.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Picker("Signal Mode", selection: Binding(
                get: { store.agentDisplayMode },
                set: { store.selectAgentDisplayMode($0) }
            )) {
                ForEach(AgentDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Label("Menu Bar Icon", systemImage: "menubar.rectangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Menu Bar Icon", selection: Binding(
                    get: { store.menuBarIconStyle },
                    set: { store.selectMenuBarIconStyle($0) }
                )) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 7) {
                    ForEach(store.scene.slots.sorted(by: { $0.index > $1.index })) { slot in
                        HStack(spacing: 7) {
                            Text("\(slot.index + 1)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 12, alignment: .trailing)
                            Circle().fill(slotColor(slot)).frame(width: 15, height: 15)
                        }
                    }
                }
                if store.agentDisplayMode == .simple {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ONE SIGNAL · FULL ARRAY")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        HStack(spacing: 9) {
                            Image(systemName: store.aggregateState.symbol)
                                .font(.title3)
                                .frame(width: 24)
                            Text(store.aggregateState.title)
                                .font(.headline)
                        }
                        Text("Highest-priority state across \(store.agents.count) detected session\(store.agents.count == 1 ? "" : "s").")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Failure → Approval → Thinking → Done")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("Tool activity is included in Thinking.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PHYSICAL ARRAY · TOP TO BOTTOM")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        if store.scene.placementsTopToBottom.isEmpty {
                            Text("No sessions on the array · lights off")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(store.scene.placementsTopToBottom) { placement in
                                Button {
                                    if placement.agent.openURL == nil {
                                        openWindow(id: "command-center")
                                        NSApp.activate(ignoringOtherApps: true)
                                    }
                                    store.selectAgent(placement.agent)
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: placement.agent.state.symbol)
                                            .frame(width: 20)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(placement.agent.name).lineLimit(1)
                                            Text(placement.rangeLabel)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()
            Button("Open Command Center", systemImage: "slider.horizontal.3") {
                openWindow(id: "command-center")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit SidePulse", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 370)
    }

    private func slotColor(_ slot: AgentLEDSlot) -> Color {
        guard let agent = slot.agent else { return .secondary.opacity(0.15) }
        return Color(hex: store.selectedProfile.style(for: agent.state).colorHex)
    }
}
