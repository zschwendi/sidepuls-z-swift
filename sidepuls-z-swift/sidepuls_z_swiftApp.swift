import AppKit
import QuartzCore
import SwiftUI

@main
struct SidePulseCommandCenterApp: App {
    @State private var store: CommandCenterStore
    private let menuBarController: SidePulseMenuBarController

    init() {
        LegacySidePulsePreferences.migrateIfNeeded()
        let store = CommandCenterStore()
        _store = State(initialValue: store)
        menuBarController = SidePulseMenuBarController(store: store)
    }

    var body: some Scene {
        WindowGroup("SidePulse Command Center", id: "command-center") {
            ContentView(store: store)
        }
        .defaultSize(width: 940, height: 640)
    }
}

@MainActor
private final class SidePulseMenuBarController: NSObject {
    private let store: CommandCenterStore
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let iconView = MenuBarDotAnimationView()
    private let notchDisplay = NotchDisplayController()
    private var displayLink: CADisplayLink?
    private var renderedProgramText = ""
    private var renderedLEDCount = 0
    private var renderedProgram: LEDFirmwareProgram?
    private var renderedClockOrigin: Date?
    private var renderedIconStyle: MenuBarIconStyle = .horizontalEight
    private var statusItemVisibilityObservation: NSKeyValueObservation?

    init(store: CommandCenterStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: 32)
        super.init()

        // Give macOS one stable identity for placement and visibility while
        // still respecting the user's system-level menu bar setting.
        statusItem.autosaveName = "SidePulseStatusItem"

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
        statusItemVisibilityObservation = statusItem.observe(
            \.isVisible,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshIconSource()
            }
        }
        store.setSoftwareDisplayChangeHandler { [weak self] in
            self?.refreshIconSource()
        }
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        renderIconFrame()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func refreshIconSource() {
        notchDisplay.update(
            enabled: store.notchEnabled,
            program: store.softwareDisplayProgram,
            ledCount: store.device.ledCount,
            clockOrigin: store.softwareDisplayClockOrigin,
            brightness: store.notchBrightness
        )
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
        renderedClockOrigin = store.softwareDisplayClockOrigin
        renderedIconStyle = store.menuBarIconStyle
        renderIconFrame()
        let toolTip = "SidePulse · \(store.agents.count) session\(store.agents.count == 1 ? "" : "s")"
        if button.toolTip != toolTip {
            button.toolTip = toolTip
        }
    }

    private func renderIconFrame() {
        guard statusItem.isVisible else {
            displayLink?.isPaused = true
            return
        }
        let elapsed = renderedClockOrigin
            .map { max(0, Date.now.timeIntervalSince($0)) }
            ?? Date.now.timeIntervalSinceReferenceDate
        guard let frame = renderedProgram?.frame(at: elapsed) else { return }
        iconView.render(
            style: renderedIconStyle,
            sourceColors: frame.colors
        )
        displayLink?.isPaused = !(renderedProgram?.needsAnimationFrame(at: elapsed) ?? false)
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
                Text("SidePulse").font(.headline)
                Spacer()
                Text("\(store.agents.count) session\(store.agents.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            UtilityControlsView(store: store, compact: true)

            if let title = store.utilityStatusTitle {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(store.utilityStatusDetail)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    MenuBarPhysicalArrayView(store: store)
                }
                .frame(width: 64, alignment: .leading)

                VStack(alignment: .leading, spacing: 0) {
                    if store.agents.isEmpty {
                        Label("No detected sessions", systemImage: "moon.stars")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                    } else {
                        MenuBarAgentHubView(store: store, openAgent: openAgent)
                        .scrollIndicators(.hidden)
                        .frame(height: LEDArrayPreviewStyle.menuBar.size(ledCount: 8).height)
                        .padding(8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Picker("Signal Mode", selection: Binding(
                get: { store.agentDisplayMode },
                set: { store.selectAgentDisplayMode($0) }
            )) {
                Text("Simple").tag(AgentDisplayMode.simple)
                Text("Per Agent").tag(AgentDisplayMode.perAgent)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
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
            }

            Button("Open Command Center", systemImage: "slider.horizontal.3") {
                openCommandCenter()
            }
            Button("Quit SidePulse", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 280)
    }
}

private struct MenuBarAgentHubView: View {
    @Bindable var store: CommandCenterStore
    let openAgent: (AgentSession) -> Void

    var body: some View {
        ScrollView {
            if store.agentDisplayMode == .simple {
                LazyVStack(spacing: LEDArrayPreviewStyle.menuBar.rowSpacing) {
                    ForEach(Array(store.agents.prefix(8))) { agent in
                        agentButton(agent)
                    }
                }
            } else {
                LazyVStack(spacing: LEDArrayPreviewStyle.menuBar.rowSpacing) {
                    ForEach(0..<displayedLEDCount, id: \.self) { row in
                        if let placement = placementsByTopRow[row] {
                            agentButton(placement.agent)
                        } else {
                            Color.clear
                                .frame(height: LEDArrayPreviewStyle.menuBar.dotSize)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }

    private var displayedLEDCount: Int {
        max(1, min(8, store.device.ledCount))
    }

    private var placementsByTopRow: [Int: AgentArrayPlacement] {
        Dictionary(uniqueKeysWithValues: store.scene.placementsTopToBottom.compactMap { placement in
            guard let row = placement.topDisplayRow(ledCount: displayedLEDCount) else { return nil }
            return (row, placement)
        })
    }

    private func agentButton(_ agent: AgentSession) -> some View {
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

private struct MenuBarPhysicalArrayView: View {
    @Bindable var store: CommandCenterStore

    var body: some View {
        let program = store.softwareDisplayProgram

        DisplayLinkedLEDArray(
            program: program,
            ledCount: store.device.ledCount,
            clockOrigin: store.softwareDisplayClockOrigin,
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
        HStack(spacing: 6) {
            Image(systemName: agent.state.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14, height: 14)
                .background(color.opacity(0.12), in: .rect(cornerRadius: 4))

            Text(agent.name)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 4)
            Text(agent.provider.title)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 5)
        .frame(height: LEDArrayPreviewStyle.menuBar.dotSize)
        .contentShape(.rect)
        .background(color.opacity(0.07), in: .rect(cornerRadius: 5))
    }
}
