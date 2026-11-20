import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@MainActor
private final class IslandPanel: NSPanel {
    var handleKey: ((UInt16) -> Bool)?
    var handleContextMenu: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event.keyCode) == true { return }
        if event.type == .rightMouseDown, let handleContextMenu {
            handleContextMenu(event)
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class IslandHostingView: NSHostingView<IslandView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class IslandShellPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class IslandController: NSObject, NSApplicationDelegate {
    private let state = IslandState()
    private let catalog = ItemCatalog()
    private var panel: IslandPanel!
    private var shellPanel: IslandShellPanel!
    private let shell = IslandShellView(frame: .zero)
    private var interaction = IslandInteraction(trigger: IslandTrigger.load(from: .standard))
    private var hoverTask: Task<Void, Never>?
    private var pendingHover: IslandInteraction.HoverIntent?
    private var contextMenuOpen = false
    private var sessionActive = true
    private var showedUnsupportedNotice = false
    private var unsupportedAlert: NSAlert?
    private var timer: Timer?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var currentDisplay: NotchedDisplay?
    private var catalogWindows = [StatusWindow]()

    func applicationDidFinishLaunching(_ notification: Notification) {
        shellPanel = IslandShellPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: true)
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        for window in [shellPanel!, panel!] {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            window.hidesOnDeactivate = false
            window.isMovable = false
        }
        shellPanel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        shellPanel.ignoresMouseEvents = true
        shellPanel.setAccessibilityHidden(true)
        shellPanel.setAccessibilityElement(false)
        shellPanel.contentView = shell
        panel.acceptsMouseMovedEvents = true
        panel.handleKey = { [weak self] in self?.handleKey($0) ?? false }
        panel.handleContextMenu = { [weak self] in self?.showContextMenu($0) }
        let hosting = IslandHostingView(rootView: IslandView(
            state: state,
            pin: { [weak self] in self?.pin() },
            dismiss: { [weak self] in self?.collapse() },
            activate: { [weak self] in self?.activate($0) },
            moveSelection: { [weak self] in self?.moveSelection($0) },
            requestPermissions: { [weak self] in self?.requestPermissions() }
        ))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setAccessibilityLabel("菜单栏灵动岛")
        refresh()
        positionPanel()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved]) { [weak self] event in
            let moving = event.type == .mouseMoved
            Task { @MainActor in
                if moving { self?.pointerChanged() } else { self?.collapse() }
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .mouseMoved]) { [weak self] event in
            if event.type == .mouseMoved { self?.pointerChanged() }
            else if event.window !== self?.panel { self?.collapse() }
            return event
        }
        let refreshTimer = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer = refreshTimer
        RunLoop.main.add(refreshTimer, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(updateDisplay),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(suspendSession), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(resumeSession), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appearanceChanged),
                              name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateVisibility()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        refresh()
        positionPanel()
        if currentDisplay == nil { showedUnsupportedNotice = false }
        updateVisibility()
        if currentDisplay != nil { pin() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        hoverTask?.cancel()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func tick() {
        refresh()
        positionPanel()
        updateVisibility()
    }

    @objc private func updateDisplay() {
        if interaction.presentation == .preview { collapse() }
        refresh(forceImages: true)
        positionPanel()
        updateVisibility()
        pointerChanged()
    }

    @objc private func suspendSession() {
        sessionActive = false
        hoverTask?.cancel()
        pendingHover = nil
        interaction.movePointer(inside: false)
        interaction.dismiss()
        applyPresentation()
        shell.stopHighlight()
        panel.orderOut(nil)
        shellPanel.orderOut(nil)
    }

    @objc private func resumeSession() {
        sessionActive = true
        refresh(forceImages: true)
        positionPanel()
        updateVisibility()
    }

    @objc private func appearanceChanged() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { shell.stopHighlight() }
    }

    private func refresh(forceImages: Bool = false) {
        let screenRecording = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        let screenPermissionChanged = state.screenRecording != screenRecording
        if screenPermissionChanged { state.screenRecording = screenRecording }
        if state.accessibility != accessibility { state.accessibility = accessibility }
        currentDisplay = NSScreen.screens.compactMap(NotchedDisplay.init).first
        guard let display = currentDisplay else { return }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else {
            if state.expanded {
                state.items = []
                state.selection = nil
                state.guidance = "当前系统版本尚未验证菜单栏读取"
            }
            return
        }
        guard state.expanded, !state.activating else { return }
        let snapshot = StatusSnapshot(display: display, otherDisplays: Self.otherDisplays(excluding: display))
        if forceImages || screenPermissionChanged || catalogWindows != snapshot.overflow {
            catalogWindows = snapshot.overflow
            state.items = catalog.items(in: snapshot, display: display)
            if !state.items.contains(where: { $0.id == state.selection }) {
                state.selection = state.items.first?.id
            }
        }
        if state.items.isEmpty {
            let guidance = snapshot.menuBarVisible ? nil : "菜单栏已隐藏，移到屏幕顶部后再试"
            if state.guidance != guidance { state.guidance = guidance }
        }
    }

    static func otherDisplays(excluding display: NotchedDisplay) -> [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard screen != display.screen,
                  let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
    }

    private func positionPanel(animated: Bool = false) {
        guard let display = currentDisplay else { return }
        let screen = display.screen
        let midX = screen.frame.minX + display.notch.midX - display.bounds.minX
        let notchHeight = display.notch.height
        let top = screen.frame.maxY - notchHeight
        let layout = IslandShellLayout(screen: screen.frame, centerX: midX, contentTop: top,
                                       notchWidth: display.notch.width, notchHeight: notchHeight,
                                       expanded: state.expanded, itemCount: state.items.count)
        if shellPanel.frame != layout.canvasFrame { shellPanel.setFrame(layout.canvasFrame, display: true) }
        shell.display(layout, animated: animated, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if panel.frame != layout.contentFrame { panel.setFrame(layout.contentFrame, display: true) }
    }

    private func updateVisibility() {
        guard sessionActive else { return }
        if currentDisplay != nil {
            showedUnsupportedNotice = false
            if let unsupportedAlert, NSApp.modalWindow == unsupportedAlert.window {
                NSApp.abortModal()
                unsupportedAlert.window.orderOut(nil)
            }
            if !shellPanel.isVisible { shellPanel.orderFrontRegardless() }
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        if panel.isVisible || shellPanel.isVisible {
            interaction.movePointer(inside: false)
            interaction.dismiss()
            applyPresentation()
            shell.stopHighlight()
            panel.orderOut(nil)
            shellPanel.orderOut(nil)
        }
        guard !showedUnsupportedNotice, unsupportedAlert == nil else { return }
        showedUnsupportedNotice = true
        let alert = NSAlert()
        alert.messageText = "当前显示器不支持菜单栏灵动岛"
        alert.informativeText = "打开或连接带刘海的显示屏后即可使用。"
        alert.addButton(withTitle: "好")
        unsupportedAlert = alert
        NSApp.activate()
        alert.runModal()
        unsupportedAlert = nil
    }

    private func pin() {
        guard sessionActive, currentDisplay != nil, !state.activating else { return }
        interaction.pin()
        applyPresentation()
    }

    private func collapse() {
        guard !state.activating else { return }
        interaction.movePointer(inside: panel.isVisible && panel.frame.contains(NSEvent.mouseLocation))
        interaction.dismiss()
        applyPresentation()
    }

    private func applyPresentation() {
        let wasExpanded = state.expanded
        guard state.presentation != interaction.presentation else { scheduleHover(); return }
        state.presentation = interaction.presentation
        if state.expanded, !wasExpanded {
            state.guidance = nil
            refresh(forceImages: true)
        } else if !state.expanded {
            state.items = []
            state.selection = nil
        }
        positionPanel(animated: true)
        if sessionActive, currentDisplay != nil {
            switch state.presentation {
            case .pinned:
                panel.makeKeyAndOrderFront(nil)
            case .preview:
                panel.orderFrontRegardless()
            case .collapsed:
                if panel.isKeyWindow { panel.orderOut(nil) }
                panel.orderFrontRegardless()
            }
        }
        if state.expanded, !wasExpanded {
            shell.playHighlight(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        pointerChanged()
    }

    private func pointerChanged() {
        let inside = sessionActive && currentDisplay != nil && panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
        if inside, !interaction.pointerInside, !contextMenuOpen {
            shell.playHighlight(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        interaction.movePointer(inside: inside)
        scheduleHover()
    }

    private func scheduleHover() {
        let intent = sessionActive && currentDisplay != nil && !contextMenuOpen && !state.activating ? interaction.hoverIntent : nil
        guard intent != pendingHover else { return }
        hoverTask?.cancel()
        pendingHover = intent
        guard let intent else { return }
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(for: intent.delay) } catch { return }
            guard let self, self.pendingHover == intent else { return }
            self.pendingHover = nil
            self.interaction.movePointer(inside: self.panel.frame.contains(NSEvent.mouseLocation))
            self.interaction.performHover(intent)
            self.applyPresentation()
        }
    }

    private func handleKey(_ code: UInt16) -> Bool {
        guard state.presentation == .pinned else { return false }
        switch code {
        case 53: collapse()
        case 123: moveSelection(-1)
        case 124: moveSelection(1)
        case 36, 76:
            guard let item = state.items.first(where: { $0.id == state.selection }) else { return false }
            activate(item)
        default: return false
        }
        return true
    }

    private func moveSelection(_ step: Int) {
        guard !state.items.isEmpty, !state.activating else { return }
        let current = state.items.firstIndex(where: { $0.id == state.selection }) ?? 0
        let next = (current + step + state.items.count) % state.items.count
        state.selection = state.items[next].id
    }

    private func activate(_ item: IslandItem) {
        guard !state.activating else { return }
        guard AXIsProcessTrusted() else {
            state.accessibility = false
            state.guidance = "允许辅助功能后才能打开原生菜单"
            return
        }
        guard let display = currentDisplay else { return }
        let snapshot = StatusSnapshot(display: display, otherDisplays: Self.otherDisplays(excluding: display))
        guard let current = snapshot.windows.first(where: { $0.id == item.id && $0.owner == item.window.owner }) else {
            refresh(forceImages: true)
            state.guidance = "该图标已离开菜单栏"
            return
        }
        let mirror = item.mirror.flatMap { match in
            snapshot.windows.first(where: { $0.id == match.id && $0.owner == match.owner && $0.visible })
        }
        let applications = NSWorkspace.shared.runningApplications
        let possibleOwners = applications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy != .prohibited
        }.map(\.processIdentifier)
        let namedOwners = item.bundleIdentifier.map { identifier in
            applications.filter { $0.bundleIdentifier == identifier }.map(\.processIdentifier)
        } ?? []
        var seen = Set<pid_t>()
        let pids = (namedOwners + [current.owner] + possibleOwners).filter { seen.insert($0).inserted }
        state.selection = item.id
        state.activating = true
        scheduleHover()
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                NativeMenu.open(for: current, mirror: current.visible ? current : mirror, preferredPIDs: pids)
            }.value
            state.activating = false
            switch result {
            case .requested: collapse()
            case .permissionRequired: state.guidance = "辅助功能权限已关闭"
            case .unavailable: state.guidance = "\(item.name) 的原生菜单当前不可访问"
            }
            scheduleHover()
        }
    }

    private func requestPermissions() {
        if !state.screenRecording {
            if !CGRequestScreenCaptureAccess(),
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else if !state.accessibility {
            requestAccessibility()
        }
        refresh(forceImages: true)
    }

    @objc private func requestAccessibility() {
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    private func showContextMenu(_ event: NSEvent) {
        contextMenuOpen = true
        scheduleHover()
        defer {
            contextMenuOpen = false
            pointerChanged()
        }
        let menu = NSMenu()
        menu.addItem(withTitle: state.expanded ? "收起面板" : "展开面板",
                     action: #selector(toggleFromMenu), keyEquivalent: "").target = self
        let modes = NSMenu()
        for trigger in IslandTrigger.allCases {
            let item = modes.addItem(withTitle: trigger.title, action: #selector(changeTrigger), keyEquivalent: "")
            item.target = self
            item.representedObject = trigger.rawValue
            item.state = trigger == interaction.trigger ? .on : .off
        }
        let modeMenu = menu.addItem(withTitle: "展开方式", action: nil, keyEquivalent: "")
        menu.setSubmenu(modes, for: modeMenu)
        let loginStatus = SMAppService.mainApp.status
        let loginItem = menu.addItem(withTitle: "开机启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginStatus == .enabled ? .on : loginStatus == .requiresApproval ? .mixed : .off
        if loginStatus == .requiresApproval {
            menu.addItem(withTitle: "在系统设置中允许开机启动…",
                         action: #selector(openLoginItemSettings), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "刷新图标", action: #selector(updateDisplay), keyEquivalent: "").target = self
        menu.addItem(withTitle: "辅助功能授权…", action: #selector(requestAccessibility), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出菜单栏灵动岛", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        if let view = panel.contentView { NSMenu.popUpContextMenu(menu, with: event, for: view) }
    }

    @objc private func toggleFromMenu() {
        if state.expanded { collapse() } else { pin() }
    }

    @objc private func changeTrigger(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let trigger = IslandTrigger(rawValue: value) else { return }
        interaction.setTrigger(trigger)
        trigger.save(to: .standard)
        applyPresentation()
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                openLoginItemSettings()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "无法更改开机启动"
            NSApp.activate()
            alert.runModal()
        }
    }

    @objc private func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@main
@MainActor
struct NotchIsland {
    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            diagnose()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = IslandController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }

    private static func diagnose() {
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("屏幕录制=\(CGPreflightScreenCaptureAccess()) 辅助功能=\(AXIsProcessTrusted())")
        let loginStatus = SMAppService.mainApp.status
        print("开机启动=\(loginStatus == .enabled) 等待登录项批准=\(loginStatus == .requiresApproval)")
        guard let display = NSScreen.screens.compactMap(NotchedDisplay.init).first else {
            print("未找到刘海屏")
            return
        }
        let snapshot = StatusSnapshot(display: display, otherDisplays: IslandController.otherDisplays(excluding: display))
        let items = ItemCatalog().items(in: snapshot, display: display)
        print("刘海=\(display.notch) 菜单栏可见=\(snapshot.menuBarVisible) 溢出项=\(items.count)")
        for item in items {
            print("#\(item.id) \(item.name) 图标=\(item.image != nil) 其他屏幕对应项=\(item.mirror?.id.description ?? "无")")
        }
    }
}
