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
            .accessibilityLabel("SidePulse, \(store.agents.count) sessions, \(store.menuBarIconStyle.title)")
            .help("SidePulse · \(store.agents.count) session\(store.agents.count == 1 ? "" : "s")")
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
        NSColor.white.withAlphaComponent(0.94).setFill()
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
        guard color.peak > 0.004 else { return }
        let brightnessBoost = 2.2
        let fill = NSColor(
            srgbRed: min(1, color.red * brightnessBoost),
            green: min(1, color.green * brightnessBoost),
            blue: min(1, color.blue * brightnessBoost),
            alpha: 1
        )
        fill.setFill()
        let path = NSBezierPath(ovalIn: rect)
        path.fill()
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
                Text("\(store.agents.count) session\(store.agents.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LIVE ARRAY")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                    MenuBarPhysicalArrayView(store: store)
                }
                .frame(width: 64, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("AGENT TIMELINE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(store.agentDisplayMode == .simple ? "ONE SIGNAL" : "PER AGENT")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    if store.agents.isEmpty {
                        Label("No detected sessions", systemImage: "moon.stars")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(store.agents) { agent in
                                    Button {
                                        if agent.openURL == nil {
                                            openWindow(id: "command-center")
                                            NSApp.activate(ignoringOtherApps: true)
                                        }
                                        store.selectAgent(agent)
                                    } label: {
                                        MenuBarAgentRow(
                                            agent: agent,
                                            color: Color(hex: store.selectedProfile.style(for: agent.state).colorHex)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open \(agent.name)")
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: min(314, max(64, CGFloat(store.agents.count) * 58)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

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

            VStack(alignment: .leading, spacing: 5) {
                Toggle("Start SidePulse at login", isOn: Binding(
                    get: { store.launchAtLoginEnabled },
                    set: { store.setLaunchAtLoginEnabled($0) }
                ))
                .toggleStyle(.switch)
                if let message = store.launchAtLoginMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if store.launchAtLoginNeedsApproval {
                            Button("Open Login Items") {
                                store.openLoginItemsSettings()
                            }
                            .font(.caption2.weight(.semibold))
                            .buttonStyle(.link)
                        }
                    }
                }
            }

            Button("Open Command Center", systemImage: "slider.horizontal.3") {
                openWindow(id: "command-center")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit SidePulse", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 480)
        .onAppear {
            store.refreshLaunchAtLoginStatus()
        }
    }
}

private struct MenuBarPhysicalArrayView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        let program = store.device.connected ? store.device.activeProgram : store.scene.program
        let firmware = LEDFirmwareProgram(program: program, ledCount: store.device.ledCount)

        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let elapsed = store.device.connected
                ? store.device.lastWrite.map { max(0, timeline.date.timeIntervalSince($0)) }
                    ?? timeline.date.timeIntervalSinceReferenceDate
                : timeline.date.timeIntervalSinceReferenceDate
            let frame = firmware.frame(at: elapsed)

            VStack(spacing: 6) {
                ForEach(Array(frame.colors.indices.reversed()), id: \.self) { index in
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 11, alignment: .trailing)
                        let output = frame.colors[index]
                        let color = Color(
                            .sRGB,
                            red: output.red,
                            green: output.green,
                            blue: output.blue,
                            opacity: 1
                        )
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(color)
                            .shadow(color: color.opacity(min(0.8, output.peak)), radius: 4)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(.white.opacity(0.14), lineWidth: 0.6)
                            }
                            .frame(width: 18, height: 18)
                    }
                }
            }
            .padding(8)
            .background(.black.opacity(0.92), in: .rect(cornerRadius: 11))
            .accessibilityLabel("Live SidePulse array, LED \(frame.colors.count) at top through LED 1 at bottom")
        }
    }
}

private struct MenuBarAgentRow: View {
    let agent: AgentSession
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: agent.state.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.12), in: .rect(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(agent.provider.title)
                    Text("·")
                    Text(agent.project)
                    Text("·")
                    Text(agent.updatedAt, style: .relative)
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 6)
            Image(systemName: "arrow.up.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 50)
        .contentShape(.rect)
        .background(color.opacity(0.055), in: .rect(cornerRadius: 12))
    }
}
