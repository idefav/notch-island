import AppKit
import QuartzCore

struct IslandShellLayout: Equatable {
    static let singleRowIconsHeight: CGFloat = 52
    static let rowTileHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 6
    static let itemSpacing: CGFloat = 6
    static let maxVisibleWrapRows = 4
    static let chromeHeight: CGFloat = 106
    static let collapsedHitExtension: CGFloat = 2
    static let collapsedVisibleDepth: CGFloat = 1

    static var maxExpandedHeight: CGFloat {
        chromeHeight + iconsHeight(forVisibleRows: maxVisibleWrapRows)
    }

    static func iconsHeight(forVisibleRows rows: Int) -> CGFloat {
        let clamped = max(1, min(maxVisibleWrapRows, rows))
        if clamped == 1 { return singleRowIconsHeight }
        return CGFloat(clamped) * rowTileHeight + CGFloat(clamped - 1) * rowSpacing + 8
    }

    static func wrappedRowCount(itemWidths: [CGFloat], availableWidth: CGFloat, spacing: CGFloat = itemSpacing) -> Int {
        guard !itemWidths.isEmpty else { return 1 }
        let maxRowWidth = max(1, availableWidth)
        var rows = 1
        var currentWidth: CGFloat = 0
        for rawWidth in itemWidths {
            let width = min(rawWidth, maxRowWidth)
            if currentWidth == 0 {
                currentWidth = width
            } else if currentWidth + spacing + width <= maxRowWidth {
                currentWidth += spacing + width
            } else {
                rows += 1
                currentWidth = width
            }
        }
        return rows
    }

    let canvasFrame: CGRect
    let notchHitFrame: CGRect
    let bodyFrame: CGRect
    let panelFrame: CGRect
    let neckWidth: CGFloat
    let notchHeight: CGFloat
    let visibleDepth: CGFloat
    let iconsHeight: CGFloat
    let rowCount: Int
    let needsVerticalScroll: Bool
    let expanded: Bool

    init(screen: CGRect, centerX: CGFloat, contentTop: CGFloat,
         notchWidth: CGFloat, notchHeight: CGFloat, expanded: Bool, itemCount: Int,
         layoutMode: IslandLayoutMode = .wrap, itemWidths: [CGFloat]? = nil) {
        self.notchHeight = notchHeight
        self.expanded = expanded
        neckWidth = notchWidth + 2
        let maxWidth = min(520, max(neckWidth, screen.width - 48))

        let widths = itemWidths ?? Array(repeating: 50 as CGFloat, count: max(0, itemCount))
        let singleRowContentWidth: CGFloat
        if widths.isEmpty {
            singleRowContentWidth = 0
        } else {
            singleRowContentWidth = widths.reduce(0, +) + CGFloat(widths.count - 1) * Self.itemSpacing
        }
        let expandedWidth = max(neckWidth, min(maxWidth, max(316, singleRowContentWidth + 36)))

        let totalRows: Int
        if layoutMode == .wrap, !widths.isEmpty {
            // Horizontal padding inside expandedBody is 15pt * 2 = 30pt plus 4pt inner padding.
            totalRows = Self.wrappedRowCount(itemWidths: widths, availableWidth: expandedWidth - 34)
        } else {
            totalRows = 1
        }
        rowCount = totalRows
        needsVerticalScroll = layoutMode == .wrap && totalRows > Self.maxVisibleWrapRows
        let visibleRows = layoutMode == .wrap ? min(Self.maxVisibleWrapRows, totalRows) : 1
        iconsHeight = Self.iconsHeight(forVisibleRows: visibleRows)
        let expandedHeight = Self.chromeHeight + iconsHeight

        visibleDepth = expanded ? expandedHeight : Self.collapsedVisibleDepth
        let canvasWidth = max(maxWidth, neckWidth) + 28
        let canvasBodyHeight = Self.maxExpandedHeight + 18
        canvasFrame = CGRect(x: centerX - canvasWidth / 2, y: contentTop - canvasBodyHeight,
                             width: canvasWidth, height: canvasBodyHeight + notchHeight)
        notchHitFrame = CGRect(x: centerX - neckWidth / 2, y: contentTop - Self.collapsedHitExtension,
                               width: neckWidth, height: notchHeight + Self.collapsedHitExtension)
        bodyFrame = CGRect(x: centerX - expandedWidth / 2, y: contentTop - expandedHeight,
                           width: expandedWidth, height: expandedHeight)
        if expanded {
            panelFrame = CGRect(x: centerX - expandedWidth / 2, y: contentTop - expandedHeight,
                                width: expandedWidth, height: expandedHeight + notchHeight)
        } else {
            panelFrame = notchHitFrame
        }
    }

