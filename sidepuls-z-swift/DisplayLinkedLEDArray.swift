import AppKit
import QuartzCore
import SwiftUI

enum LEDArrayPreviewStyle: Sendable {
    case commandCenter
    case menuBar

    var dotSize: CGFloat {
        switch self {
        case .commandCenter: 34
        case .menuBar: 18
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .commandCenter: 7
        case .menuBar: 6
        }
    }

    var labelWidth: CGFloat {
        switch self {
        case .commandCenter: 14
        case .menuBar: 11
        }
    }

    var labelGap: CGFloat {
        switch self {
        case .commandCenter: 8
        case .menuBar: 6
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .commandCenter: 10
        case .menuBar: 5
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .commandCenter: 9
        case .menuBar: 9
        }
    }

    var shadowRadius: CGFloat {
        switch self {
        case .commandCenter: 8
        case .menuBar: 4
        }
    }

    func size(ledCount: Int) -> CGSize {
        let count = CGFloat(max(1, min(8, ledCount)))
        return CGSize(
            width: labelWidth + labelGap + dotSize,
            height: (count * dotSize) + (max(0, count - 1) * rowSpacing)
        )
    }
}

/// A layer-backed LED preview driven directly by the display that contains it.
/// This avoids rebuilding a SwiftUI hierarchy for every animation frame.
struct DisplayLinkedLEDArray: NSViewRepresentable {
    var program: String
    var ledCount: Int
    var clockOrigin: Date?
    var style: LEDArrayPreviewStyle

    func makeNSView(context: Context) -> DisplayLinkedLEDArrayNSView {
        DisplayLinkedLEDArrayNSView(
            program: program,
            ledCount: ledCount,
            clockOrigin: clockOrigin,
            style: style
        )
    }

    func updateNSView(_ nsView: DisplayLinkedLEDArrayNSView, context: Context) {
        nsView.configure(
            program: program,
            ledCount: ledCount,
            clockOrigin: clockOrigin
        )
    }
}

@MainActor
final class DisplayLinkedLEDArrayNSView: NSView {
    private let style: LEDArrayPreviewStyle
    private var programText: String
    private var ledCount: Int
    private var clockOrigin: Date?
    private var firmware: LEDFirmwareProgram
    private var animationDisplayLink: CADisplayLink?
    private var dotLayers: [CAShapeLayer] = []
    private var labelLayers: [CATextLayer] = []
    private var lastColors: [LEDProgramColor] = []

    init(
        program: String,
        ledCount: Int,
        clockOrigin: Date?,
        style: LEDArrayPreviewStyle
    ) {
        let count = max(1, min(8, ledCount))
        self.style = style
        programText = program
        self.ledCount = count
        self.clockOrigin = clockOrigin
        firmware = LEDFirmwareProgram(program: program, ledCount: count)
        super.init(frame: .zero)
        wantsLayer = true
        rebuildLayers()
        updateFrame(at: Date.now)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAccessibilityLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        animationDisplayLink?.invalidate()
    }

