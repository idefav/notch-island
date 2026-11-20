import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

private func gradient(_ context: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                    colors: colors as CFArray, locations: nil) else { return }
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

private func rail() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 286, y: 734))
    path.addLine(to: CGPoint(x: 286, y: 504))
    path.addCurve(to: CGPoint(x: 420, y: 370),
                  control1: CGPoint(x: 286, y: 416), control2: CGPoint(x: 335, y: 370))
    path.addLine(to: CGPoint(x: 604, y: 370))
    path.addCurve(to: CGPoint(x: 738, y: 504),
                  control1: CGPoint(x: 689, y: 370), control2: CGPoint(x: 738, y: 416))
    path.addLine(to: CGPoint(x: 738, y: 734))
    return path
}

private func drawIcon(pixels: Int) -> CGImage? {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let small = pixels <= 64
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let tile = CGPath(roundedRect: CGRect(x: 93, y: 93, width: 838, height: 838),
                      cornerWidth: 199, cornerHeight: 199, transform: nil)
    context.saveGState()
    context.addPath(tile)
    context.clip()
    gradient(context, [color(0.15, 0.20, 0.25), color(0.036, 0.052, 0.072)],
             from: CGPoint(x: 215, y: 927), to: CGPoint(x: 813, y: 104))
    if !small {
        context.setStrokeColor(color(0.63, 0.78, 0.82, 0.19))
        context.setLineWidth(6)
        context.addPath(tile)
        context.strokePath()
        context.setStrokeColor(color(0.53, 0.71, 0.75, 0.08))
        context.setLineWidth(3)
        context.addPath(CGPath(roundedRect: CGRect(x: 109, y: 109, width: 806, height: 806),
                               cornerWidth: 183, cornerHeight: 183, transform: nil))
        context.strokePath()
    }

    let housing = CGMutablePath()
    housing.move(to: CGPoint(x: 334, y: 932))
    housing.addLine(to: CGPoint(x: 334, y: 554))
    housing.addQuadCurve(to: CGPoint(x: 436, y: 451), control: CGPoint(x: 334, y: 451))
    housing.addLine(to: CGPoint(x: 588, y: 451))
    housing.addQuadCurve(to: CGPoint(x: 690, y: 554), control: CGPoint(x: 690, y: 451))
    housing.addLine(to: CGPoint(x: 690, y: 932))
    housing.closeSubpath()
    context.saveGState()
    context.addPath(housing)
    context.clip()
    gradient(context, [color(0.016, 0.021, 0.033), color(0.033, 0.054, 0.073)],
             from: CGPoint(x: 500, y: 850), to: CGPoint(x: 500, y: 451))
    context.restoreGState()

    let contour = rail()
    context.setLineWidth(small ? 48 : 28)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    if !small {
        context.saveGState()
        context.setShadow(offset: .zero, blur: 22, color: color(0.21, 0.90, 0.83, 0.72))
        context.setStrokeColor(color(0.15, 0.70, 0.68, 0.78))
        context.addPath(contour)
        context.strokePath()
        context.restoreGState()
    }
    context.saveGState()
    context.addPath(contour)
    context.replacePathWithStrokedPath()
    context.clip()
    gradient(context, [color(0.12, 0.51, 0.58), color(0.27, 0.83, 0.81), color(0.61, 1, 0.94), color(0.33, 0.78, 0.90)],
             from: CGPoint(x: 270, y: 754), to: CGPoint(x: 759, y: 365))
    context.restoreGState()

    if !small {
        let gleam = CGMutablePath()
        gleam.move(to: CGPoint(x: 592, y: 370))
        gleam.addLine(to: CGPoint(x: 604, y: 370))
        gleam.addCurve(to: CGPoint(x: 738, y: 504),
                       control1: CGPoint(x: 689, y: 370), control2: CGPoint(x: 738, y: 416))
        gleam.addLine(to: CGPoint(x: 738, y: 543))
        context.setLineWidth(10)
        context.setStrokeColor(color(0.77, 1, 0.97, 0.92))
        context.addPath(gleam)
        context.strokePath()
    }
    context.restoreGState()
    return context.makeImage()
}

private enum ArtworkError: Error {
    case missingIconsetDirectory
    case renderFailed(String)
}

guard CommandLine.arguments.count == 2 else { throw ArtworkError.missingIconsetDirectory }
let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "icon_\(points)x\(points)\(suffix).png"
        let file = iconset.appendingPathComponent(filename)
        guard let image = drawIcon(pixels: size),
              let output = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw ArtworkError.renderFailed(filename) }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw ArtworkError.renderFailed(filename) }
    }
}
