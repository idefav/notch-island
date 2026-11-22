import AppKit
import CoreGraphics
import Darwin

enum StatusImageAdapter {
    /// Adapts captured status bar icons for clear legibility on the dark Dynamic Island surface:
    /// 1. Ignores faint translucent window backdrop pixels (e.g. macOS 26 menu bar vibrancy floor) when analyzing foreground strokes.
    /// 2. Restores alpha on dimmed icons (inactive display / offscreen menu bar windows rendered at ~17%–45% opacity).
    /// 3. Inverts dark monochrome icons (light-mode menu bars) and lifts dull gray monochrome icons while preserving colored badges.
    static func adaptForDarkSurface(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= 2_048, height <= 256 else { return image }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drew = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return image }

        // Pass 1: detect peak alpha and any uniform faint backdrop floor across the window.
        var fullHistogram = [Int](repeating: 0, count: 256)
        var maxAlphaByte = 0
        let totalPixels = width * height
        for index in stride(from: 3, to: pixels.count, by: 4) {
            let a = Int(pixels[index])
            fullHistogram[a] += 1
            if a > maxAlphaByte { maxAlphaByte = a }
        }
        guard maxAlphaByte >= 12 else { return image }

        // If >= 50% of the entire window carries a faint uniform non-zero alpha (1...20),
        // treat it as a menu bar backdrop floor so thin-stroke foreground analysis isn't diluted.
        var faintCount = 0
        var dominantFaintAlpha = 0
        var dominantFaintCount = 0
        for a in 1...20 {
            let count = fullHistogram[a]
            faintCount += count
            if count > dominantFaintCount {
                dominantFaintCount = count
                dominantFaintAlpha = a
            }
        }
        let bgFloor = (faintCount * 2 >= totalPixels && maxAlphaByte > dominantFaintAlpha + 8) ? dominantFaintAlpha : 0
        let fgThreshold = max(bgFloor + 6, max(12, Int((Float(maxAlphaByte) * 0.35).rounded(.down))))

        // Pass 2: analyze foreground strokes only.
        var fgHistogram = [Int](repeating: 0, count: 256)
        var fgPixels = 0
        var opaqueWeight: Float = 0
        var monoWeight: Float = 0
        var monoLumaSum: Float = 0
        let chromaThreshold: Float = 0.15

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha >= fgThreshold else { continue }
            fgHistogram[alpha] += 1
            fgPixels += 1
            let af = Float(alpha) / 255
            let r = min(1, Float(pixels[index]) / 255 / af)
            let g = min(1, Float(pixels[index + 1]) / 255 / af)
            let b = min(1, Float(pixels[index + 2]) / 255 / af)
            let chroma = max(r, max(g, b)) - min(r, min(g, b))
            opaqueWeight += af
            if chroma < chromaThreshold {
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                monoWeight += af
                monoLumaSum += luma * af
            }
        }

        guard fgPixels > 0, opaqueWeight > 0 else { return image }

        // 85th-percentile alpha of foreground strokes detects dimmed inactive/offscreen icons robustly.
        let targetRank = max(1, Int((Float(fgPixels) * 0.85).rounded(.up)))
        var cumulative = 0
        var peakAlphaByte = maxAlphaByte
        for value in 0..<256 {
            cumulative += fgHistogram[value]
            if cumulative >= targetRank {
                peakAlphaByte = value
                break
            }
        }
        let effectivePeakAlpha = Float(max(1, peakAlphaByte - bgFloor)) / 255
        let needsAlphaBoost = effectivePeakAlpha > 0.04 && effectivePeakAlpha < 0.85
        let alphaGain: Float = needsAlphaBoost ? min(8.0, 0.95 / effectivePeakAlpha) : 1.0

        let isMostlyMonochrome = (monoWeight / opaqueWeight) >= 0.50
        let avgMonoLuma = monoWeight > 0 ? monoLumaSum / monoWeight : 1.0
        let shouldInvertMono = isMostlyMonochrome && avgMonoLuma < 0.45
        let shouldBrightenMono = isMostlyMonochrome && !shouldInvertMono && avgMonoLuma < 0.82

        guard needsAlphaBoost || shouldInvertMono || shouldBrightenMono else {
            return image
        }

        let invertedLift: Float = shouldInvertMono ? max(1.0, min(1.8, 0.95 / max(0.4, 1 - avgMonoLuma))) : 1.0
        let brightenLift: Float = shouldBrightenMono ? max(1.0, min(2.5, 0.92 / max(0.2, avgMonoLuma))) : 1.0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let rawAlpha = Int(pixels[index + 3])
            guard rawAlpha > 0 else { continue }
            if bgFloor > 0 && rawAlpha <= bgFloor + 2 {
                pixels[index] = 0
                pixels[index + 1] = 0
                pixels[index + 2] = 0
                pixels[index + 3] = 0
                continue
            }
            let af = Float(rawAlpha) / 255
            var r = min(1, Float(pixels[index]) / 255 / af)
            var g = min(1, Float(pixels[index + 1]) / 255 / af)
            var b = min(1, Float(pixels[index + 2]) / 255 / af)
            let chroma = max(r, max(g, b)) - min(r, min(g, b))

            if chroma < chromaThreshold {
                if shouldInvertMono {
                    r = min(1, (1 - r) * invertedLift)
                    g = min(1, (1 - g) * invertedLift)
                    b = min(1, (1 - b) * invertedLift)
                } else if shouldBrightenMono {
                    r = min(1, r * brightenLift)
                    g = min(1, g * brightenLift)
                    b = min(1, b * brightenLift)
                }
            }

            let effectiveAlpha = Float(max(0, rawAlpha - bgFloor)) / 255
            let newAlpha = min(1, effectiveAlpha * alphaGain)
            pixels[index] = UInt8(max(0, min(255, (r * newAlpha * 255).rounded())))
            pixels[index + 1] = UInt8(max(0, min(255, (g * newAlpha * 255).rounded())))
            pixels[index + 2] = UInt8(max(0, min(255, (b * newAlpha * 255).rounded())))
            pixels[index + 3] = UInt8(max(0, min(255, (newAlpha * 255).rounded())))
        }

        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: colorSpace, bitmapInfo: bitmapInfo),
                  let adapted = context.makeImage() else { return image }
            return adapted
        }
    }
}