    override var intrinsicContentSize: NSSize {
        style.size(ledCount: ledCount)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if window == nil {
            animationDisplayLink?.invalidate()
            animationDisplayLink = nil
        } else if animationDisplayLink == nil {
            let displayLink = displayLink(
                target: self,
                selector: #selector(displayLinkDidFire(_:))
            )
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 120,
                maximum: 120,
                preferred: 120
            )
            displayLink.add(to: .main, forMode: .common)
            animationDisplayLink = displayLink
        }
        if let window {
            for name in [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(displayVisibilityDidChange(_:)),
                    name: name,
                    object: window
                )
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(displayVisibilityDidChange(_:)),
                name: NSApplication.didHideNotification,
                object: NSApp
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(displayVisibilityDidChange(_:)),
                name: NSApplication.didUnhideNotification,
                object: NSApp
            )
            updateFrame(at: .now)
        }
    }

    override func layout() {
        super.layout()
        let scale = window?.screen?.backingScaleFactor ?? 2
        let labelFont = NSFont.monospacedDigitSystemFont(
            ofSize: style.fontSize,
            weight: style == .commandCenter ? .semibold : .medium
        )
        let labelHeight = ceil(labelFont.ascender - labelFont.descender + labelFont.leading)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<ledCount {
            let y = CGFloat(index) * (style.dotSize + style.rowSpacing)
            let dotFrame = CGRect(
                x: style.labelWidth + style.labelGap,
                y: y,
                width: style.dotSize,
                height: style.dotSize
            )
            let dot = dotLayers[index]
            dot.frame = dotFrame
            dot.path = CGPath(
                roundedRect: CGRect(origin: .zero, size: dotFrame.size),
                cornerWidth: style.cornerRadius,
                cornerHeight: style.cornerRadius,
                transform: nil
            )
            dot.shadowPath = dot.path
            dot.contentsScale = scale

            let label = labelLayers[index]
            label.frame = CGRect(
                x: 0,
                y: y + ((style.dotSize - labelHeight) / 2),
                width: style.labelWidth,
                height: labelHeight
            )
            label.contentsScale = scale
            label.font = labelFont
            label.fontSize = style.fontSize
        }
        CATransaction.commit()
    }

    func configure(program: String, ledCount: Int, clockOrigin: Date?) {
        let count = max(1, min(8, ledCount))
        let programChanged = programText != program || self.ledCount != count
        let countChanged = self.ledCount != count
        programText = program
        self.ledCount = count
        self.clockOrigin = clockOrigin

        if programChanged {
            firmware = LEDFirmwareProgram(program: program, ledCount: count)
        }
        if countChanged {
            rebuildLayers()
            invalidateIntrinsicContentSize()
            updateAccessibilityLabel()
        }
        updateFrame(at: Date.now)
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        guard isDisplayVisible else {
            displayLink.isPaused = true
            return
        }
        updateFrame(at: Date.now)
    }

    @objc private func displayVisibilityDidChange(_ notification: Notification) {
        updateFrame(at: .now)
    }

    private var isDisplayVisible: Bool {
        guard let window else { return false }
        return window.isVisible
            && !window.isMiniaturized
            && !NSApp.isHidden
            && window.occlusionState.contains(.visible)
    }

    private func updateFrame(at date: Date) {
        let elapsed = clockOrigin.map { max(0, date.timeIntervalSince($0)) }
            ?? date.timeIntervalSinceReferenceDate
        let colors = firmware.frame(at: elapsed).colors
        animationDisplayLink?.isPaused = !isDisplayVisible
            || !firmware.needsAnimationFrame(at: elapsed)
        guard colors != lastColors else { return }
        lastColors = colors

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in 0..<ledCount {
            let output = colors.indices.contains(index) ? colors[index] : .black
            let color = NSColor(
                srgbRed: output.red,
                green: output.green,
                blue: output.blue,
                alpha: 1
            ).cgColor
            let dot = dotLayers[index]
            dot.fillColor = color
            dot.shadowColor = color
            dot.shadowOpacity = Float(min(0.88, output.peak * 1.15))
        }
        CATransaction.commit()
    }

    private func rebuildLayers() {
        dotLayers.forEach { $0.removeFromSuperlayer() }
        labelLayers.forEach { $0.removeFromSuperlayer() }
        dotLayers.removeAll(keepingCapacity: true)
        labelLayers.removeAll(keepingCapacity: true)
        lastColors.removeAll(keepingCapacity: true)

        for index in 0..<ledCount {
            let dot = CAShapeLayer()
            dot.fillColor = NSColor.black.cgColor
            dot.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
            dot.lineWidth = style == .commandCenter ? 1 : 0.6
            dot.shadowRadius = style.shadowRadius
            dot.shadowOffset = .zero
            layer?.addSublayer(dot)
            dotLayers.append(dot)

            let label = CATextLayer()
            label.string = "\(index + 1)"
            label.alignmentMode = .right
            label.foregroundColor = NSColor.secondaryLabelColor.cgColor
            layer?.addSublayer(label)
            labelLayers.append(label)
        }
        needsLayout = true
    }

    private func updateAccessibilityLabel() {
        setAccessibilityLabel(
            "Live SidePulse array, LED \(ledCount) at top through LED 1 at bottom"
        )
    }
}
