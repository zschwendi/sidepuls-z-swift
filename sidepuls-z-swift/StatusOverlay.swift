import AppKit
import Observation
import SwiftUI

struct SidePulseAgentSpaceItem: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var project: String
    var provider: AgentProvider
    var state: AgentState
    var colorHex: String
    var updatedAt: Date
}

struct SidePulseStatusOverlaySignal: Equatable, Sendable {
    var state: AgentState
    var colorHex: String
    var agents: [SidePulseAgentSpaceItem]
}

extension Notification.Name {
    static let sidePulseStatusOverlaySignalDidChange = Notification.Name(
        "com.zephyrstudios.sidepulse.status-overlay.signal"
    )
    static let sidePulseStatusOverlayDismiss = Notification.Name(
        "com.zephyrstudios.sidepulse.status-overlay.dismiss"
    )
    static let sidePulseAgentSpaceSelectAgent = Notification.Name(
        "com.zephyrstudios.sidepulse.agent-space.select-agent"
    )
}

@MainActor
final class SidePulseAppDelegate: NSObject, NSApplicationDelegate {
    private let statusOverlay = SidePulseStatusOverlayController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        statusOverlay.start()
    }
}

@MainActor
@Observable
private final class SidePulseAgentSpaceModel {
    var signal = SidePulseStatusOverlaySignal(state: .idle, colorHex: "#000000", agents: [])
    var isExpanded = false
    var isPinned = false
    var notchHeight: CGFloat = 30
    var notchWidth: CGFloat = 166

    @ObservationIgnored var onLayoutChange: (() -> Void)?
    @ObservationIgnored private var isHovered = false
    @ObservationIgnored private var collapseWorkItem: DispatchWorkItem?

    func update(
        _ signal: SidePulseStatusOverlaySignal,
        notchHeight: CGFloat,
        notchWidth: CGFloat
    ) {
        self.signal = signal
        self.notchHeight = notchHeight
        self.notchWidth = notchWidth
        onLayoutChange?()
    }

    func setHovered(_ hovered: Bool) {
        isHovered = hovered
        collapseWorkItem?.cancel()
        collapseWorkItem = nil

        if hovered {
            setExpanded(true)
        } else if !isPinned {
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.isHovered, !self.isPinned else { return }
                self.setExpanded(false)
            }
            collapseWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: item)
        }
    }

    func togglePin() {
        isPinned.toggle()
        setExpanded(isPinned || isHovered)
    }

    func resetPresentation() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        isHovered = false
        isPinned = false
        setExpanded(false)
    }

    private func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        onLayoutChange?()
    }
}

@MainActor
private final class SidePulseStatusOverlayController {
    private let compactSideWidth: CGFloat = 72
    private let expandedWidth: CGFloat = 390
    private let model = SidePulseAgentSpaceModel()
    private var panel: NSPanel?
    private var signalObserver: NSObjectProtocol?
    private var dismissObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    func start() {
        guard signalObserver == nil else { return }
        model.onLayoutChange = { [weak self] in self?.updatePanelLayout(animated: true) }

        signalObserver = NotificationCenter.default.addObserver(
            forName: .sidePulseStatusOverlaySignalDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let signal = notification.object as? SidePulseStatusOverlaySignal else { return }
            Task { @MainActor [weak self] in self?.show(signal) }
        }
        dismissObserver = NotificationCenter.default.addObserver(
            forName: .sidePulseStatusOverlayDismiss,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePanelLayout(animated: false) }
        }
    }

    private func show(_ signal: SidePulseStatusOverlaySignal) {
        guard !signal.agents.isEmpty else {
            dismiss()
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        let screen = targetScreen()
        model.update(
            signal,
            notchHeight: screen?.safeAreaInsets.top ?? 30,
            notchWidth: notchWidth(on: screen)
        )
        updatePanelLayout(animated: panel.isVisible)

        guard !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        guard let panel, panel.isVisible else { return }
        model.resetPresentation()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: compactSize(on: targetScreen())),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.title = "SidePulse Agent Space"
        panel.setAccessibilityLabel("SidePulse dynamic agent island")
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let hostingView = NSHostingView(rootView: SidePulseAgentSpaceView(model: model))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        return panel
    }

    private func updatePanelLayout(animated: Bool) {
        guard let panel, let screen = targetScreen() else { return }
        let size = model.isExpanded ? expandedSize(on: screen) : compactSize(on: screen)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.hasShadow = model.isExpanded
        guard animated, panel.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = model.isExpanded ? 0.24 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func notchWidth(on screen: NSScreen?) -> CGFloat {
        guard let left = screen?.auxiliaryTopLeftArea,
              let right = screen?.auxiliaryTopRightArea
        else { return 166 }
        return max(0, right.minX - left.maxX)
    }

    private func compactSize(on screen: NSScreen?) -> NSSize {
        let notchHeight = screen?.safeAreaInsets.top ?? 30
        return NSSize(
            width: notchWidth(on: screen) + compactSideWidth * 2,
            height: notchHeight
        )
    }

    private func expandedSize(on screen: NSScreen?) -> NSSize {
        let notchHeight = screen?.safeAreaInsets.top ?? 30
        let visibleRows = min(max(model.signal.agents.count, 1), 6)
        return NSSize(width: expandedWidth, height: notchHeight + 78 + CGFloat(visibleRows * 54))
    }
}