    var trackingScreenRects: [CGRect] {
        expanded ? [notchHitFrame, bodyFrame] : [notchHitFrame]
    }

    func containsPointer(_ point: CGPoint) -> Bool {
        if Self.containsInclusiveTop(notchHitFrame, point) { return true }
        return expanded && bodyFrame.contains(point)
    }

    private static func containsInclusiveTop(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX &&
        point.y >= rect.minY && point.y <= rect.maxY + 1
    }

    private struct Metrics {
        let top: CGFloat
        let bottom: CGFloat
        let left: CGFloat
        let right: CGFloat
        let neckLeft: CGFloat
        let neckRight: CGFloat
        let radius: CGFloat
        let topRadius: CGFloat
        let seam: CGFloat
        let shoulder: CGFloat
        let midY: CGFloat
    }

    private var metrics: Metrics {
        let strokeInset: CGFloat = 0.65
        let contentTopLocal = bodyFrame.maxY - canvasFrame.minY
        let centerXLocal = bodyFrame.midX - canvasFrame.minX
        let isCompact = !expanded
        let width = isCompact ? neckWidth : bodyFrame.width
        let left = centerXLocal - width / 2
        let right = centerXLocal + width / 2
        let neckLeft = centerXLocal - neckWidth / 2
        let neckRight = centerXLocal + neckWidth / 2
        let top = contentTopLocal + notchHeight + 1
        let bottom = contentTopLocal - visibleDepth + (isCompact ? 0 : strokeInset)
        let radius = isCompact ? min(9, notchHeight * 0.4) : min(19, visibleDepth * 0.48)
        let topRadius = min(5, notchHeight * 0.25)
        let seam = isCompact ? bottom + radius + 3 : contentTopLocal + 4
        let shoulder = max(bottom + radius, contentTopLocal - min(22, visibleDepth * 0.42))
        let midY = (seam + shoulder) / 2
        return Metrics(top: top, bottom: bottom, left: left, right: right,
                       neckLeft: neckLeft, neckRight: neckRight, radius: radius,
                       topRadius: topRadius, seam: seam, shoulder: shoulder, midY: midY)
    }

    func outline() -> CGPath {
        let m = metrics
        let path = CGMutablePath()
        path.move(to: CGPoint(x: m.neckLeft + m.topRadius, y: m.top))
        path.addQuadCurve(to: CGPoint(x: m.neckLeft, y: m.top - m.topRadius),
                          control: CGPoint(x: m.neckLeft, y: m.top))
        addContourBody(to: path, metrics: m)
        path.addLine(to: CGPoint(x: m.neckRight, y: m.top - m.topRadius))
        path.addQuadCurve(to: CGPoint(x: m.neckRight - m.topRadius, y: m.top),
                          control: CGPoint(x: m.neckRight, y: m.top))
        path.closeSubpath()
        return path
    }

    /// Open U-shaped contour along the visible boundary (omitting the top edge hidden behind the display bezel).
    func highlightPath() -> CGPath {
        let m = metrics
        let path = CGMutablePath()
        path.move(to: CGPoint(x: m.neckLeft, y: m.top - m.topRadius))
        addContourBody(to: path, metrics: m)
        path.addLine(to: CGPoint(x: m.neckRight, y: m.top - m.topRadius))
        return path
    }

