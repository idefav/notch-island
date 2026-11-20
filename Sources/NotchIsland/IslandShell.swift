import AppKit
import QuartzCore

struct IslandShellLayout: Equatable {
    let canvasFrame: CGRect
    let contentFrame: CGRect
    let neckWidth: CGFloat
    let notchHeight: CGFloat
    let visibleDepth: CGFloat

    init(screen: CGRect, centerX: CGFloat, contentTop: CGFloat,
         notchWidth: CGFloat, notchHeight: CGFloat, expanded: Bool, itemCount: Int) {
        let maxWidth = min(400, screen.width - 24)
        self.notchHeight = notchHeight
        neckWidth = notchWidth + 2
        let expandedWidth = max(neckWidth, min(maxWidth, max(316, CGFloat(itemCount) * 55 + 40)))
        let width = expanded ? expandedWidth : neckWidth
        let height: CGFloat = expanded ? 150 : 10
        visibleDepth = expanded ? height : 1
        let canvasWidth = max(maxWidth, neckWidth) + 24
        canvasFrame = CGRect(x: centerX - canvasWidth / 2, y: contentTop - 166,
                             width: canvasWidth, height: 166 + notchHeight)
        contentFrame = CGRect(x: centerX - width / 2, y: contentTop - height,
                              width: width, height: height)
    }

    func outline() -> CGPath {
        let strokeInset: CGFloat = 0.65
        let content = contentFrame.offsetBy(dx: -canvasFrame.minX, dy: -canvasFrame.minY)
        let top = content.maxY + notchHeight + 1
        let bottom = content.maxY - visibleDepth + (visibleDepth > 1 ? strokeInset : 0)
        let left = content.minX
        let right = content.maxX
        let neckLeft = content.midX - neckWidth / 2
        let neckRight = content.midX + neckWidth / 2
        let isCompact = visibleDepth == 1
        let radius = isCompact ? min(9, notchHeight * 0.4) : min(19, visibleDepth * 0.48)
        let topRadius = min(5, notchHeight * 0.25)
        let seam = isCompact ? bottom + radius + 3 : content.maxY + 4
        let shoulder = max(bottom + radius, content.maxY - min(21, visibleDepth * 0.42))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: neckLeft + topRadius, y: top))
        path.addQuadCurve(to: CGPoint(x: neckLeft, y: top - topRadius),
                          control: CGPoint(x: neckLeft, y: top))
        path.addLine(to: CGPoint(x: neckLeft, y: seam))
        path.addCurve(to: CGPoint(x: left, y: shoulder),
                      control1: CGPoint(x: neckLeft, y: shoulder + 6),
                      control2: CGPoint(x: left, y: seam + 2))
        path.addLine(to: CGPoint(x: left, y: bottom + radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: right, y: bottom + radius), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right, y: shoulder))
        path.addCurve(to: CGPoint(x: neckRight, y: seam),
                      control1: CGPoint(x: right, y: seam + 2),
                      control2: CGPoint(x: neckRight, y: shoulder + 6))
        path.addLine(to: CGPoint(x: neckRight, y: top - topRadius))
        path.addQuadCurve(to: CGPoint(x: neckRight - topRadius, y: top),
                          control: CGPoint(x: neckRight, y: top))
        path.closeSubpath()
        return path
    }
}

@MainActor
final class IslandShellView: NSView {
    private let surface = CAShapeLayer()
    private let bloom = CAShapeLayer()
    private let highlight = CAShapeLayer()
    private var currentLayout: IslandShellLayout?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        surface.fillColor = NSColor(srgbRed: 0.025, green: 0.032, blue: 0.041, alpha: 1).cgColor
        surface.shadowColor = NSColor.black.cgColor
        surface.shadowRadius = 5
        surface.shadowOffset = CGSize(width: 0, height: -2)
        let cyan = NSColor(srgbRed: 0.31, green: 0.90, blue: 0.88, alpha: 1)
        configureStroke(bloom, width: 4.5, color: cyan, opacity: 0)
        configureStroke(highlight, width: 1.15, color: cyan, opacity: 0)
        for sublayer in [surface, bloom, highlight] {
            layer?.addSublayer(sublayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureStroke(_ stroke: CAShapeLayer, width: CGFloat, color: NSColor, opacity: Float) {
        stroke.fillColor = nil
        stroke.strokeColor = color.cgColor
        stroke.lineWidth = width
        stroke.lineCap = .round
        stroke.lineJoin = .round
        stroke.opacity = opacity
    }

    func display(_ layout: IslandShellLayout, animated: Bool, reduceMotion: Bool) {
        let previous = currentLayout
        guard previous != layout else { return }
        currentLayout = layout
        let path = layout.outline()
        let sameCanvas = previous?.canvasFrame.size == layout.canvasFrame.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.shadowOpacity = layout.visibleDepth > 10 ? 0.18 : 0
        for shape in [surface, bloom, highlight] {
            let from = shape.presentation()?.path ?? shape.path
            shape.frame = CGRect(origin: .zero, size: layout.canvasFrame.size)
            shape.path = path
            if animated, sameCanvas, !reduceMotion, let from {
                let morph = CABasicAnimation(keyPath: "path")
                morph.fromValue = from
                morph.toValue = path
                morph.duration = 0.24
                morph.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.25, 1)
                shape.add(morph, forKey: "shape")
            } else {
                shape.removeAnimation(forKey: "shape")
            }
        }
        if reduceMotion, animated {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.74
            fade.toValue = 1
            fade.duration = 0.09
            surface.add(fade, forKey: "fade")
        }
        CATransaction.commit()
    }

    func playHighlight(reduceMotion: Bool) {
        guard highlight.animation(forKey: "sweep") == nil else { return }
        if reduceMotion {
            let fade = keyframes("opacity", values: [0, 0.36, 0], times: [0, 0.4, 1], duration: 0.18)
            highlight.add(fade, forKey: "sweep")
            return
        }
        sweep(bloom, length: 0.17, opacity: 0.14)
        sweep(highlight, length: 0.10, opacity: 0.92)
    }

    func stopHighlight() {
        bloom.removeAnimation(forKey: "sweep")
        highlight.removeAnimation(forKey: "sweep")
    }

    private func sweep(_ shape: CAShapeLayer, length: Double, opacity: Double) {
        let duration = 1.05
        let start = keyframes("strokeStart", values: [0, 0, 1 - length, 1],
                              times: [0, length, 0.87, 1], duration: duration)
        let end = keyframes("strokeEnd", values: [0, length, 1, 1],
                            times: [0, length, 0.87, 1], duration: duration)
        let fade = keyframes("opacity", values: [0, opacity, opacity * 0.65, 0],
                             times: [0, 0.14, 0.78, 1], duration: duration)
        let animation = CAAnimationGroup()
        animation.animations = [start, end, fade]
        animation.duration = duration
        shape.add(animation, forKey: "sweep")
    }

    private func keyframes(_ property: String, values: [Double], times: [Double],
                           duration: TimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: property)
        animation.values = values
        animation.keyTimes = times.map(NSNumber.init(value:))
        animation.duration = duration
        return animation
    }
}
