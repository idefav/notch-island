import ApplicationServices
import Foundation

enum NativeMenu {
    enum Result {
        case requested
        case permissionRequired
        case unavailable
    }

    static func open(for window: StatusWindow, mirror: StatusWindow?, preferredPIDs: [pid_t]) -> Result {
        guard AXIsProcessTrusted() else { return .permissionRequired }
        if let element = hitTest(mirror), sendPress(to: element) {
            return .requested
        }
        for pid in preferredPIDs {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.12)
            guard let bar = element(attribute("AXExtrasMenuBar", of: application)) else { continue }
            AXUIElementSetMessagingTimeout(bar, 0.12)
            let children = attribute("AXChildren", of: bar) as? [AXUIElement] ?? []
            for child in children {
                AXUIElementSetMessagingTimeout(child, 0.12)
                guard let bounds = frame(of: child),
                      matches(bounds, window.frame) || mirror.map({ matches(bounds, $0.frame) }) == true else { continue }
                return sendPress(to: child) ? .requested : .unavailable
            }
        }
        return .unavailable
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

    private static func sendPress(to target: AXUIElement) -> Bool {
        var values: CFArray?
        guard AXUIElementCopyActionNames(target, &values) == .success,
              let actions = values as? [String] else { return false }
        guard let action = ["AXPress", "AXShowMenu"].first(where: actions.contains) else { return false }
        // Some native menus keep the request open until the menu closes.
        // A timeout is ambiguous, so never send a second press on timeout.
        let result = AXUIElementPerformAction(target, action as CFString)
        return result == .success || result == .cannotComplete
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
              let size = attribute("AXSize", of: element), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions), dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func matches(_ accessibility: CGRect, _ window: CGRect) -> Bool {
        abs(accessibility.midX - window.midX) <= 7 &&
        abs(accessibility.midY - window.midY) <= 7 &&
        accessibility.intersection(window).width >= min(accessibility.width, window.width) * 0.8
    }
}