    private func addContourBody(to path: CGMutablePath, metrics m: Metrics) {
        path.addLine(to: CGPoint(x: m.neckLeft, y: m.seam))
        path.addCurve(to: CGPoint(x: m.left, y: m.shoulder),
                      control1: CGPoint(x: m.neckLeft, y: m.midY),
                      control2: CGPoint(x: m.left, y: m.midY))
        path.addLine(to: CGPoint(x: m.left, y: m.bottom + m.radius))
        path.addQuadCurve(to: CGPoint(x: m.left + m.radius, y: m.bottom),
                          control: CGPoint(x: m.left, y: m.bottom))
        path.addLine(to: CGPoint(x: m.right - m.radius, y: m.bottom))
        path.addQuadCurve(to: CGPoint(x: m.right, y: m.bottom + m.radius),
                          control: CGPoint(x: m.right, y: m.bottom))
        path.addLine(to: CGPoint(x: m.right, y: m.shoulder))
        path.addCurve(to: CGPoint(x: m.neckRight, y: m.seam),
                      control1: CGPoint(x: m.right, y: m.midY),
                      control2: CGPoint(x: m.neckRight, y: m.midY))
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
        updateContentsScale()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        for sublayer in [surface, bloom, highlight] {
            sublayer.contentsScale = scale
        }
    }

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
        let fillPath = layout.outline()
        let strokePath = layout.highlightPath()
        let sameCanvas = previous?.canvasFrame.size == layout.canvasFrame.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.shadowOpacity = layout.visibleDepth > 10 ? 0.18 : 0
        updateShape(surface, to: fillPath, size: layout.canvasFrame.size,
                    animated: animated && sameCanvas && !reduceMotion, syncShadow: true)
        for shape in [bloom, highlight] {
            updateShape(shape, to: strokePath, size: layout.canvasFrame.size,
                        animated: animated && sameCanvas && !reduceMotion, syncShadow: false)
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

    private func updateShape(_ shape: CAShapeLayer, to path: CGPath, size: CGSize,
                             animated: Bool, syncShadow: Bool) {
        let fromPath = shape.presentation()?.path ?? shape.path
        let fromShadow = syncShadow ? (shape.presentation()?.shadowPath ?? shape.shadowPath) : nil
        shape.frame = CGRect(origin: .zero, size: size)
        shape.path = path
        if syncShadow { shape.shadowPath = path }
        if animated, let fromPath {
            let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.75, 0.25, 1)
            let morph = CABasicAnimation(keyPath: "path")
            morph.fromValue = fromPath
            morph.toValue = path
            morph.duration = 0.24
            morph.timingFunction = timing
            shape.add(morph, forKey: "shape")
            if syncShadow, let fromShadow {
                let shadowMorph = CABasicAnimation(keyPath: "shadowPath")
                shadowMorph.fromValue = fromShadow
                shadowMorph.toValue = path
                shadowMorph.duration = 0.24
                shadowMorph.timingFunction = timing
                shape.add(shadowMorph, forKey: "shadowShape")
            }
        } else {
            shape.removeAnimation(forKey: "shape")
            if syncShadow { shape.removeAnimation(forKey: "shadowShape") }
        }
    }

    func playHighlight(reduceMotion: Bool) {
        guard highlight.animation(forKey: "sweep") == nil else { return }
        if reduceMotion {
            let fade = keyframes("opacity", values: [0, 0.36, 0], times: [0, 0.4, 1], duration: 0.18)
            highlight.add(fade, forKey: "sweep")
            return
        }
        sweep(bloom, length: 0.20, opacity: 0.14)
        sweep(highlight, length: 0.12, opacity: 0.92)
    }

    func stopHighlight() {
        bloom.removeAnimation(forKey: "sweep")
        highlight.removeAnimation(forKey: "sweep")
    }

    private func sweep(_ shape: CAShapeLayer, length: Double, opacity: Double) {
        let duration = 0.95
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
