import AppKit
import CoreGraphics

struct DisplayGeometry: Sendable, Equatable {
    let displayID: CGDirectDisplayID
    let bounds: CGRect
    let notch: CGRect
}

struct NotchedDisplay {
    let screen: NSScreen
    let geometry: DisplayGeometry

    var displayID: CGDirectDisplayID { geometry.displayID }
    var bounds: CGRect { geometry.bounds }
    var notch: CGRect { geometry.notch }

    init?(screen: NSScreen) {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              screen.safeAreaInsets.top > 0, right.minX > left.maxX else { return nil }
        self.screen = screen
        let displayID = number.uint32Value
        let bounds = CGDisplayBounds(displayID)
        let notch = CGRect(x: bounds.minX + left.maxX - screen.frame.minX,
                           y: bounds.minY, width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        geometry = DisplayGeometry(displayID: displayID, bounds: bounds, notch: notch)
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

struct StatusSnapshot: Sendable {
    let windows: [StatusWindow]
    let overflow: [StatusWindow]
    let menuBarVisible: Bool

    init(display: NotchedDisplay, otherDisplays: [CGRect]) {
        self.init(display: display.geometry, otherDisplays: otherDisplays)
    }

    init(display: DisplayGeometry, otherDisplays: [CGRect]) {
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let entries = CGWindowListCopyWindowInfo(.excludeDesktopElements, kCGNullWindowID) as? [[String: Any]] ?? []
        let displays = [display.bounds] + otherDisplays
        let currentPID = ProcessInfo.processInfo.processIdentifier
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
                  owner.int32Value != currentPID else { continue }
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
            .sorted { lhs, rhs in
                if abs(lhs.frame.maxX - rhs.frame.maxX) > 1 {
                    return lhs.frame.maxX > rhs.frame.maxX
                }
                if abs(lhs.frame.width - rhs.frame.width) > 1 {
                    return lhs.frame.width < rhs.frame.width
                }
                return lhs.id < rhs.id
            }
        var boundary = firstVisible
        var hidden = [StatusWindow]()
        let maxGap: CGFloat = 18
        for window in candidates {
            // Other Spaces and parked items can leave windows behind. The
            // overflow chain should stay contiguous with the first visible status item,
            // while tolerating narrow spacers/dividers and skipping overlapping stale windows.
            if window.frame.maxX < boundary - maxGap { break }
            guard window.frame.maxX <= boundary + 4 else { continue }
            guard window.frame.minX < boundary - 2 else { continue }
            hidden.append(window)
            boundary = window.frame.minX
        }
        guard hidden.contains(where: { $0.frame.intersects(notch.insetBy(dx: -12, dy: 0)) }) else { return [] }
        return Array(hidden.reversed())
    }
}