struct StatusImage: Sendable {
    let image: CGImage
    let frame: CGRect

    func computeSignature() -> [Float] {
        guard frame.height > 0, image.height > 0, image.width > 0 else { return [] }
        let sampleHeight = max(1, min(image.height, Int(24 * CGFloat(image.height) / frame.height)))
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
        guard rendered else { return [] }
        return Self.normalized(stride(from: 0, to: pixels.count, by: 4).map { index in
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

    static func similarity(between lhs: [Float], and rhs: [Float]) -> Float {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        return abs(zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 })
    }
}

final class StatusImageReader: @unchecked Sendable {
    private typealias Capture = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    // ScreenCaptureKit omits some hidden menu bar windows on macOS 26.
    // Resolve the private SkyLight single-window capture once at startup and keep it optional.
    private let framework: UnsafeMutableRawPointer?
    private let capture: Capture?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
        framework = handle
        if let handle, let symbol = dlsym(handle, "SLWindowListCreateImageFromArray") {
            capture = unsafeBitCast(symbol, to: Capture.self)
        } else {
            capture = nil
        }
    }

    deinit {
        if let framework { dlclose(framework) }
    }

    func read(_ window: StatusWindow) -> StatusImage? {
        guard let capture,
              let windowPointer = UnsafeRawPointer(bitPattern: UInt(window.id)) else { return nil }
        var pointer: UnsafeRawPointer? = windowPointer
        var callbacks = CFArrayCallBacks(version: 0, retain: nil, release: nil, copyDescription: nil, equal: nil)
        guard let windowIDs = CFArrayCreate(nil, &pointer, 1, &callbacks) else { return nil }
        let options = CGWindowImageOption.boundsIgnoreFraming.union(.bestResolution)
        guard let rawImage = capture(.null, windowIDs, options.rawValue)?.takeRetainedValue(),
              rawImage.width <= 2_048, rawImage.height <= 256 else { return nil }
        let adapted = StatusImageAdapter.adaptForDarkSurface(rawImage)
        return StatusImage(image: adapted, frame: window.frame)
    }
}

struct CapturedItem: Sendable {
    let window: StatusWindow
    let cgImage: CGImage?
    let mirror: StatusWindow?
    let axEntry: AXMenuBarEntry?
}

struct IslandItem: Identifiable {
    let window: StatusWindow
    let name: String
    let image: NSImage?
    let isAppIconFallback: Bool
    let mirror: StatusWindow?
    let bundleIdentifier: String?
    let axOwnerPID: pid_t?
    var id: CGWindowID { window.id }

