import AppKit
import SwiftUI

struct SidePulseStatusOverlaySignal: Equatable, Sendable {
    var state: AgentState
    var colorHex: String
    var sessionCount: Int
}

extension Notification.Name {
    static let sidePulseStatusOverlaySignalDidChange = Notification.Name(
        "com.zephyrstudios.sidepulse.status-overlay.signal"
    )
    static let sidePulseStatusOverlayDismiss = Notification.Name(
        "com.zephyrstudios.sidepulse.status-overlay.dismiss"
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
private final class SidePulseStatusOverlayController {
    private let panelSize = NSSize(width: 286, height: 58)
    private var panel: NSPanel?
    private var signalObserver: NSObjectProtocol?
    private var dismissObserver: NSObjectProtocol?
    private var dismissWorkItem: DispatchWorkItem?

    func start() {
        guard signalObserver == nil else { return }
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
    }

    private func show(_ signal: SidePulseStatusOverlaySignal) {
        dismissWorkItem?.cancel()
        guard signal.state != .idle else {
            dismiss()
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        let hostingView = NSHostingView(rootView: SidePulseStatusOverlayView(signal: signal))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        position(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.dismiss() }
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + displayDuration(for: signal.state),
            execute: workItem
        )
    }

    private func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.title = "SidePulse Status"
        panel.setAccessibilityLabel("SidePulse status popout")
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
        else { return }
        let topEdge = screen.visibleFrame.maxY - 8
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: topEdge - panelSize.height
        ))
    }

    private func displayDuration(for state: AgentState) -> TimeInterval {
        switch state {
        case .error, .waiting: 4
        case .completed: 3
        case .working, .toolRunning: 2.2
        case .idle: 0
        }
    }
}

private struct SidePulseStatusOverlayView: View {
    let signal: SidePulseStatusOverlaySignal

    private var color: Color { Color(hex: signal.colorHex) }
    private var subtitle: String {
        let sessions = "\(signal.sessionCount) session\(signal.sessionCount == 1 ? "" : "s")"
        return switch signal.state {
        case .error: "Run stopped · \(sessions)"
        case .waiting: "Your approval is needed · \(sessions)"
        case .completed: "Ready for another run · \(sessions)"
        case .working, .toolRunning: "Unified agent hub · \(sessions)"
        case .idle: "No active agents"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            StatusOverlayDots(state: signal.state, color: color)

            VStack(alignment: .leading, spacing: 2) {
                Text(signal.state.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(width: 286, height: 58)
        .glassEffect(.regular.tint(color.opacity(0.08)), in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("SidePulse, \(signal.state.title), \(subtitle)")
    }
}

private struct StatusOverlayDots: View {
    let state: AgentState
    let color: Color

    private var animated: Bool { state == .working || state == .toolRunning }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { timeline in
            HStack(spacing: 2.5) {
                ForEach(0..<8, id: \.self) { index in
                    let brightness = dotBrightness(index: index, date: timeline.date)
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(color.opacity(brightness))
                        .frame(width: 7, height: 13)
                        .shadow(color: color.opacity(0.5 * brightness), radius: 3)
                }
            }
        }
        .frame(width: 74)
    }

    private func dotBrightness(index: Int, date: Date) -> Double {
        guard animated else { return 1 }
        let cycle = 1.05
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycle) / cycle
        let dotPhase = (phase - Double(index) / 8 + 1)
            .truncatingRemainder(dividingBy: 1)
        let wave = (cos(dotPhase * 2 * .pi) + 1) / 2
        return 0.24 + 0.76 * wave
    }
}
