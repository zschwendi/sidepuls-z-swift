import AppKit
import QuartzCore

/// Native adaptation of Peter Kuhar's SidePulse Notch geometry and light blend.
/// Source: inteliwear/sidepulse, virtual_device.py, MIT (see NOTICE).
enum NotchDisplayStyle: Equatable {
    case physicalNotch
    case syntheticIsland

    static func resolve(notchDepth: CGFloat) -> Self {
        notchDepth > 0 ? .physicalNotch : .syntheticIsland
    }

    var hasPhysicalNotch: Bool {
        self == .physicalNotch
    }

    var isSynthetic: Bool {
        self == .syntheticIsland
    }
}

enum NotchDisplayGeometry {
    static let bandHeight: CGFloat = 5
    static let syntheticWidth: CGFloat = 220
    static let syntheticHeight: CGFloat = 32

    static func frame(screen: CGRect, notchDepth: CGFloat, notchWidth: CGFloat?) -> CGRect {
        // NSScreen reports the cutout in the current display's logical points,
        // including display scaling. Do not impose a model-specific minimum.
        let width = min(screen.width, max(0, notchWidth ?? syntheticWidth))
        let height = max(0, notchDepth) + bandHeight
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - height, width: width, height: height)
    }

    static func frame(
        screen: CGRect,
        notchDepth: CGFloat,
        notchWidth: CGFloat?,
        style: NotchDisplayStyle
    ) -> CGRect {
        switch style {
        case .physicalNotch:
            return frame(screen: screen, notchDepth: notchDepth, notchWidth: notchWidth)
        case .syntheticIsland:
            return syntheticFrame(screen: screen)
        }
    }

    static func syntheticFrame(screen: CGRect) -> CGRect {
        let width = min(screen.width, syntheticWidth)
        let height = min(screen.height, syntheticHeight)
        return CGRect(x: screen.midX - width / 2,
                      y: screen.maxY - height,
                      width: width,
                      height: height)
    }

    static func expandedFrame(collapsed: CGRect, screen: CGRect, contentHeight: CGFloat) -> CGRect {
        let width = min(400, screen.width)
        let height = min(screen.height, collapsed.height + contentHeight + 22)
        return CGRect(x: min(max(screen.minX, collapsed.midX - width / 2), screen.maxX - width),
                      y: screen.maxY - height, width: width, height: height)
    }

    static func blendedColor(_ colors: [LEDProgramColor], x: CGFloat, width: CGFloat) -> LEDProgramColor {
        guard !colors.isEmpty, width > 0 else { return .black }
        let ledWidth = Double(width) / Double(colors.count)
        let radius = ledWidth * 1.5
        var result = LEDProgramColor.black
        for (index, color) in colors.enumerated() {
            let distance = abs(Double(x) - (Double(index) + 0.5) * ledWidth)
            guard distance <= radius else { continue }
            let weight = 0.5 + 0.5 * cos(.pi * distance / radius)
            result.red += color.red * weight
            result.green += color.green * weight
            result.blue += color.blue * weight
        }
        return LEDProgramColor(red: min(1, result.red), green: min(1, result.green), blue: min(1, result.blue))
    }
}

