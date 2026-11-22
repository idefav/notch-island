import CoreGraphics
import Foundation

struct FullScreenDetector {
    struct WindowInfo: Sendable {
        let layer: Int
        let frame: CGRect
        let ownerName: String
        let alpha: Double
    }

    static func isFullScreen(on display: DisplayGeometry) -> Bool {
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var menuBarVisible = false
        var normalWindows = [WindowInfo]()
        for entry in entries {
            guard let layer = entry[kCGWindowLayer as String] as? Int,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary) else { continue }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0 else { continue }
            if layer == menuLevel {
                if StatusSnapshot.onMenuBar(frame, display.bounds), frame.width >= display.bounds.width - 8 {
                    menuBarVisible = true
                }
                continue
            }
            if layer == 0 {
                let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
                normalWindows.append(WindowInfo(layer: layer, frame: frame, ownerName: ownerName, alpha: alpha))
            }
        }
        return isFullScreen(displayBounds: display.bounds, notchHeight: display.notch.height,
                            menuBarVisible: menuBarVisible, normalWindows: normalWindows)
    }

    static func isFullScreen(displayBounds: CGRect, notchHeight: CGFloat,
                             menuBarVisible: Bool, normalWindows: [WindowInfo]) -> Bool {
        guard !menuBarVisible else { return false }
        let ignoredOwners: Set<String> = [
            "Window Server", "Dock", "Wallpaper", "Control Center", "SystemUIServer",
        ]
        return normalWindows.contains { window in
            guard window.layer == 0, window.alpha > 0, !ignoredOwners.contains(window.ownerName) else { return false }
            let coversWidth = abs(window.frame.minX - displayBounds.minX) <= 2 &&
                              abs(window.frame.width - displayBounds.width) <= 4
            guard coversWidth else { return false }
            let coversFullHeight = abs(window.frame.minY - displayBounds.minY) <= 2 &&
                                   abs(window.frame.height - displayBounds.height) <= 4
            let coversBelowNotch = abs(window.frame.minY - (displayBounds.minY + notchHeight)) <= 4 &&
                                   abs(window.frame.height - (displayBounds.height - notchHeight)) <= 6
            return coversFullHeight || coversBelowNotch
        }
    }
}