    var estimatedTileWidth: CGFloat {
        let contentWidth: CGFloat
        if let image, !isAppIconFallback {
            contentWidth = min(88, max(28, image.size.width))
        } else {
            contentWidth = 28
        }
        return max(44, contentWidth) + 6
    }
}

final class ItemCatalog: @unchecked Sendable {
    private let capture = StatusImageReader()

    private static let genericSystemHosts = AXExtrasCatalog.systemHostBundleIDs

    private static let knownSystemTitles: [String: String] = [
        "WiFi": "无线局域网",
        "Bluetooth": "蓝牙",
        "Battery": "电池",
        "Sound": "声音",
        "Clock": "时钟",
        "FocusModes": "专注模式",
        "ScreenMirroring": "屏幕镜像",
        "NowPlaying": "正在播放",
        "BentoBox": "控制中心",
        "Display": "显示器",
        "AirDrop": "隔空投送",
        "KeyboardBrightness": "键盘亮度",
        "UserSwitcher": "快速切换用户",
        "AccessibilityShortcuts": "辅助功能快捷键",
        "Hearing": "听觉",
    ]

    /// Performs window image capture, cross-display matching, and parallel AXExtrasMenuBar lookup off the main thread.
    func captureItems(in snapshot: StatusSnapshot, display: DisplayGeometry,
                      canCapture: Bool, runningApps: [RunningAppSummary]) -> [CapturedItem] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let systemHostPIDs = Set(runningApps.filter {
            $0.bundleIdentifier.map(Self.genericSystemHosts.contains) ?? false
        }.map(\.pid))
        let axEntries = AXExtrasCatalog.snapshot(apps: runningApps, excluding: currentPID)
        let mirrors = snapshot.windows.filter { $0.visible && !StatusSnapshot.onMenuBar($0.frame, display.bounds) }
        var mirrorImages = [CGWindowID: StatusImage]()
        var mirrorSignatures = [CGWindowID: [Float]]()

        return snapshot.overflow.map { window in
            let icon = canCapture ? capture.read(window) : nil
            let mirror = match(window, icon: icon, mirrors: mirrors, canCapture: canCapture,
                               mirrorImages: &mirrorImages, mirrorSignatures: &mirrorSignatures)
            let axEntry = AXExtrasCatalog.match(window, mirror: mirror, in: axEntries, systemHostPIDs: systemHostPIDs)
            return CapturedItem(window: window, cgImage: icon?.image, mirror: mirror, axEntry: axEntry)
        }
    }

