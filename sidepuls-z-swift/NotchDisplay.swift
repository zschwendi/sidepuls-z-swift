import AppKit
import QuartzCore

/// Native adaptation of Peter Kuhar's SidePulse Notch geometry and light blend.
/// Source: inteliwear/sidepulse, virtual_device.py, MIT (see NOTICE).
enum NotchDisplayGeometry {
    static let bandHeight: CGFloat = 5

    static func frame(screen: CGRect, notchDepth: CGFloat, notchWidth: CGFloat?) -> CGRect {
        let width = min(screen.width, notchWidth.map { max(180, min(320, $0)) } ?? 220)
        let height = max(0, notchDepth) + bandHeight
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - height, width: width, height: height)
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

    @objc private func screenChanged() { refresh() }
    @objc private func suspend() {
        suspended = true
        refresh()
    }
    @objc private func resume() {
        suspended = false
        refresh()
    }

    private func refresh() {
        guard enabled, !suspended, brightness > 0,
              let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first
        else {
            ledView?.stopAnimating()
            panel?.orderOut(nil)
            return
        }
        if panel == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.title = "SidePulse Notch"
            let view = NotchLEDView(frame: .zero)
            panel.contentView = view
            self.panel = panel
            ledView = view
        }
        let depth = screen.safeAreaInsets.top
        let width: CGFloat?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           right.minX - left.maxX >= 120 {
            width = right.minX - left.maxX
        } else {
            width = nil
        }
        let frame = NotchDisplayGeometry.frame(screen: screen.frame, notchDepth: depth, notchWidth: width)
        if panel?.frame != frame { panel?.setFrame(frame, display: true) }
        if panel?.isVisible != true { panel?.orderFrontRegardless() }
        ledView?.configure(program: program, ledCount: ledCount, clockOrigin: clockOrigin, brightness: brightness, hasNotch: depth > 0)
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

    func configure(program: String, ledCount: Int, clockOrigin: Date?, brightness: Double, hasNotch: Bool) {
        if programText != program || self.ledCount != ledCount {
            programText = program
            self.ledCount = ledCount
            firmware = LEDFirmwareProgram(program: program, ledCount: ledCount)
        }
        self.clockOrigin = clockOrigin
        self.brightness = brightness
        if self.hasNotch != hasNotch { needsDisplay = true }
        self.hasNotch = hasNotch
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
        let body = CGMutablePath()
        let radius: CGFloat = hasNotch ? min(8, bounds.height / 2) : 0
        body.move(to: CGPoint(x: 0, y: bounds.height))
        body.addLine(to: CGPoint(x: bounds.width, y: bounds.height))
        body.addLine(to: CGPoint(x: bounds.width, y: radius))
        body.addQuadCurve(to: CGPoint(x: bounds.width - radius, y: 0), control: CGPoint(x: bounds.width, y: 0))
        body.addLine(to: CGPoint(x: radius, y: 0))
        body.addQuadCurve(to: CGPoint(x: 0, y: radius), control: .zero)
        body.addLine(to: CGPoint(x: 0, y: bounds.height))
        body.closeSubpath()
        context.addPath(body)
        context.clip()
        if hasNotch {
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
