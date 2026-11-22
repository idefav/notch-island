import ApplicationServices
import CoreGraphics
import Foundation

enum NativeMenu {
    enum Result: Equatable {
        case requested
        case needsVisibleClick(CGPoint)
        case permissionRequired
        case unsupportedByApp
        case unavailable
    }

    private enum PressOutcome {
        case succeeded
        case actionUnsupported
        case failed
    }

    static func open(for window: StatusWindow, mirror: StatusWindow?,
                     notch: CGRect? = nil,
                     primaryPIDs: [pid_t], fallbackPIDs: [pid_t] = [],
                     systemHostPIDs: Set<pid_t> = [],
                     timeout: Duration = .milliseconds(1200)) -> Result {
        guard AXIsProcessTrusted() else { return .permissionRequired }
        var sawUnsupported = false

        if let element = hitTest(mirror) {
            switch sendPress(to: element) {
            case .succeeded: return .requested
            case .actionUnsupported: sawUnsupported = true
            case .failed: break
            }
        }
        let deadline = ContinuousClock.now + timeout

        // Phase 1: check prioritized PIDs (AX-matched owner, bundle-matched owners) directly — typically < 15ms.
        for pid in primaryPIDs {
            if ContinuousClock.now >= deadline { break }
            switch tryOpen(pid: pid, window: window, mirror: mirror,
                           allowSingleChildFallback: !systemHostPIDs.contains(pid),
                           deadline: deadline) {
            case .succeeded: return .requested
            case .actionUnsupported: sawUnsupported = true
            case .failed: break
            }
        }

        // Phase 2: parallel geometric scan of remaining running apps (needed on macOS 26 when
        // ControlCenter owns the CGWindow and the item moved slightly since last refresh).
        let remaining = fallbackPIDs.filter { !primaryPIDs.contains($0) }
        if !sawUnsupported, !remaining.isEmpty, ContinuousClock.now < deadline,
           let matched = findMatchingElementInParallel(pids: remaining, window: window, mirror: mirror,
                                                       systemHostPIDs: systemHostPIDs) {
            switch sendPress(to: matched) {
            case .succeeded: return .requested
            case .actionUnsupported: sawUnsupported = true
            case .failed: break
            }
        }

        // Phase 3: if the item has a visible mirror on another screen, or is itself visible / straddling
        // past the right edge of the notch, request a direct CGEvent click after NotchIsland collapses.
        if let point = visibleClickPoint(for: window, mirror: mirror, notch: notch) {
            return .needsVisibleClick(point)
        }

        return sawUnsupported ? .unsupportedByApp : .unavailable
    }

    static func visibleClickPoint(for window: StatusWindow, mirror: StatusWindow?, notch: CGRect?) -> CGPoint? {
        if let mirror, mirror.visible {
            return CGPoint(x: mirror.frame.midX, y: mirror.frame.midY)
        }
        if window.visible {
            if let notch, window.frame.minX < notch.maxX, window.frame.maxX > notch.maxX + 4 {
                let x = min(window.frame.maxX - 4, max(notch.maxX + 4, (notch.maxX + window.frame.maxX) / 2))
                return CGPoint(x: x, y: window.frame.midY)
            }
            return CGPoint(x: window.frame.midX, y: window.frame.midY)
        }
        return nil
    }

