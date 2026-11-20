import AppKit
import CoreGraphics
import Darwin

struct StatusImage {
    let image: CGImage
    let signature: [Float]

    init(image: CGImage, frame: CGRect) {
        self.image = image
        let sampleHeight = min(image.height, Int(24 * CGFloat(image.height) / frame.height))
        let crop = CGRect(x: 0, y: (image.height - sampleHeight) / 2, width: image.width, height: sampleHeight)
        let centralImage = image.cropping(to: crop) ?? image
        var pixels = [UInt8](repeating: 0, count: 48 * 20 * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 48, height: 20,
                                          bitsPerComponent: 8, bytesPerRow: 48 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(centralImage, in: CGRect(x: 0, y: 0, width: 48, height: 20))
            return true
        }
        guard rendered else { signature = []; return }
        signature = Self.normalized(stride(from: 0, to: pixels.count, by: 4).map { index in
            let luminance = Float(pixels[index]) * 0.21 + Float(pixels[index + 1]) * 0.72 + Float(pixels[index + 2]) * 0.07
            return Float(pixels[index + 3]) * 0.55 + luminance * 0.45
        })
    }

    private static func normalized(_ samples: [Float]) -> [Float] {
        let mean = samples.reduce(0, +) / Float(samples.count)
        let centered = samples.map { $0 - mean }
        let magnitude = sqrt(centered.reduce(0) { $0 + $1 * $1 })
        return magnitude > 80 ? centered.map { $0 / magnitude } : []
    }

    func similarity(to other: StatusImage) -> Float {
        guard !signature.isEmpty, signature.count == other.signature.count else { return 0 }
        return abs(zip(signature, other.signature).reduce(0) { $0 + $1.0 * $1.1 })
    }
}

@MainActor
final class StatusImageReader {
    private typealias Capture = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    // ScreenCaptureKit omits some hidden menu bar windows on macOS 26.
    // Resolve the legacy single-window capture at runtime and keep it optional.
    private let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)

    func read(_ window: StatusWindow) -> StatusImage? {
        guard let framework,
              let symbol = dlsym(framework, "SLWindowListCreateImageFromArray"),
              let windowPointer = UnsafeRawPointer(bitPattern: UInt(window.id)) else { return nil }
        var pointer: UnsafeRawPointer? = windowPointer
        var callbacks = CFArrayCallBacks(version: 0, retain: nil, release: nil, copyDescription: nil, equal: nil)
        guard let windowIDs = CFArrayCreate(nil, &pointer, 1, &callbacks) else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let options = CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution)
        guard let image = capture(.null, windowIDs, options.rawValue)?.takeRetainedValue(),
              image.width <= 2_048, image.height <= 256 else { return nil }
        return StatusImage(image: image, frame: window.frame)
    }
}

struct IslandItem: Identifiable {
    let window: StatusWindow
    let name: String
    let image: NSImage?
    let mirror: StatusWindow?
    let bundleIdentifier: String?
    var id: CGWindowID { window.id }
}

@MainActor
final class ItemCatalog {
    private let capture = StatusImageReader()

    func items(in snapshot: StatusSnapshot, display: NotchedDisplay) -> [IslandItem] {
        let canCapture = CGPreflightScreenCaptureAccess()
        let mirrors = snapshot.windows.filter { $0.visible && !StatusSnapshot.onMenuBar($0.frame, display.bounds) }
        var mirrorImages = [CGWindowID: StatusImage]()
        if canCapture {
            for window in mirrors where snapshot.overflow.contains(where: { abs($0.frame.width - window.frame.width) <= 1 }) {
                mirrorImages[window.id] = capture.read(window)
            }
        }
        return snapshot.overflow.enumerated().map { index, window in
            let icon = canCapture ? capture.read(window) : nil
            let mirror = match(window, icon: icon, mirrors: mirrors, images: mirrorImages)
            let nameHint = mirror?.hasIdentifyingTitle == true ? mirror?.title : window.hasIdentifyingTitle ? window.title : nil
            let owner = NSRunningApplication(processIdentifier: window.owner)
            let app = nameHint.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            let specificOwner = owner?.bundleIdentifier != "com.apple.controlcenter" ? owner : nil
            let name = app?.localizedName ?? specificOwner?.localizedName ?? nameHint ?? "菜单栏图标 \(index + 1)"
            let image = icon.map { image in
                let scale = min(1, 88 / window.frame.width)
                let size = NSSize(width: window.frame.width * scale, height: window.frame.height * scale)
                return NSImage(cgImage: image.image, size: size)
            } ?? app?.icon ?? specificOwner?.icon
            return IslandItem(window: window, name: name, image: image, mirror: mirror,
                              bundleIdentifier: app?.bundleIdentifier ?? specificOwner?.bundleIdentifier)
        }
    }

    private func match(_ hidden: StatusWindow, icon: StatusImage?, mirrors: [StatusWindow],
                       images: [CGWindowID: StatusImage]) -> StatusWindow? {
        let sameSize = mirrors.filter { $0.owner == hidden.owner && abs($0.frame.width - hidden.frame.width) <= 1 }
        if hidden.hasIdentifyingTitle {
            let named = sameSize.filter { $0.title == hidden.title }
            if named.count == 1 { return named[0] }
        }
        guard let icon else { return nil }
        let scores = sameSize.compactMap { candidate in
            images[candidate.id].map { (window: candidate, score: icon.similarity(to: $0)) }
        }.sorted { $0.score > $1.score }
        guard let best = scores.first, best.score >= 0.95,
              best.score - (scores.dropFirst().first?.score ?? 0) >= 0.09 else { return nil }
        return best.window
    }
}