    @MainActor
    func resolveItems(from captured: [CapturedItem]) -> [IslandItem] {
        captured.enumerated().map { index, entry in
            let window = entry.window
            let mirror = entry.mirror
            let axEntry = entry.axEntry
            let nameHint = mirror?.hasIdentifyingTitle == true ? mirror?.title : window.hasIdentifyingTitle ? window.title : nil

            let axOwner = axEntry.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
            let axIsGenericHost = axEntry?.bundleIdentifier.map(Self.genericSystemHosts.contains) ?? false
            let specificAXOwner = axIsGenericHost ? nil : axOwner

            let windowOwner = NSRunningApplication(processIdentifier: window.owner)
            let windowIsGenericHost = windowOwner?.bundleIdentifier.map(Self.genericSystemHosts.contains) ?? false
            let specificWindowOwner = windowIsGenericHost ? nil : windowOwner

            let namedApp = nameHint.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            let axDescription: String? = {
                guard let axEntry else { return nil }
                if !axEntry.description.isEmpty { return axEntry.description }
                if !axEntry.title.isEmpty { return axEntry.title }
                return nil
            }()
            let friendlyHint = nameHint.map { Self.knownSystemTitles[$0] ?? $0 }

            let enclosingParentName: String? = {
                guard let url = specificAXOwner?.bundleURL ?? specificWindowOwner?.bundleURL else { return nil }
                let enclosing = AppBundleResolver.enclosingAppURL(for: url)
                guard enclosing != url else { return nil }
                return AppBundleResolver.displayName(for: enclosing)
            }()

            let name: String
            if let enclosingParentName {
                name = enclosingParentName
            } else if let specificAX = specificAXOwner?.localizedName, !specificAX.isEmpty {
                name = specificAX
            } else if let axName = axEntry?.appName, !axIsGenericHost, !axName.isEmpty {
                name = axName
            } else if axIsGenericHost, let axDescription {
                name = axDescription
            } else if let appName = namedApp?.localizedName {
                name = appName
            } else if let ownerName = specificWindowOwner?.localizedName {
                name = ownerName
            } else if let friendlyHint {
                name = friendlyHint
            } else if let axDescription {
                name = axDescription
            } else {
                name = "菜单栏图标 \(index + 1)"
            }

            let resolvedBundleID = (axIsGenericHost ? nil : axEntry?.bundleIdentifier)
                ?? namedApp?.bundleIdentifier
                ?? specificWindowOwner?.bundleIdentifier

            let image: NSImage?
            let isFallback: Bool
            if let cgImage = entry.cgImage {
                let scale = window.frame.width > 0 ? min(1, 88 / window.frame.width) : 1
                let size = NSSize(width: window.frame.width * scale, height: window.frame.height * scale)
                image = NSImage(cgImage: cgImage, size: size)
                isFallback = false
            } else {
                image = specificAXOwner?.icon ?? namedApp?.icon ?? specificWindowOwner?.icon
                isFallback = image != nil
            }
            return IslandItem(window: window, name: name, image: image, isAppIconFallback: isFallback,
                              mirror: mirror, bundleIdentifier: resolvedBundleID, axOwnerPID: axEntry?.pid)
        }
    }

    @MainActor
    func items(in snapshot: StatusSnapshot, display: NotchedDisplay) -> [IslandItem] {
        let apps = Self.currentRunningApps()
        let captured = captureItems(in: snapshot, display: display.geometry,
                                    canCapture: CGPreflightScreenCaptureAccess(),
                                    runningApps: apps)
        return resolveItems(from: captured)
    }

    @MainActor
    static func currentRunningApps() -> [RunningAppSummary] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy != .prohibited else { return nil }
            return RunningAppSummary(pid: app.processIdentifier,
                                     localizedName: app.localizedName,
                                     bundleIdentifier: app.bundleIdentifier)
        }
    }

    private func match(_ hidden: StatusWindow, icon: StatusImage?, mirrors: [StatusWindow], canCapture: Bool,
                       mirrorImages: inout [CGWindowID: StatusImage],
                       mirrorSignatures: inout [CGWindowID: [Float]]) -> StatusWindow? {
        let sameSize = mirrors.filter { $0.owner == hidden.owner && abs($0.frame.width - hidden.frame.width) <= 1 }
        guard !sameSize.isEmpty else { return nil }
        if hidden.hasIdentifyingTitle {
            let named = sameSize.filter { $0.title == hidden.title }
            if named.count == 1 { return named[0] }
        }
        guard canCapture, let icon else { return nil }
        let hiddenSignature = icon.computeSignature()
        guard !hiddenSignature.isEmpty else { return nil }

        let scores = sameSize.compactMap { candidate -> (window: StatusWindow, score: Float)? in
            let candidateImage: StatusImage
            if let cached = mirrorImages[candidate.id] {
                candidateImage = cached
            } else if let captured = capture.read(candidate) {
                mirrorImages[candidate.id] = captured
                candidateImage = captured
            } else {
                return nil
            }
            let candidateSignature: [Float]
            if let cachedSig = mirrorSignatures[candidate.id] {
                candidateSignature = cachedSig
            } else {
                let computed = candidateImage.computeSignature()
                mirrorSignatures[candidate.id] = computed
                candidateSignature = computed
            }
            return (candidate, StatusImage.similarity(between: hiddenSignature, and: candidateSignature))
        }.sorted { $0.score > $1.score }

        guard let best = scores.first, best.score >= 0.95,
              best.score - (scores.dropFirst().first?.score ?? 0) >= 0.09 else { return nil }
        return best.window
    }
}
