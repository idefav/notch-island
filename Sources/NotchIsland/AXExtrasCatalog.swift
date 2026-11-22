import AppKit
import ApplicationServices
import Foundation

enum AppBundleResolver {
    /// If `bundleURL` is an embedded LoginItem/Helper inside an enclosing `.app` bundle
    /// (e.g. `/Applications/iShot Pro.app/Contents/Library/LoginItems/iShotProHelper.app`),
    /// returns the outermost enclosing `.app` URL (`/Applications/iShot Pro.app`).
    /// Otherwise returns `bundleURL` itself.
    static func enclosingAppURL(for bundleURL: URL) -> URL {
        var outermostApp = bundleURL
        var current = bundleURL.deletingLastPathComponent()
        while current.path != "/" && !current.path.isEmpty {
            if current.pathExtension.lowercased() == "app" {
                outermostApp = current
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return outermostApp
    }

    static func displayName(for appURL: URL) -> String? {
        guard let bundle = Bundle(url: appURL) else { return nil }
        if let display = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !display.isEmpty {
            return display
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
            return name
        }
        let stem = appURL.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? nil : stem
    }
}

struct RunningAppSummary: Sendable {
    let pid: pid_t
    let localizedName: String?
    let bundleIdentifier: String?
}

struct AXMenuBarEntry: Sendable, Equatable {
    let pid: pid_t
    let frame: CGRect
    let title: String
    let description: String
    let identifier: String
    let appName: String?
    let bundleIdentifier: String?
}

enum AXExtrasCatalog {
    static let systemHostBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.systemuiserver",
    ]

    /// Queries all running applications' `AXExtrasMenuBar` in parallel.
    /// On macOS 26, ControlCenter owns third-party menu bar CGWindows, while each app
    /// still exposes its real `AXMenuBarItem` (with matching geometry) on its own PID.
    static func snapshot(apps: [RunningAppSummary], excluding currentPID: pid_t) -> [AXMenuBarEntry] {
        guard AXIsProcessTrusted() else { return [] }
        let candidates = apps.filter { $0.pid != currentPID }
        guard !candidates.isEmpty else { return [] }

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            var entries = [AXMenuBarEntry]()
            func append(_ items: [AXMenuBarEntry]) {
                guard !items.isEmpty else { return }
                lock.lock()
                entries.append(contentsOf: items)
                lock.unlock()
            }
        }

        let collector = Collector()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let app = candidates[index]
            let found = entries(for: app)
            collector.append(found)
        }
        return collector.entries
    }

    static func match(_ window: StatusWindow, mirror: StatusWindow?,
                      in entries: [AXMenuBarEntry],
                      systemHostPIDs: Set<pid_t>) -> AXMenuBarEntry? {
        func bestMatch(from pool: [AXMenuBarEntry]) -> AXMenuBarEntry? {
            let matched = pool.compactMap { entry -> (entry: AXMenuBarEntry, distance: CGFloat)? in
                if NativeMenu.matches(entry.frame, window.frame) {
                    return (entry, abs(entry.frame.midX - window.frame.midX))
                }
                if let mirror, NativeMenu.matches(entry.frame, mirror.frame) {
                    return (entry, abs(entry.frame.midX - mirror.frame.midX))
                }
                return nil
            }
            return matched.min { $0.distance < $1.distance }?.entry
        }

        // Prefer specific third-party/helper apps over generic ControlCenter/SystemUIServer hosts.
        let specific = entries.filter { !systemHostPIDs.contains($0.pid) }
        if let hit = bestMatch(from: specific) { return hit }
        let system = entries.filter { systemHostPIDs.contains($0.pid) }
        return bestMatch(from: system)
    }

    private static func entries(for app: RunningAppSummary) -> [AXMenuBarEntry] {
        let axApp = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(axApp, 0.12)
        guard let bar = axElement(axAttribute("AXExtrasMenuBar", of: axApp)) else { return [] }
        AXUIElementSetMessagingTimeout(bar, 0.12)
        let children = axAttribute("AXChildren", of: bar) as? [AXUIElement] ?? []
        guard !children.isEmpty else { return [] }
        var result = [AXMenuBarEntry]()
        result.reserveCapacity(children.count)
        for child in children {
            AXUIElementSetMessagingTimeout(child, 0.12)
            guard let bounds = axFrame(of: child) else { continue }
            let title = axAttribute("AXTitle", of: child) as? String ?? ""
            let desc = axAttribute("AXDescription", of: child) as? String ?? ""
            let identifier = axAttribute("AXIdentifier", of: child) as? String ?? ""
            result.append(AXMenuBarEntry(
                pid: app.pid,
                frame: bounds,
                title: title,
                description: desc,
                identifier: identifier,
                appName: app.localizedName,
                bundleIdentifier: app.bundleIdentifier
            ))
        }
        return result
    }

    private static func axAttribute(_ name: String, of source: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(source, name as CFString, &value) == .success ? value : nil
    }

    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        guard let position = axAttribute("AXPosition", of: element), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = axAttribute("AXSize", of: element), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
