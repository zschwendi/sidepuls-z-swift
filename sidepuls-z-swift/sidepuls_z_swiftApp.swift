import AppKit
import QuartzCore
import SwiftUI

@main
struct SidePulseCommandCenterApp: App {
    @State private var store: CommandCenterStore
    private let menuBarController: SidePulseMenuBarController

    init() {
        let store = CommandCenterStore()
        _store = State(initialValue: store)
        menuBarController = SidePulseMenuBarController(store: store)
    }

    var body: some Scene {
        WindowGroup("SidePulse Command Center", id: "command-center") {
            ContentView(store: store)
        }
        .defaultSize(width: 1_180, height: 780)
    }
}

@MainActor
private final class SidePulseMenuBarController: NSObject {
    private let store: CommandCenterStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let iconView = MenuBarDotAnimationView()
    private var displayLink: CADisplayLink?
    private var renderedProgramText = ""
    private var renderedLEDCount = 0
    private var renderedProgram: LEDFirmwareProgram?

    init(store: CommandCenterStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: 32)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.image = nil
            button.imagePosition = .noImage
            button.setAccessibilityLabel("SidePulse")
            iconView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: MenuBarDotAnimationView.preferredSize.width),
                iconView.heightAnchor.constraint(equalToConstant: MenuBarDotAnimationView.preferredSize.height),
            ])
        }

        popover.behavior = .transient
        popover.animates = false
        let hostingController = NSHostingController(
            rootView: AnyView(
                SidePulseMenuBarView(
                    store: store,
                    openAgent: { [weak self] agent in self?.openAgent(agent) },
                    openCommandCenter: { [weak self] in self?.openCommandCenter() }
                )
            )
        )
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController

        if let button = statusItem.button {
            let displayLink = button.displayLink(
                target: self,
                selector: #selector(displayLinkDidFire(_:))
            )
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 120,
                maximum: 120,
                preferred: 120
            )
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }
        refreshIcon()
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        refreshIcon()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let program = store.softwareDisplayProgram
        let ledCount = store.device.ledCount
        if renderedProgram == nil
            || renderedProgramText != program
            || renderedLEDCount != ledCount
        {
            renderedProgramText = program
            renderedLEDCount = ledCount
            renderedProgram = LEDFirmwareProgram(program: program, ledCount: ledCount)
        }
        let elapsed = store.device.connected
            ? store.device.lastWrite.map { max(0, Date.now.timeIntervalSince($0)) }
                ?? Date.now.timeIntervalSinceReferenceDate
            : Date.now.timeIntervalSinceReferenceDate
        guard let frame = renderedProgram?.frame(at: elapsed) else { return }
        iconView.render(
            style: store.menuBarIconStyle,
            sourceColors: frame.colors
        )
        let toolTip = "SidePulse · \(store.agents.count) session\(store.agents.count == 1 ? "" : "s")"
        if button.toolTip != toolTip {
            button.toolTip = toolTip
        }
    }

    private func openCommandCenter() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == "Command Center" }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
        }
    }

    private func openAgent(_ agent: AgentSession) {
        popover.performClose(nil)
        store.openAgent(agent)
    }
}

struct SidePulseMenuBarView: View {
    @Bindable var store: CommandCenterStore
    let openAgent: (AgentSession) -> Void
    let openCommandCenter: () -> Void

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

            HStack(alignment: .top, spacing: 14) {
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
                                        openAgent(agent)
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

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Label("Max Brightness", systemImage: "sun.max.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int((store.universalBrightness * 100).rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { store.universalBrightness },
                        set: { store.setUniversalBrightness($0) }
                    ),
                    in: 0...1,
                    step: 0.01
                )
                .tint(.purple)
                .controlSize(.small)
                .accessibilityLabel("Max Brightness")
                .accessibilityValue("\(Int((store.universalBrightness * 100).rounded())) percent")
                Text("Dims every profile, animation, preview, and battery signal.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

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
                .frame(width: 120)
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
                openCommandCenter()
            }
            Button("Quit SidePulse", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            store.refreshLaunchAtLoginStatus()
        }
    }
}

private struct MenuBarPhysicalArrayView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        let program = store.softwareDisplayProgram

        DisplayLinkedLEDArray(
            program: program,
            ledCount: store.device.ledCount,
            clockOrigin: store.device.connected ? store.device.lastWrite : nil,
            style: .menuBar
        )
            .frame(
                width: LEDArrayPreviewStyle.menuBar.size(
                    ledCount: store.device.ledCount
                ).width,
                height: LEDArrayPreviewStyle.menuBar.size(
                    ledCount: store.device.ledCount
                ).height
            )
            .padding(8)
            .background(.black.opacity(0.92), in: .rect(cornerRadius: 11))
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
