import CoreGraphics
import Foundation
import Testing
@testable import NotchIsland

struct StatusAndMenuTests {
    private func makeImage(width: Int = 32, height: Int = 32, draw: (CGContext) -> Void) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        draw(context)
        return try #require(context.makeImage())
    }

    private func pixel(at x: Int, y: Int, in image: CGImage) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ok = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(ok)
        let offset = (y * image.width + x) * 4
        return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
    }

    @Test func darkMonochromeIconIsInvertedForDarkSurface() throws {
        let darkIcon = try makeImage { context in
            context.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1))
            context.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
        }
        let adapted = StatusImageAdapter.adaptForDarkSurface(darkIcon)
        let center = try pixel(at: 16, y: 16, in: adapted)
        let corner = try pixel(at: 2, y: 2, in: adapted)
        #expect(center.r >= 230 && center.g >= 230 && center.b >= 230 && center.a == 255)
        #expect(corner.a == 0)
    }

    @Test func darkMonochromeIconPreservesColoredNotificationBadge() throws {
        let iconWithBadge = try makeImage { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 6, y: 6, width: 20, height: 20))
            context.setFillColor(CGColor(srgbRed: 0.95, green: 0.1, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 22, y: 22, width: 6, height: 6))
        }
        let adapted = StatusImageAdapter.adaptForDarkSurface(iconWithBadge)
        let body = try pixel(at: 12, y: 16, in: adapted)
        // Note: CGContext coordinates are bottom-left; pixel row 0 in memory is top-left (y=31 in CGContext).
        let badge = try pixel(at: 25, y: 6, in: adapted)
        #expect(body.r >= 240 && body.g >= 240 && body.b >= 240)
        #expect(badge.r >= 220 && badge.g <= 40 && badge.b <= 40)
    }

    @Test func whiteAndColorfulIconsRemainUnchanged() throws {
        let whiteIcon = try makeImage { context in
            context.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1))
            context.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
        }
        let adaptedWhite = StatusImageAdapter.adaptForDarkSurface(whiteIcon)
        let whitePixel = try pixel(at: 16, y: 16, in: adaptedWhite)
        #expect(whitePixel.r >= 235 && whitePixel.g >= 235 && whitePixel.b >= 235)

        let colorfulIcon = try makeImage { context in
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.25, blue: 0.65, alpha: 1))
            context.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
        }
        let adaptedColorful = StatusImageAdapter.adaptForDarkSurface(colorfulIcon)
        let colorPixel = try pixel(at: 16, y: 16, in: adaptedColorful)
        #expect(colorPixel.b >= 150 && colorPixel.r <= 40)
    }

    @Test func dimmedInactiveDisplayWhiteAndBlackIconsAreRestoredToCrispBrightness() throws {
        let dimmedWhite = try makeImage { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
            context.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
        }
        let restoredWhite = StatusImageAdapter.adaptForDarkSurface(dimmedWhite)
        let wp = try pixel(at: 16, y: 16, in: restoredWhite)
        #expect(wp.a >= 220 && wp.r >= 220 && wp.g >= 220 && wp.b >= 220)

        let dimmedBlackWithRedBadge = try makeImage { context in
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22))
            context.fill(CGRect(x: 4, y: 4, width: 18, height: 18))
            context.setFillColor(CGColor(srgbRed: 0.95, green: 0.1, blue: 0.1, alpha: 0.22))
            context.fill(CGRect(x: 23, y: 23, width: 6, height: 6))
        }
        let restoredBadge = StatusImageAdapter.adaptForDarkSurface(dimmedBlackWithRedBadge)
        let body = try pixel(at: 12, y: 18, in: restoredBadge)
        let badge = try pixel(at: 26, y: 5, in: restoredBadge)
        #expect(body.a >= 220 && body.r >= 220 && body.g >= 220 && body.b >= 220)
        #expect(badge.a >= 220 && badge.r >= 200 && badge.g <= 40 && badge.b <= 40)

        let dimmedColorful = try makeImage { context in
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.7, blue: 0.3, alpha: 0.3))
            context.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
        }
        let restoredColor = StatusImageAdapter.adaptForDarkSurface(dimmedColorful)
        let cp = try pixel(at: 16, y: 16, in: restoredColor)
        #expect(cp.a >= 220 && cp.g >= 150 && cp.r <= 40)
    }

    @Test func dimmedThinStrokeOnFaintBackdropIsStillBoostedWithoutBrighteningBackdrop() throws {
        // Simulates a 64x64 menu bar window where 90% has faint backdrop alpha (~9/255)
        // and only ~8% is a thin dimmed icon stroke (alpha ~45/255).
        let image = try makeImage(width: 64, height: 64) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 9.0 / 255.0))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 45.0 / 255.0))
            context.fill(CGRect(x: 28, y: 16, width: 8, height: 32))
        }
        let adapted = StatusImageAdapter.adaptForDarkSurface(image)
        let stroke = try pixel(at: 32, y: 32, in: adapted)
        let backdrop = try pixel(at: 4, y: 4, in: adapted)
        #expect(stroke.a >= 220 && stroke.r >= 220 && stroke.g >= 220 && stroke.b >= 220)
        #expect(backdrop.a == 0)
    }

    @Test func axExtrasCatalogPrefersThirdPartyAppOverControlCenterHost() {
        let hiddenWindow = StatusWindow(id: 88, owner: 469, title: "Item-0",
                                        frame: CGRect(x: 903, y: 0, width: 44, height: 33), visible: false)
        let controlCenterEntry = AXMenuBarEntry(pid: 469, frame: CGRect(x: 903, y: 0, width: 44, height: 33),
                                                title: "", description: "", identifier: "",
                                                appName: "控制中心", bundleIdentifier: "com.apple.controlcenter")
        let iShotEntry = AXMenuBarEntry(pid: 690, frame: CGRect(x: 913, y: 5.5, width: 22, height: 22),
                                        title: "", description: "ishotmenulogo", identifier: "",
                                        appName: "iShotProHelper", bundleIdentifier: "cn.better365.iShotProHelper")
        let matched = AXExtrasCatalog.match(hiddenWindow, mirror: nil,
                                            in: [controlCenterEntry, iShotEntry],
                                            systemHostPIDs: [469])
        #expect(matched?.pid == 690)
        #expect(matched?.appName == "iShotProHelper")
    }

    @Test func appBundleResolverFindsOutermostEnclosingAppForLoginItemHelpers() {
        let helper = URL(fileURLWithPath: "/Applications/iShot Pro.app/Contents/Library/LoginItems/iShotProHelper.app")
        let nested = URL(fileURLWithPath: "/Applications/Outer.app/Contents/Helpers/Inner.app/Contents/Helpers/Leaf.app")
        let standalone = URL(fileURLWithPath: "/Applications/WeChat.app")
        #expect(AppBundleResolver.enclosingAppURL(for: helper).path == "/Applications/iShot Pro.app")
        #expect(AppBundleResolver.enclosingAppURL(for: nested).path == "/Applications/Outer.app")
        #expect(AppBundleResolver.enclosingAppURL(for: standalone).path == "/Applications/WeChat.app")
    }

    @Test func visibleClickPointTargetsMirrorOrVisibleNotchEdge() {
        let notch = CGRect(x: 771, y: 0, width: 185, height: 32)
        let hidden = StatusWindow(id: 88, owner: 469, title: "", frame: CGRect(x: 903, y: 0, width: 44, height: 33), visible: false)
        let mirror = StatusWindow(id: 188, owner: 469, title: "", frame: CGRect(x: -500, y: 0, width: 44, height: 30), visible: true)
        let straddling = StatusWindow(id: 577, owner: 469, title: "", frame: CGRect(x: 946, y: 0, width: 34, height: 33), visible: true)

        #expect(NativeMenu.visibleClickPoint(for: hidden, mirror: nil, notch: notch) == nil)
        #expect(NativeMenu.visibleClickPoint(for: hidden, mirror: mirror, notch: notch) == CGPoint(x: -478, y: 15))
        let edgePoint = NativeMenu.visibleClickPoint(for: straddling, mirror: nil, notch: notch)
        #expect(edgePoint != nil && edgePoint!.x > notch.maxX)
    }

    @Test func nativeMenuMatchesTallNotchedMenuBar() {
        let tallStatusWindow = CGRect(x: 820, y: 0, width: 34, height: 44)
        let axTopAligned = CGRect(x: 820, y: 0, width: 34, height: 24)
        let axCentered = CGRect(x: 821, y: 10, width: 32, height: 24)
        let unrelatedWindow = CGRect(x: 820, y: 120, width: 34, height: 24)
        #expect(NativeMenu.matches(axTopAligned, tallStatusWindow))
        #expect(NativeMenu.matches(axCentered, tallStatusWindow))
        #expect(!NativeMenu.matches(unrelatedWindow, tallStatusWindow))
    }

    @Test func fullScreenDetectorHandlesFullAndBelowNotchWindows() {
        let display = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let fullWindow = FullScreenDetector.WindowInfo(layer: 0, frame: display, ownerName: "Safari", alpha: 1)
        let belowNotchWindow = FullScreenDetector.WindowInfo(
            layer: 0, frame: CGRect(x: 0, y: 38, width: 1728, height: 1079), ownerName: "IINA", alpha: 1
        )
        let regularWindow = FullScreenDetector.WindowInfo(
            layer: 0, frame: CGRect(x: 100, y: 100, width: 1200, height: 800), ownerName: "Xcode", alpha: 1
        )
        let dockBackdrop = FullScreenDetector.WindowInfo(layer: 0, frame: display, ownerName: "Dock", alpha: 1)

        #expect(FullScreenDetector.isFullScreen(displayBounds: display, notchHeight: 38, menuBarVisible: false, normalWindows: [fullWindow]))
        #expect(FullScreenDetector.isFullScreen(displayBounds: display, notchHeight: 38, menuBarVisible: false, normalWindows: [belowNotchWindow]))
        #expect(!FullScreenDetector.isFullScreen(displayBounds: display, notchHeight: 38, menuBarVisible: true, normalWindows: [fullWindow]))
        #expect(!FullScreenDetector.isFullScreen(displayBounds: display, notchHeight: 38, menuBarVisible: false, normalWindows: [regularWindow]))
        #expect(!FullScreenDetector.isFullScreen(displayBounds: display, notchHeight: 38, menuBarVisible: false, normalWindows: [dockBackdrop]))
    }
}
