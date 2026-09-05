import AppKit
import QuartzCore
import SwiftUI

@main
enum SidePulseMain {
    static func main() {
        guard !CoffeePowerProtect.runIfRequested(), !ClosedLidSleepGuard.runIfRequested() else { return }
        SidePulseCommandCenterApp.main()
    }
}

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
            CommandCenterRootView(store: store, menuBarController: menuBarController)
        }
        .defaultSize(width: 940, height: 640)
    }
}

private struct CommandCenterRootView: View {
    let store: CommandCenterStore
    let menuBarController: SidePulseMenuBarController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(store: store)
            .background(CommandCenterWindowReader(register: menuBarController.registerCommandCenter))
            .onAppear {
                menuBarController.createCommandCenter = { openWindow(id: "command-center") }
            }
    }
}

private struct CommandCenterWindowReader: NSViewRepresentable {
    let register: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.register = register
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {}

    final class WindowReaderView: NSView {
        var register: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { register?(window) }
        }
    }
}

private final class NotchIslandHostingView: NSHostingView<NotchIslandView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
    private var presentationObservation: NSKeyValueObservation?
    private var lastRequestedVisibility: Bool?
    private var lastExternalPresentation: NSApplication.PresentationOptions = []
    private var activatedAt = Date.distantPast
    private weak var commandCenterWindow: NSWindow?
    private var commandCenterRequested = false
    var createCommandCenter: (() -> Void)?

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

        notchDisplay.setIslandContent(NotchIslandHostingView(rootView: NotchIslandView(
            store: store,
            openAgent: { [weak self] agent in self?.openAgent(agent) },
            openCommandCenter: { [weak self] in
                self?.store.selectedSection = .overview
                self?.openCommandCenter()
            },
            togglePower: { [weak self] in self?.store.toggleOutputPower() }
        )))
        notchDisplay.onPresentationChanged = { [weak self] in self?.refreshStatusItemVisibility() }

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
        presentationObservation = NSApp.observe(\.currentSystemPresentationOptions, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.presentationChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(workspaceApplicationChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(presentationChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationBecameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(commandCenterClosed(_:)), name: NSWindow.willCloseNotification, object: nil)
        store.setSoftwareDisplayChangeHandler { [weak self] in
            self?.refreshIconSource()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        renderIconFrame()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        let presentation = NSApp.currentSystemPresentationOptions
        let justActivated = Date.now.timeIntervalSince(activatedAt) < 1
        if presentation.contains(.fullScreen) || presentation.contains(.hideMenuBar)
            || (justActivated && lastExternalPresentation.contains(.fullScreen)) {
            activatedAt = .distantPast
            lastExternalPresentation = []
            store.selectedSection = .overview
            openCommandCenter()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func refreshIconSource() {
        notchDisplay.setIslandContentHeight(NotchIslandView.contentHeight(agentCount: store.notchDrivingAgents.count))
        notchDisplay.update(
            enabled: store.notchEnabled,
            program: store.softwareDisplayProgram,
            ledCount: store.device.ledCount,
            clockOrigin: store.softwareDisplayClockOrigin,
            brightness: store.notchBrightness
        )
        refreshStatusItemVisibility()
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

    @objc private func workspaceApplicationChanged() {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            activatedAt = .now
        }
        presentationChanged()
    }

    @objc private func presentationChanged() {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalPresentation = NSApp.currentSystemPresentationOptions
        }
        refreshStatusItemVisibility()
    }

    private func refreshStatusItemVisibility() {
        let presentation = NSApp.currentSystemPresentationOptions
        let autoHidden = !presentation.intersection([.fullScreen, .autoHideMenuBar, .hideMenuBar]).isEmpty
        let visible = store.menuBarVisibilityMode.shouldShow(
            notchPresented: notchDisplay.isPresented,
            menuBarAutoHidden: autoHidden,
            keepWhenAutoHidden: store.menuBarKeepWhenAutoHidden
        )
        guard lastRequestedVisibility != visible else { return }
        lastRequestedVisibility = visible
        if !visible { popover.performClose(nil) }
        statusItem.isVisible = visible
        renderIconFrame()
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
        notchDisplay.collapse()
        commandCenterRequested = true
        if let window = commandCenterWindow {
            focusCommandCenter(window)
        } else if let createCommandCenter {
            createCommandCenter()
        } else {
            NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
        }
    }

    func registerCommandCenter(_ window: NSWindow) {
        commandCenterWindow = window
        if commandCenterRequested { focusCommandCenter(window) }
    }

    @objc private func commandCenterClosed(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === commandCenterWindow {
            commandCenterWindow = nil
        }
    }

    private func focusCommandCenter(_ window: NSWindow) {
        window.deminiaturize(nil)
        // Keep the window in its Space and take the user to it, including when
        // the click came from a different application's full-screen Space.
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        DispatchQueue.main.async { [weak self] in
            self?.applicationBecameActive()
        }
    }

    @objc private func applicationBecameActive() {
        guard commandCenterRequested, NSApp.isActive, let window = commandCenterWindow else { return }
        window.makeKeyAndOrderFront(nil)
        commandCenterRequested = false
    }

    private func openAgent(_ agent: AgentSession) {
        popover.performClose(nil)
        notchDisplay.collapse()
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

            UtilityControlsView(store: store, compact: true, openSettings: openCommandCenter)
                .padding(3)
                .glassEffect(.regular, in: .capsule)

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

            if store.displayedUtilityMode == .agents {
                Picker("Signal Mode", selection: Binding(
                    get: { store.agentDisplayMode },
                    set: { store.selectAgentDisplayMode($0) }
                )) {
                    Text("Simple").tag(AgentDisplayMode.simple)
                    Text("Per Agent").tag(AgentDisplayMode.perAgent)
                }
                .pickerStyle(.segmented)
            } else {
                Button("Agent lighting", systemImage: "arrow.uturn.backward") {
                    store.selectUtilityMode(.agents)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

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