@MainActor
final class NotchDisplayController: NSObject {
    private var panel: NSPanel?
    private var ledView: NotchLEDView?
    private var containerView: NotchInteractionView?
    private var islandView: NSView?
    private var islandContentHeight: CGFloat = 200
    private var closeTask: Task<Void, Never>?
    private var targetFrame: CGRect?
    private var transitionID = 0
    private(set) var isExpanded = false
    var isPresented: Bool { panel?.isVisible == true && !suspended }
    var onPresentationChanged: (() -> Void)?
    private var enabled = false
    private var suspended = false
    private var program = "off"
    private var ledCount = 8
    private var clockOrigin: Date?
    private var brightness = 1.0

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(suspend), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(resume), name: name, object: nil)
        }
    }

    deinit {
        closeTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func update(enabled: Bool, program: String, ledCount: Int, clockOrigin: Date?, brightness: Double) {
        self.enabled = enabled
        self.program = program
        self.ledCount = ledCount
        self.clockOrigin = clockOrigin
        self.brightness = brightness
        refresh()
    }

    func setIslandContent(_ view: NSView, height: CGFloat = 200) {
        islandView?.removeFromSuperview()
        islandView = view
        islandContentHeight = height
        view.isHidden = !isExpanded
        containerView?.islandView = view
        containerView?.addSubview(view)
        panel?.ignoresMouseEvents = false
        refresh()
    }

    func setIslandContentHeight(_ height: CGFloat) {
        guard islandContentHeight != height else { return }
        islandContentHeight = height
        refresh(animated: isExpanded)
    }

    func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard islandView != nil, enabled, !suspended, brightness > 0 else { return }
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        closeTask?.cancel()
        closeTask = nil
        refresh(animated: animated)
    }

    func collapse() { setExpanded(false) }

    private func pointerEntered() {
        closeTask?.cancel()
        closeTask = nil
        setExpanded(true)
    }

    private func pointerExited() {
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self,
                  self.panel?.frame.contains(NSEvent.mouseLocation) != true else { return }
            self.setExpanded(false)
        }
    }

    @objc private func screenChanged() { refresh() }
    @objc private func suspend() {
        suspended = true
        refresh()
    }
    @objc private func resume() {
        suspended = false
        refresh()
    }

    private func refresh(animated: Bool = false) {
        guard enabled, !suspended, brightness > 0,
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
        else {
            closeTask?.cancel()
            closeTask = nil
            isExpanded = false
            transitionID += 1
            islandView?.isHidden = true
            containerView?.backdrop.isHidden = true
            targetFrame = nil
            ledView?.stopAnimating()
            panel?.orderOut(nil)
            onPresentationChanged?()
            return
        }
        if panel == nil {
            let panel = NotchOverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = islandView == nil
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.title = "SidePulse Notch"
            let container = NotchInteractionView(frame: .zero)
            container.onEnter = { [weak self] in self?.pointerEntered() }
            container.onExit = { [weak self] in self?.pointerExited() }
            let view = NotchLEDView(frame: .zero)
            container.ledView = view
            container.addSubview(view)
            if let islandView {
                container.islandView = islandView
                container.addSubview(islandView)
            }
            panel.contentView = container
            self.panel = panel
            containerView = container
            ledView = view
        }
        let depth = screen.safeAreaInsets.top
        let width: CGFloat?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            width = right.minX - left.maxX
        } else {
            width = nil
        }
        let displayStyle = NotchDisplayStyle.resolve(notchDepth: depth)
        let collapsed = NotchDisplayGeometry.frame(
            screen: screen.frame,
            notchDepth: depth,
            notchWidth: width,
            style: displayStyle
        )
        let frame = isExpanded
            ? NotchDisplayGeometry.expandedFrame(collapsed: collapsed, screen: screen.frame, contentHeight: islandContentHeight)
            : collapsed
        containerView?.displayStyle = displayStyle
        containerView?.collapsedSize = collapsed.size
        if targetFrame != frame {
            targetFrame = frame
            transitionID += 1
            let transition = transitionID
            if isExpanded {
                // Keep the contents at their final size while the window reveals
                // them. Reflowing every row during expansion makes it stutter.
                containerView?.islandSize = CGSize(width: max(0, frame.width - 32),
                                                   height: max(0, frame.height - collapsed.height - 22))
                containerView?.isExpanded = true
                if islandView?.isHidden == true {
                    islandView?.alphaValue = 0
                    containerView?.backdrop.alphaValue = 0
                }
                islandView?.isHidden = false
                containerView?.backdrop.isHidden = false
                panel?.hasShadow = true
            }
            if animated, panel?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = isExpanded ? 0.36 : 0.26
                    context.timingFunction = isExpanded
                        ? CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                        : CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
                    panel?.animator().setFrame(frame, display: true)
                    islandView?.animator().alphaValue = isExpanded ? 1 : 0
                    containerView?.backdrop.animator().alphaValue = isExpanded ? 1 : 0
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        self?.finishTransition(transition)
                    }
                }
            } else {
                panel?.setFrame(frame, display: true)
                islandView?.alphaValue = isExpanded ? 1 : 0
                containerView?.backdrop.alphaValue = isExpanded ? 1 : 0
                finishTransition(transition)
            }
        }
        containerView?.needsLayout = true
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
        onPresentationChanged?()
        ledView?.configure(
            program: program,
            ledCount: ledCount,
            clockOrigin: clockOrigin,
            brightness: brightness,
            hasNotch: displayStyle.hasPhysicalNotch,
            isSynthetic: displayStyle.isSynthetic
        )
    }

    private func finishTransition(_ transition: Int) {
        guard transitionID == transition else { return }
        if !isExpanded {
            islandView?.isHidden = true
            containerView?.backdrop.isHidden = true
            containerView?.isExpanded = false
            panel?.hasShadow = false
        }
    }
}

@MainActor
private final class NotchOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class NotchInteractionView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    weak var ledView: NSView?
    weak var islandView: NSView?
    let backdrop = NSView()
    var collapsedSize: CGSize = .zero
    var islandSize: CGSize = .zero
    var displayStyle: NotchDisplayStyle = .physicalNotch { didSet { needsLayout = true } }
    var isExpanded = false { didSet { needsLayout = true } }
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.cgColor
        backdrop.isHidden = true
        addSubview(backdrop)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseDown(with event: NSEvent) { onEnter?() }

    override func layout() {
        super.layout()
        ledView?.frame = CGRect(x: (bounds.width - collapsedSize.width) / 2,
                                y: bounds.height - collapsedSize.height,
                                width: collapsedSize.width, height: collapsedSize.height)
        islandView?.frame = CGRect(x: (bounds.width - islandSize.width) / 2,
                                   y: bounds.height - collapsedSize.height - 8 - islandSize.height,
                                   width: islandSize.width, height: islandSize.height)
        backdrop.frame = bounds
        layer?.cornerRadius = isExpanded
            ? 22
            : (displayStyle.isSynthetic ? min(collapsedSize.width, collapsedSize.height) / 2 : 0)
    }
}

