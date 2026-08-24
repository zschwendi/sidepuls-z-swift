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
            Label("SidePulse", systemImage: store.aggregateState.symbol)
        }
        .menuBarExtraStyle(.window)
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