private struct SidePulseAgentSpaceView: View {
    @Bindable var model: SidePulseAgentSpaceModel

    private var aggregateColor: Color { Color(hex: model.signal.colorHex) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(model.isExpanded ? 0.985 : 0)

            if model.isExpanded {
                expandedContent
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            } else {
                compactContent
                    .transition(.opacity)
            }
        }
        .clipShape(.rect(bottomLeadingRadius: 24, bottomTrailingRadius: 24))
        .overlay(alignment: .bottom) {
            if model.isExpanded {
                RoundedRectangle(cornerRadius: 1)
                    .fill(aggregateColor.opacity(0.34))
                    .frame(height: 1)
                    .padding(.horizontal, 22)
            }
        }
        .shadow(
            color: aggregateColor.opacity(model.isExpanded ? 0.18 : 0),
            radius: model.isExpanded ? 18 : 0,
            y: model.isExpanded ? 6 : 0
        )
        .contentShape(.rect)
        .animation(.snappy(duration: 0.24), value: model.isExpanded)
        .animation(.easeInOut(duration: 0.18), value: model.signal)
        .onHover { model.setHovered($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SidePulse dynamic agent island")
    }

    private var compactContent: some View {
        HStack(spacing: 0) {
            AgentSpaceDots(agents: model.signal.agents)
                .frame(width: 64, alignment: .trailing)
                .padding(.trailing, 8)

            Color.clear
                .frame(width: model.notchWidth)

            HStack(spacing: 6) {
                Text("\(model.signal.agents.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(.white.opacity(0.46))
            }
            .frame(width: 64, alignment: .leading)
            .padding(.leading, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchHeight + 6)

            HStack(spacing: 10) {
                AgentSpaceDots(agents: model.signal.agents)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AGENT SPACE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                    Text("\(model.signal.state.title) · \(model.signal.agents.count) session\(model.signal.agents.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }
                Spacer(minLength: 0)
                Button { model.togglePin() } label: {
                    Image(systemName: model.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.isPinned ? aggregateColor : .white.opacity(0.55))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.07), in: .circle)
                }
                .buttonStyle(.plain)
                .help(model.isPinned ? "Unpin Agent Space" : "Keep Agent Space open")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            Divider().overlay(.white.opacity(0.08))

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.signal.agents) { agent in
                        AgentSpaceRow(agent: agent)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct AgentSpaceRow: View {
    let agent: SidePulseAgentSpaceItem

    private var color: Color { Color(hex: agent.colorHex) }

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .sidePulseAgentSpaceSelectAgent, object: agent.id)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: agent.state.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.14), in: .rect(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                    Text("\(agent.provider.title) · \(agent.project)")
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(agent.updatedAt, style: .relative)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .monospacedDigit()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .padding(.horizontal, 9)
            .frame(height: 48)
            .contentShape(.rect)
            .background(.white.opacity(0.045), in: .rect(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .help("Open \(agent.name)")
    }
}

private struct AgentSpaceDots: View {
    let agents: [SidePulseAgentSpaceItem]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isAnimated)) { timeline in
            HStack(spacing: 2.5) {
                ForEach(Array(agents.prefix(8).enumerated()), id: \.element.id) { index, agent in
                    let color = Color(hex: agent.colorHex)
                    let brightness = dotBrightness(agent: agent, index: index, date: timeline.date)
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(color.opacity(brightness))
                        .frame(width: 5, height: 9)
                        .shadow(color: color.opacity(0.45 * brightness), radius: 2.5)
                }
            }
        }
        .frame(minWidth: 18, alignment: .leading)
    }

    private var isAnimated: Bool {
        agents.contains { $0.state == .working || $0.state == .toolRunning }
    }

    private func dotBrightness(agent: SidePulseAgentSpaceItem, index: Int, date: Date) -> Double {
        guard agent.state == .working || agent.state == .toolRunning else { return 1 }
        let cycle = 1.05
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycle) / cycle
        let dotPhase = (phase - Double(index) / Double(max(agents.count, 1)) + 1)
            .truncatingRemainder(dividingBy: 1)
        return 0.28 + 0.72 * ((cos(dotPhase * 2 * .pi) + 1) / 2)
    }
}
