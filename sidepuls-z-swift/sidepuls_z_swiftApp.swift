import AppKit
import Combine
import SwiftUI

@main
struct SidePulseCommandCenterApp: App {
    @State private var store = CommandCenterStore()
    @StateObject private var menuBarIconAnimator = MenuBarIconAnimator()

    var body: some Scene {
        WindowGroup("SidePulse Command Center", id: "command-center") {
            ContentView(store: store)
        }
        .defaultSize(width: 1_180, height: 780)

        MenuBarExtra {
            SidePulseMenuBarView(store: store)
        } label: {
            SidePulseMenuBarIcon(
                store: store,
                animationTick: menuBarIconAnimator.tick
            )
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private final class MenuBarIconAnimator: ObservableObject {
    @Published private(set) var tick = 0
    private var timer: Timer?

    init() {
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick = (self.tick + 1) % 120
            }
        }
        timer.tolerance = 0.012
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

private struct SidePulseMenuBarIcon: View {
    @Bindable var store: CommandCenterStore
    let animationTick: Int

    var body: some View {
        let _ = animationTick
        let program = store.device.connected ? store.device.activeProgram : store.scene.program
        let elapsed = store.device.connected
            ? store.device.lastWrite.map { max(0, Date.now.timeIntervalSince($0)) }
                ?? Date.now.timeIntervalSinceReferenceDate
            : Date.now.timeIntervalSinceReferenceDate
        let frame = LEDFirmwareProgram(
            program: program,
            ledCount: store.device.ledCount
        ).frame(at: elapsed)
        let image = MenuBarIconRenderer.image(
            style: store.menuBarIconStyle,
            colors: frame.colors
        )

        Image(nsImage: image)
            .renderingMode(.original)
            .frame(width: MenuBarIconRenderer.size.width, height: MenuBarIconRenderer.size.height)
            .accessibilityLabel("SidePulse, \(store.aggregateState.title), \(store.menuBarIconStyle.title)")
            .help("SidePulse · \(store.aggregateState.title)")
    }
}

private enum MenuBarIconRenderer {
    static let size = NSSize(width: 28, height: 16)

    static func image(
        style: MenuBarIconStyle,
        colors: [LEDProgramColor]
    ) -> NSImage {
        renderedImage { bounds in
            let groups = MenuBarDotLayout.sourceIndices(
                for: style,
                ledCount: colors.count
            )
            let dotColors = groups.map { indices in
                indices.compactMap { colors.indices.contains($0) ? colors[$0] : nil }
                    .max(by: { $0.peak < $1.peak }) ?? .black
            }
            drawHorizontalDots(
                colors: dotColors,
                diameter: style == .horizontalEight ? 2.6 : 4,
                spacing: style == .horizontalEight ? 0.65 : 1.5,
                in: bounds
            )
        }
    }

    private static func renderedImage(
        draw: @escaping (NSRect) -> Void
    ) -> NSImage {
        let image = NSImage(size: size, flipped: false) { bounds in
            NSGraphicsContext.current?.shouldAntialias = true
            draw(bounds)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawHorizontalDots(
        colors: [LEDProgramColor],
        diameter: CGFloat,
        spacing: CGFloat,
        in bounds: NSRect
    ) {
        let totalLength = CGFloat(colors.count) * diameter
            + CGFloat(max(0, colors.count - 1)) * spacing
        let horizontalPadding: CGFloat = colors.count > 4 ? 1.15 : 2.5
        let verticalPadding: CGFloat = colors.count > 4 ? 2.1 : 1.8
        let pillRect = NSRect(
            x: bounds.midX - (totalLength + horizontalPadding * 2) / 2,
            y: bounds.midY - (diameter + verticalPadding * 2) / 2,
            width: totalLength + horizontalPadding * 2,
            height: diameter + verticalPadding * 2
        )
        let pill = NSBezierPath(
            roundedRect: pillRect,
            xRadius: pillRect.height / 2,
            yRadius: pillRect.height / 2
        )
        NSColor.white.withAlphaComponent(0.92).setFill()
        pill.fill()
        NSColor.black.withAlphaComponent(0.16).setStroke()
        pill.lineWidth = 0.45
        pill.stroke()

        for index in colors.indices {
            let rect = NSRect(
                x: bounds.minX + (bounds.width - totalLength) / 2
                    + CGFloat(index) * (diameter + spacing),
                y: bounds.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            drawDot(in: rect, color: colors[index])
        }
    }

    private static func drawDot(
        in rect: NSRect,
        color: LEDProgramColor
    ) {
        let active = color.peak > 0.004
        let fill = active
            ? NSColor(
                srgbRed: color.red,
                green: color.green,
                blue: color.blue,
                alpha: 1
            )
            : NSColor.black.withAlphaComponent(0.16)
        fill.setFill()
        let path = NSBezierPath(ovalIn: rect)
        path.fill()
        NSColor.black.withAlphaComponent(active ? 0.28 : 0.18).setStroke()
        path.lineWidth = 0.35
        path.stroke()
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