@MainActor
final class NotchLEDView: NSView {
    private var programText = ""
    private var ledCount = 8
    private var firmware = LEDFirmwareProgram(program: "off", ledCount: 8)
    private var clockOrigin: Date?
    private var brightness = 1.0
    private var hasNotch = false
    private var isSynthetic = false
    private var colors: [LEDProgramColor] = []
    private var animationDisplayLink: CADisplayLink?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("SidePulse LED status")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { animationDisplayLink?.invalidate() }

    func configure(
        program: String,
        ledCount: Int,
        clockOrigin: Date?,
        brightness: Double,
        hasNotch: Bool,
        isSynthetic: Bool = false
    ) {
        if programText != program || self.ledCount != ledCount {
            programText = program
            self.ledCount = ledCount
            firmware = LEDFirmwareProgram(program: program, ledCount: ledCount)
        }
        self.clockOrigin = clockOrigin
        self.brightness = brightness
        if self.hasNotch != hasNotch || self.isSynthetic != isSynthetic { needsDisplay = true }
        self.hasNotch = hasNotch
        self.isSynthetic = isSynthetic
        if animationDisplayLink == nil {
            let link = displayLink(target: self, selector: #selector(renderFrame))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            animationDisplayLink = link
        }
        renderFrame()
    }

    func stopAnimating() {
        animationDisplayLink?.invalidate()
        animationDisplayLink = nil
    }

    @objc private func renderFrame() {
        let elapsed = clockOrigin.map { max(0, Date.now.timeIntervalSince($0)) } ?? Date.now.timeIntervalSinceReferenceDate
        let next = firmware.frame(at: elapsed).colors.map { $0.scaled(by: brightness) }
        if next != colors {
            colors = next
            needsDisplay = true
        }
        animationDisplayLink?.isPaused = !firmware.needsAnimationFrame(at: elapsed)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        context.saveGState()
        let body: CGPath
        if isSynthetic {
            body = CGPath(
                roundedRect: bounds,
                cornerWidth: min(bounds.width, bounds.height) / 2,
                cornerHeight: min(bounds.width, bounds.height) / 2,
                transform: nil
            )
        } else {
            let path = CGMutablePath()
            let radius: CGFloat = hasNotch ? min(8, bounds.height / 2) : 0
            path.move(to: CGPoint(x: 0, y: bounds.height))
            path.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
            path.addLine(to: CGPoint(x: bounds.width, y: radius))
            path.addQuadCurve(to: CGPoint(x: bounds.width - radius, y: 0), control: CGPoint(x: bounds.width, y: 0))
            path.addLine(to: CGPoint(x: radius, y: 0))
            path.addQuadCurve(to: CGPoint(x: 0, y: radius), control: .zero)
            path.addLine(to: CGPoint(x: 0, y: bounds.height))
            path.closeSubpath()
            body = path
        }
        context.addPath(body)
        context.clip()
        if hasNotch || isSynthetic {
            context.setFillColor(NSColor(calibratedWhite: 0.006, alpha: 0.93).cgColor)
            context.fill(bounds)
        }
        let band = NotchDisplayGeometry.bandHeight
        for x in stride(from: CGFloat.zero, to: bounds.width, by: 2) {
            let width = min(2, bounds.width - x)
            let color = NotchDisplayGeometry.blendedColor(colors, x: x + width / 2, width: bounds.width)
            guard color.peak > 0.001 else { continue }
            fill(context, rect: CGRect(x: x, y: 0, width: width, height: band), color: color, boost: 1.22, alpha: 0.92)
            fill(context, rect: CGRect(x: x, y: 0, width: width, height: 1.15), color: color, boost: 1.46, alpha: 0.72)
            if hasNotch {
                fill(context, rect: CGRect(x: x, y: band, width: width, height: 5), color: color, boost: 0.82, alpha: 0.18)
                fill(context, rect: CGRect(x: x, y: band + 5, width: width, height: 6), color: color, boost: 0.64, alpha: 0.07)
            }
        }
        context.restoreGState()
    }

    private func fill(_ context: CGContext, rect: CGRect, color: LEDProgramColor, boost: Double, alpha: Double) {
        func channel(_ value: Double) -> Double { min(1, pow(max(0, value), 0.86) * boost) }
        context.setFillColor(NSColor(calibratedRed: channel(color.red), green: channel(color.green), blue: channel(color.blue), alpha: alpha).cgColor)
        context.fill(rect)
    }
}
