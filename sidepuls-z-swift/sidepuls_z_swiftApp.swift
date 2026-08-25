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

    var body: some View {
        Image(nsImage: MenuBarIconRenderer.image(
            style: store.menuBarIconStyle,
            stateSymbol: store.aggregateState.symbol,
            slots: store.scene.slots,
            ledCount: store.device.ledCount
        ))
        .renderingMode(.template)
        .frame(width: MenuBarIconRenderer.size.width, height: MenuBarIconRenderer.size.height)
        .accessibilityLabel("SidePulse, \(store.aggregateState.title), \(store.menuBarIconStyle.title)")
        .help("SidePulse · \(store.aggregateState.title)")
    }
}

enum MenuBarIconRenderer {
    static let size = NSSize(width: 28, height: 16)

    static func image(
        style: MenuBarIconStyle,
        stateSymbol: String,
        slots: [AgentLEDSlot],
        ledCount: Int
    ) -> NSImage {
        let image = NSImage(size: size, flipped: false) { bounds in
            NSGraphicsContext.current?.shouldAntialias = true
            if style == .stateSymbol {
                drawStateSymbol(stateSymbol, in: bounds)
            } else {
                drawDots(style: style, slots: slots, ledCount: ledCount, in: bounds)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawStateSymbol(_ name: String, in bounds: NSRect) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "SidePulse")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        else { return }
        symbol.draw(in: NSRect(
            x: bounds.midX - 7,
            y: bounds.midY - 7,
            width: 14,
            height: 14
        ))
    }

    private static func drawDots(
        style: MenuBarIconStyle,
        slots: [AgentLEDSlot],
        ledCount: Int,
        in bounds: NSRect
    ) {
        let groups = MenuBarDotLayout.sourceIndices(for: style, ledCount: ledCount)
        guard !groups.isEmpty else { return }

        let geometry: (diameter: CGFloat, spacing: CGFloat, vertical: Bool) = switch style {
        case .horizontalEight: (2.6, 0.65, false)
        case .verticalEight: (1.65, 0.3, true)
        case .mirroredFour: (4, 1.5, false)
        case .stateSymbol: (0, 0, false)
        }
        let totalLength = CGFloat(groups.count) * geometry.diameter
            + CGFloat(max(0, groups.count - 1)) * geometry.spacing

        for (position, indices) in groups.enumerated() {
            let active = indices.contains { index in
                slots.first(where: { $0.index == index })?.agent != nil
            }
            NSColor.black.withAlphaComponent(active ? 1 : 0.55).setFill()

            let rect: NSRect
            if geometry.vertical {
                rect = NSRect(
                    x: bounds.midX - geometry.diameter / 2,
                    y: bounds.maxY - (bounds.height - totalLength) / 2
                        - geometry.diameter
                        - CGFloat(position) * (geometry.diameter + geometry.spacing),
                    width: geometry.diameter,
                    height: geometry.diameter
                )
            } else {
                rect = NSRect(
                    x: bounds.minX + (bounds.width - totalLength) / 2
                        + CGFloat(position) * (geometry.diameter + geometry.spacing),
                    y: bounds.midY - geometry.diameter / 2,
                    width: geometry.diameter,
                    height: geometry.diameter
                )
            }
            NSBezierPath(ovalIn: rect).fill()
        }
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
