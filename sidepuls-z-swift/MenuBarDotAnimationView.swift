import AppKit
import QuartzCore

/// A persistent, layer-backed status-item icon. Updating layer colors avoids
/// routing every animation frame through NSButton's image replacement path.
@MainActor
final class MenuBarDotAnimationView: NSView {
    static let preferredSize = NSSize(width: 28, height: 16)

    private let pillLayer = CAShapeLayer()
    private var dotLayers: [CAShapeLayer] = []
    private var style: MenuBarIconStyle = .horizontalEight

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
        wantsLayer = true
        layer?.masksToBounds = false

        pillLayer.fillColor = NSColor.white.withAlphaComponent(0.46).cgColor
        pillLayer.strokeColor = NSColor.black.withAlphaComponent(0.1).cgColor
        pillLayer.lineWidth = 0.45
        layer?.addSublayer(pillLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        guard !dotLayers.isEmpty else { return }

        let diameter: CGFloat = style == .horizontalEight ? 2.6 : 4.2
        let spacing: CGFloat = style == .horizontalEight ? 0.65 : 0.7
        let totalLength = CGFloat(dotLayers.count) * diameter
            + CGFloat(max(0, dotLayers.count - 1)) * spacing
        let horizontalPadding: CGFloat = dotLayers.count > 4 ? 1.15 : 2
        let verticalPadding: CGFloat = dotLayers.count > 4 ? 2.1 : 1.65
        let pillRect = CGRect(
            x: bounds.midX - (totalLength + horizontalPadding * 2) / 2,
            y: bounds.midY - (diameter + verticalPadding * 2) / 2,
            width: totalLength + horizontalPadding * 2,
            height: diameter + verticalPadding * 2
        )
        let scale = window?.screen?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillLayer.frame = bounds
        pillLayer.path = CGPath(
            roundedRect: pillRect,
            cornerWidth: pillRect.height / 2,
            cornerHeight: pillRect.height / 2,
            transform: nil
        )
        pillLayer.contentsScale = scale

        for index in dotLayers.indices {
            let dot = dotLayers[index]
            dot.frame = CGRect(
                x: bounds.midX - totalLength / 2 + CGFloat(index) * (diameter + spacing),
                y: bounds.midY - diameter / 2,
                width: diameter,
                height: diameter
            )
            dot.path = CGPath(ellipseIn: CGRect(origin: .zero, size: dot.bounds.size), transform: nil)
            dot.contentsScale = scale
        }
        CATransaction.commit()
    }

    func render(
        style: MenuBarIconStyle,
        sourceColors: [LEDProgramColor]
    ) {
        let colors = MenuBarDotLayout.colors(for: style, sourceColors: sourceColors)

        let geometryChanged = self.style != style || dotLayers.count != colors.count
        self.style = style
        if dotLayers.count != colors.count {
            rebuildDots(count: colors.count)
        }
        if geometryChanged {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }

        let brightnessBoost = 2.2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in dotLayers.indices {
            let output = colors.indices.contains(index) ? colors[index] : .black
            let visible = output.peak > 0.004
            let dot = dotLayers[index]
            dot.isHidden = !visible
            if visible {
                dot.fillColor = NSColor(
                    srgbRed: min(1, output.red * brightnessBoost),
                    green: min(1, output.green * brightnessBoost),
                    blue: min(1, output.blue * brightnessBoost),
                    alpha: 1
                ).cgColor
            }
        }
        CATransaction.commit()
    }

    private func rebuildDots(count: Int) {
        dotLayers.forEach { $0.removeFromSuperlayer() }
        dotLayers.removeAll(keepingCapacity: true)

        for _ in 0..<count {
            let dot = CAShapeLayer()
            dot.fillColor = NSColor.clear.cgColor
            layer?.addSublayer(dot)
            dotLayers.append(dot)
        }
    }
}