    static func clickVisibleTarget(at point: CGPoint) -> Bool {
        let savedLocation = CGEvent(source: nil)?.location
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return false }
        down.post(tap: .cghidEventTap)
        usleep(25_000)
        up.post(tap: .cghidEventTap)
        if let savedLocation,
           let restore = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: savedLocation, mouseButton: .left) {
            restore.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func tryOpen(pid: pid_t, window: StatusWindow, mirror: StatusWindow?,
                                allowSingleChildFallback: Bool, deadline: ContinuousClock.Instant) -> PressOutcome {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.12)
        guard let bar = element(attribute("AXExtrasMenuBar", of: application)) else { return .failed }
        AXUIElementSetMessagingTimeout(bar, 0.12)
        let children = attribute("AXChildren", of: bar) as? [AXUIElement] ?? []
        guard !children.isEmpty else { return .failed }

        var sawUnsupported = false

        // Pass 1: exact geometric match against the hidden window or its visible mirror.
        for child in children {
            if ContinuousClock.now >= deadline { return sawUnsupported ? .actionUnsupported : .failed }
            AXUIElementSetMessagingTimeout(child, 0.12)
            guard let bounds = frame(of: child),
                  matches(bounds, window.frame) || mirror.map({ matches(bounds, $0.frame) }) == true else { continue }
            switch sendPress(to: child) {
            case .succeeded: return .succeeded
            case .actionUnsupported: sawUnsupported = true
            case .failed: break
            }
        }

        // Pass 2: for a specific (non-ControlCenter) app that we already know owns this item,
        // fall back to its sole AXMenuBarItem or title/description match if its frame shifted slightly.
        guard allowSingleChildFallback, !sawUnsupported else {
            return sawUnsupported ? .actionUnsupported : .failed
        }
        if children.count == 1 {
            let sole = children[0]
            AXUIElementSetMessagingTimeout(sole, 0.12)
            return sendPress(to: sole)
        } else if window.hasIdentifyingTitle {
            for child in children {
                if ContinuousClock.now >= deadline { break }
                AXUIElementSetMessagingTimeout(child, 0.12)
                let title = attribute("AXTitle", of: child) as? String ?? ""
                let desc = attribute("AXDescription", of: child) as? String ?? ""
                guard title == window.title || desc == window.title || desc.contains(window.title) else { continue }
                switch sendPress(to: child) {
                case .succeeded: return .succeeded
                case .actionUnsupported: sawUnsupported = true
                case .failed: break
                }
            }
        }
        return sawUnsupported ? .actionUnsupported : .failed
    }

    private static func findMatchingElementInParallel(pids: [pid_t], window: StatusWindow,
                                                      mirror: StatusWindow?,
                                                      systemHostPIDs: Set<pid_t>) -> AXUIElement? {
        final class MatchBox: @unchecked Sendable {
            private let lock = NSLock()
            var specific: (element: AXUIElement, distance: CGFloat)?
            var system: (element: AXUIElement, distance: CGFloat)?

            func record(_ el: AXUIElement, distance: CGFloat, isSystem: Bool) {
                lock.lock()
                if isSystem {
                    if system == nil || distance < system!.distance { system = (el, distance) }
                } else {
                    if specific == nil || distance < specific!.distance { specific = (el, distance) }
                }
                lock.unlock()
            }
        }

        let box = MatchBox()
        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            let pid = pids[index]
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.12)
            guard let bar = element(attribute("AXExtrasMenuBar", of: application)) else { return }
            AXUIElementSetMessagingTimeout(bar, 0.12)
            let children = attribute("AXChildren", of: bar) as? [AXUIElement] ?? []
            let isSystem = systemHostPIDs.contains(pid)
            for child in children {
                AXUIElementSetMessagingTimeout(child, 0.12)
                guard let bounds = frame(of: child) else { continue }
                if matches(bounds, window.frame) {
                    box.record(child, distance: abs(bounds.midX - window.frame.midX), isSystem: isSystem)
                } else if let mirror, matches(bounds, mirror.frame) {
                    box.record(child, distance: abs(bounds.midX - mirror.frame.midX), isSystem: isSystem)
                }
            }
        }
        return box.specific?.element ?? box.system?.element
    }

    private static func hitTest(_ window: StatusWindow?) -> AXUIElement? {
        guard let window else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.12)
        var target: AXUIElement?
        let point = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &target) == .success,
              let target else { return nil }
        AXUIElementSetMessagingTimeout(target, 0.12)
        let role = attribute("AXRole", of: target) as? String
        guard role == "AXMenuBarItem" || role == "AXMenuExtra",
              let bounds = frame(of: target), matches(bounds, window.frame) else { return nil }
        return target
    }

    private static func sendPress(to target: AXUIElement, allowSubChildren: Bool = true) -> PressOutcome {
        AXUIElementSetMessagingTimeout(target, 0.15)
        let direct = performPrimaryAction(on: target)
        if direct == .succeeded { return .succeeded }
        guard allowSubChildren,
              let subChildren = attribute("AXChildren", of: target) as? [AXUIElement],
              !subChildren.isEmpty else { return direct }
        var sawUnsupported = direct == .actionUnsupported
        for sub in subChildren {
            AXUIElementSetMessagingTimeout(sub, 0.15)
            switch performPrimaryAction(on: sub) {
            case .succeeded: return .succeeded
            case .actionUnsupported: sawUnsupported = true
            case .failed: break
            }
        }
        return sawUnsupported ? .actionUnsupported : .failed
    }

    private static func performPrimaryAction(on target: AXUIElement) -> PressOutcome {
        var values: CFArray?
        guard AXUIElementCopyActionNames(target, &values) == .success,
              let actions = values as? [String] else { return .failed }
        let candidates = ["AXPress", "AXShowMenu"].filter(actions.contains)
        guard !candidates.isEmpty else { return .actionUnsupported }
        var sawUnsupported = false
        for action in candidates {
            // Some native menus keep the request open until the menu closes, hitting the messaging timeout.
            // An immediate .cannotComplete indicates rejection rather than an open menu.
            let start = ContinuousClock.now
            let result = AXUIElementPerformAction(target, action as CFString)
            let elapsed = start.duration(to: .now)
            if result == .success || (result == .cannotComplete && elapsed >= .milliseconds(80)) {
                return .succeeded
            }
            if result == .actionUnsupported {
                sawUnsupported = true
            }
        }
        return sawUnsupported ? .actionUnsupported : .failed
    }

    private static func attribute(_ name: String, of source: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(source, name as CFString, &value) == .success ? value : nil
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute("AXPosition", of: element), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = axSizeAttribute(of: element) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func axSizeAttribute(of element: AXUIElement) -> CGSize? {
        guard let size = attribute("AXSize", of: element), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var dimensions = CGSize.zero
        return AXValueGetValue(size as! AXValue, .cgSize, &dimensions) ? dimensions : nil
    }

    static func matches(_ accessibility: CGRect, _ window: CGRect) -> Bool {
        let horizontalMatch = abs(accessibility.midX - window.midX) <= 7 &&
            accessibility.intersection(window).width >= min(accessibility.width, window.width) * 0.8
        guard horizontalMatch else { return false }
        if abs(accessibility.midY - window.midY) <= 7 { return true }
        let minHeight = min(accessibility.height, window.height)
        return minHeight > 0 &&
            accessibility.intersection(window).height >= minHeight * 0.5 &&
            abs(accessibility.minY - window.minY) <= 16
    }
}
