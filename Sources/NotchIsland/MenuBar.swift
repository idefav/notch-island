import AppKit
import CoreGraphics

struct NotchedDisplay {
    let screen: NSScreen
    let bounds: CGRect
    let notch: CGRect

    init?(screen: NSScreen) {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              screen.safeAreaInsets.top > 0, right.minX > left.maxX else { return nil }
        self.screen = screen
        bounds = CGDisplayBounds(number.uint32Value)
        notch = CGRect(x: bounds.minX + left.maxX - screen.frame.minX,
                       y: bounds.minY, width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    }
}

struct StatusWindow: Identifiable, Sendable, Equatable {
    let id: CGWindowID
    let owner: pid_t
    let title: String
    let frame: CGRect
    let visible: Bool

    var hasIdentifyingTitle: Bool {
        !title.isEmpty && !title.hasPrefix("Item-") && UUID(uuidString: title) == nil
    }
}

struct StatusSnapshot {
    let windows: [StatusWindow]
    let overflow: [StatusWindow]
    let menuBarVisible: Bool

    init(display: NotchedDisplay, otherDisplays: [CGRect]) {
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let entries = CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID) as? [[String: Any]] ?? []
        let displays = [display.bounds] + otherDisplays
        var localMenuBarVisible = false
        var statusWindows = [StatusWindow]()
        for entry in entries {
            guard let level = entry[kCGWindowLayer as String] as? Int,
                  level == menuLevel || level == statusLevel,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary),
                  (14...52).contains(frame.height) else { continue }
            let visible = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            if level == menuLevel {
                if visible, Self.onMenuBar(frame, display.bounds), frame.width >= display.bounds.width - 8 {
                    localMenuBarVisible = true
                }
                continue
            }
            guard (12...480).contains(frame.width),
                  displays.contains(where: { Self.onMenuBar(frame, $0) }),
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value != ProcessInfo.processInfo.processIdentifier else { continue }
            statusWindows.append(StatusWindow(id: number.uint32Value, owner: owner.int32Value,
                                               title: entry[kCGWindowName as String] as? String ?? "",
                                               frame: frame, visible: visible))
        }
        windows = statusWindows
        menuBarVisible = localMenuBarVisible
        let local = statusWindows.filter { Self.onMenuBar($0.frame, display.bounds) }
        overflow = localMenuBarVisible ? Self.overflow(in: local, notch: display.notch) : []
    }

    static func onMenuBar(_ item: CGRect, _ display: CGRect) -> Bool {
        abs(item.minY - display.minY) <= 2 &&
        item.minX >= display.minX - 2 && item.midX < display.maxX && item.maxX <= display.maxX + 4
    }

    static func overflow(in windows: [StatusWindow], notch: CGRect) -> [StatusWindow] {
        guard let firstVisible = windows.lazy.filter({ $0.visible && $0.frame.minX >= notch.maxX - 2 })
            .map(\.frame.minX).min() else { return [] }
        let candidates = windows.filter { !$0.visible && $0.frame.maxX <= firstVisible + 2 }
            .sorted { $0.frame.maxX > $1.frame.maxX }
        var boundary = firstVisible
        var hidden = [StatusWindow]()
        for window in candidates {
            // Other Spaces and parked items can leave windows behind. The
            // overflow chain should still touch the first visible status item.
            if window.frame.maxX < boundary - 12 { break }
            guard window.frame.minX < boundary - 2 else { continue }
            hidden.append(window)
            boundary = window.frame.minX
        }
        guard hidden.contains(where: { $0.frame.intersects(notch.insetBy(dx: -12, dy: 0)) }) else { return [] }
        return Array(hidden.reversed())
    }
}
