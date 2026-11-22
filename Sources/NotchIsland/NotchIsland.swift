import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

@MainActor
private final class IslandPanel: NSPanel {
    var allowsKeyWindow = false
    var handleKey: ((NSEvent) -> Bool)?
    var handleContextMenu: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { allowsKeyWindow }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        if let handleContextMenu,
           event.type == .rightMouseDown ||
           (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            handleContextMenu(event)
            return
        }
        // Ensure the very first click inside an expanded .nonactivatingPanel (including nested NSScrollView)
        // is delivered immediately to SwiftUI controls without being dropped by acceptsFirstMouse == false.
        if event.type == .leftMouseDown, allowsKeyWindow, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class IslandHostingView: NSHostingView<IslandView> {
    var trackingScreenRects: [CGRect] = [] {
        didSet {
            guard trackingScreenRects != oldValue else { return }
            updateTrackingAreas()
        }
    }
    var onPointerBoundaryChange: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        guard let window else { return }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        for screenRect in trackingScreenRects {
            let windowRect = window.convertFromScreen(screenRect)
            let localRect = convert(windowRect, from: nil)
            guard !localRect.isEmpty else { continue }
            addTrackingArea(NSTrackingArea(rect: localRect, options: options, owner: self, userInfo: nil))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerBoundaryChange?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerBoundaryChange?()
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
           abs(event.scrollingDeltaX) < 0.01,
           let scrollView = findHorizontalScrollView(in: self) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 18
            let clip = scrollView.contentView
            var origin = clip.bounds.origin
            let maxX = max(0, (scrollView.documentView?.bounds.width ?? 0) - clip.bounds.width)
            origin.x = min(maxX, max(0, origin.x - delta))
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            return
        }
        super.scrollWheel(with: event)
    }

    private func findHorizontalScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView,
           let document = scrollView.documentView,
           document.bounds.width > scrollView.contentView.bounds.width + 1 {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findHorizontalScrollView(in: subview) { return found }
        }
        return nil
    }
}

@MainActor
private final class IslandShellPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class IslandController: NSObject, NSApplicationDelegate {
    private enum GuidanceKind {
        case menuBarHidden
        case accessibilityRequired
        case actionError
    }

    private let state = IslandState()
    private let catalog = ItemCatalog()
    private var panel: IslandPanel!
    private var hostingView: IslandHostingView!
    private var shellPanel: IslandShellPanel!
    private let shell = IslandShellView(frame: .zero)
    private var interaction = IslandInteraction(trigger: IslandTrigger.load(from: .standard))
    private var layoutMode = IslandLayoutMode.load(from: .standard)
    private var hideInFullScreen = IslandPreferences.hideInFullScreen(from: .standard)
    private var hiddenForFullScreen = false
    private var guidanceKind: GuidanceKind?
    private var hoverTask: Task<Void, Never>?
    private var collapseFrameTask: Task<Void, Never>?
    private var fullScreenRecheckTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var pendingHover: IslandInteraction.HoverIntent?
    private var contextMenuOpen = false
    private var sessionActive = true
    private var showedUnsupportedNotice = false
    private var unsupportedAlert: NSAlert?
    private var fallbackStatusItem: NSStatusItem?
    private var timer: Timer?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var currentDisplay: NotchedDisplay?
    private var currentLayout: IslandShellLayout?
    private var catalogWindows = [StatusWindow]()

    func applicationDidFinishLaunching(_ notification: Notification) {
        state.layoutMode = layoutMode
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
        panel.acceptsMouseMovedEvents = false
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
        hosting.onPointerBoundaryChange = { [weak self] in self?.pointerChanged() }
        hostingView = hosting
        panel.contentView = hosting
        panel.setAccessibilityLabel("菜单栏灵动岛")

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, !self.contextMenuOpen else { return event }
            if event.window !== self.panel { self.collapse() }
            return event
        }

        NotificationCenter.default.addObserver(self, selector: #selector(updateDisplay),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(permissionsMayHaveChanged),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(suspendSession), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(resumeSession), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appearanceChanged),
                              name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(spaceOrAppChanged),
                              name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(spaceOrAppChanged),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)

        refreshEnvironment()
        updateFullScreenState(scheduleFollowUp: false)
        positionPanel()
        updateVisibility(deferAlert: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        refreshEnvironment()
        updateFullScreenState(scheduleFollowUp: false)
        positionPanel()
        if currentDisplay == nil { showedUnsupportedNotice = false }
        updateVisibility(deferAlert: true)
        if currentDisplay != nil, !hiddenForFullScreen { pin() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRefreshTimer()
        removeOutsideMonitor()
        hoverTask?.cancel()
        collapseFrameTask?.cancel()
        fullScreenRecheckTask?.cancel()
        refreshTask?.cancel()
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let fallbackStatusItem { NSStatusBar.system.removeStatusItem(fallbackStatusItem) }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func tick() {
        refreshEnvironment()
        refreshItems(forceImages: false)
    }

    @objc private func permissionsMayHaveChanged() {
        refreshEnvironment()
        if state.expanded { refreshItems(forceImages: true) }
    }

    @objc private func updateDisplay() {
        if interaction.presentation == .preview { collapse() }
        refreshEnvironment()
        updateFullScreenState(scheduleFollowUp: true)
        positionPanel()
        updateVisibility(deferAlert: true)
        if state.expanded { refreshItems(forceImages: true) }
        pointerChanged()
    }

    @objc private func spaceOrAppChanged() {
        updateFullScreenState(scheduleFollowUp: true)
    }

    @objc private func suspendSession() {
        sessionActive = false
        hoverTask?.cancel()
        collapseFrameTask?.cancel()
        fullScreenRecheckTask?.cancel()
        refreshTask?.cancel()
        stopRefreshTimer()
        removeOutsideMonitor()
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
        refreshEnvironment()
        updateFullScreenState(scheduleFollowUp: true)
        positionPanel()
        updateVisibility(deferAlert: true)
        if state.expanded { refreshItems(forceImages: true) }
    }

    @objc private func appearanceChanged() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { shell.stopHighlight() }
    }

    private func setGuidance(_ text: String?, kind: GuidanceKind?) {
        guidanceKind = text == nil ? nil : kind
        if state.guidance != text { state.guidance = text }
    }

    private func clearGuidance(if kind: GuidanceKind) {
        if guidanceKind == kind { setGuidance(nil, kind: nil) }
    }

    private func refreshEnvironment() {
        let screenRecording = CGPreflightScreenCaptureAccess()
        let accessibility = AXIsProcessTrusted()
        if state.screenRecording != screenRecording { state.screenRecording = screenRecording }
        if state.accessibility != accessibility { state.accessibility = accessibility }
        if accessibility { clearGuidance(if: .accessibilityRequired) }
        currentDisplay = NSScreen.screens.compactMap(NotchedDisplay.init).first
    }

    private func updateFullScreenState(scheduleFollowUp: Bool) {
        fullScreenRecheckTask?.cancel()
        let nextHidden: Bool
        if hideInFullScreen, let display = currentDisplay {
            nextHidden = FullScreenDetector.isFullScreen(on: display.geometry)
        } else {
            nextHidden = false
        }
        if hiddenForFullScreen != nextHidden {
            hiddenForFullScreen = nextHidden
            if hiddenForFullScreen {
                hoverTask?.cancel()
                pendingHover = nil
                interaction.movePointer(inside: false)
                interaction.dismiss()
                applyPresentation()
                shell.stopHighlight()
            }
            updateVisibility(deferAlert: true)
            pointerChanged()
        }
        if scheduleFollowUp, hideInFullScreen, currentDisplay != nil {
            fullScreenRecheckTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                self?.updateFullScreenState(scheduleFollowUp: false)
            }
        }
    }

    private func refreshItems(forceImages: Bool) {
        guard let display = currentDisplay, !hiddenForFullScreen else { return }
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else {
            if state.expanded {
                state.items = []
                state.selection = nil
                state.isLoading = false
                setGuidance("当前系统版本尚未验证菜单栏读取", kind: .actionError)
            }
            return
        }
        guard state.expanded, !state.activating else { return }

        let geometry = display.geometry
        let others = Self.otherDisplays(excluding: display)
        let canCapture = state.screenRecording
        let previousWindows = catalogWindows
        let runningApps = ItemCatalog.currentRunningApps()
        let catalog = self.catalog
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask?.cancel()

        refreshTask = Task { [weak self] in
            let output = await Task.detached(priority: .userInitiated) { () -> (StatusSnapshot, [CapturedItem]?) in
                let snapshot = StatusSnapshot(display: geometry, otherDisplays: others)
                guard forceImages || previousWindows != snapshot.overflow else {
                    return (snapshot, nil)
                }
                let captured = catalog.captureItems(in: snapshot, display: geometry,
                                                    canCapture: canCapture, runningApps: runningApps)
                return (snapshot, captured)
            }.value

            guard let self, !Task.isCancelled,
                  self.refreshGeneration == generation,
                  self.state.expanded, !self.state.activating else { return }

            let (snapshot, captured) = output
            self.state.isLoading = false
            if let captured {
                self.catalogWindows = snapshot.overflow
                let previousWidths = self.state.items.map(\.estimatedTileWidth)
                self.state.items = self.catalog.resolveItems(from: captured)
                if !self.state.items.contains(where: { $0.id == self.state.selection }) {
                    self.state.selection = self.state.items.first?.id
                }
                if previousWidths != self.state.items.map(\.estimatedTileWidth) {
                    self.positionPanel(animated: true)
                }
            }
            if !snapshot.menuBarVisible && self.state.items.isEmpty {
                self.setGuidance("菜单栏已隐藏，移到屏幕顶部后再试", kind: .menuBarHidden)
            } else {
                self.clearGuidance(if: .menuBarHidden)
            }
        }
    }

    static func otherDisplays(excluding display: NotchedDisplay) -> [CGRect] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  number.uint32Value != display.displayID else { return nil }
            return CGDisplayBounds(number.uint32Value)
        }
    }

    private func computeLayout(expanded: Bool) -> IslandShellLayout? {
        guard let display = currentDisplay else { return nil }
        let screen = display.screen
        let midX = screen.frame.minX + display.notch.midX - display.bounds.minX
        let notchHeight = display.notch.height
        let top = screen.frame.maxY - notchHeight
        let itemWidths = state.items.map(\.estimatedTileWidth)
        return IslandShellLayout(screen: screen.frame, centerX: midX, contentTop: top,
                                 notchWidth: display.notch.width, notchHeight: notchHeight,
                                 expanded: expanded, itemCount: state.items.count,
                                 layoutMode: layoutMode, itemWidths: itemWidths)
    }

    private func positionPanel(animated: Bool = false, deferPanelShrink: Bool = false) {
        guard let layout = computeLayout(expanded: state.expanded) else { return }
        currentLayout = layout
        state.notchHeight = layout.notchHeight
        state.neckWidth = layout.neckWidth
        state.iconsHeight = layout.iconsHeight
        state.needsVerticalScroll = layout.needsVerticalScroll

        if shellPanel.frame != layout.canvasFrame {
            shellPanel.setFrame(layout.canvasFrame, display: true)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        shell.display(layout, animated: animated, reduceMotion: reduceMotion)

        collapseFrameTask?.cancel()
        if deferPanelShrink, !layout.expanded, panel.frame != layout.panelFrame {
            // Keep panel large briefly so SwiftUI fade-out is not clipped mid-transition,
            // while immediately shrinking tracking areas to the notch.
            hostingView.trackingScreenRects = layout.trackingScreenRects
            let shrinkDelay: Duration = reduceMotion ? .milliseconds(80) : .milliseconds(180)
            let targetFrame = layout.panelFrame
            let targetTracking = layout.trackingScreenRects
            collapseFrameTask = Task { [weak self] in
                do { try await Task.sleep(for: shrinkDelay) } catch { return }
                guard let self, !self.state.expanded else { return }
                if self.panel.frame != targetFrame {
                    self.panel.setFrame(targetFrame, display: true)
                }
                self.hostingView.trackingScreenRects = targetTracking
                self.state.items = []
                self.state.selection = nil
                self.catalogWindows = []
            }
        } else {
            if panel.frame != layout.panelFrame {
                panel.setFrame(layout.panelFrame, display: true)
            }
            hostingView.trackingScreenRects = layout.trackingScreenRects
        }
    }

    private func updateVisibility(deferAlert: Bool) {
        guard sessionActive else { return }
        if currentDisplay != nil {
            removeFallbackStatusItem()
            if let unsupportedAlert, NSApp.modalWindow == unsupportedAlert.window {
                NSApp.abortModal()
                unsupportedAlert.window.orderOut(nil)
            }
            if hiddenForFullScreen {
                panel.orderOut(nil)
                shellPanel.orderOut(nil)
                syncBackgroundMonitors()
                return
            }
            if !shellPanel.isVisible { shellPanel.orderFrontRegardless() }
            if !panel.isVisible { panel.orderFrontRegardless() }
            syncBackgroundMonitors()
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
        syncBackgroundMonitors()
        installFallbackStatusItem()
        guard !showedUnsupportedNotice, unsupportedAlert == nil else { return }
        showedUnsupportedNotice = true
        if deferAlert {
            DispatchQueue.main.async { [weak self] in self?.presentUnsupportedAlert() }
        } else {
            presentUnsupportedAlert()
        }
    }

    private func presentUnsupportedAlert() {
        guard currentDisplay == nil, unsupportedAlert == nil else { return }
        let alert = NSAlert()
        alert.messageText = "当前显示器不支持菜单栏灵动岛"
        alert.informativeText = "打开或连接带刘海的显示屏后即可自动恢复，也可通过菜单栏图标退出应用。"
        alert.addButton(withTitle: "后台等待")
        alert.addButton(withTitle: "退出应用")
        unsupportedAlert = alert
        NSApp.activate()
        let response = alert.runModal()
        unsupportedAlert = nil
        if response == .alertSecondButtonReturn {
            NSApp.terminate(nil)
        }
    }

    private func installFallbackStatusItem() {
        guard fallbackStatusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: "菜单栏灵动岛")
        let menu = NSMenu()
        let status = menu.addItem(withTitle: "等待带刘海的显示屏…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出菜单栏灵动岛", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        fallbackStatusItem = item
    }

    private func removeFallbackStatusItem() {
        guard let fallbackStatusItem else { return }
        NSStatusBar.system.removeStatusItem(fallbackStatusItem)
        self.fallbackStatusItem = nil
    }

    private func syncBackgroundMonitors() {
        let activeExpanded = state.expanded && sessionActive && currentDisplay != nil && !hiddenForFullScreen
        panel.acceptsMouseMovedEvents = activeExpanded
        if activeExpanded {
            installOutsideMonitor()
            startRefreshTimer()
        } else {
            removeOutsideMonitor()
            stopRefreshTimer()
        }
    }

    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.contextMenuOpen else { return }
                self.collapse()
            }
        }
    }

    private func removeOutsideMonitor() {
        guard let outsideMonitor else { return }
        NSEvent.removeMonitor(outsideMonitor)
        self.outsideMonitor = nil
    }

    private func startRefreshTimer() {
        guard timer == nil else { return }
        let refreshTimer = Timer(timeInterval: 1.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        refreshTimer.tolerance = 0.2
        timer = refreshTimer
        RunLoop.main.add(refreshTimer, forMode: .common)
    }

    private func stopRefreshTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func pin() {
        guard sessionActive, currentDisplay != nil, !hiddenForFullScreen, !state.activating else { return }
        interaction.pin()
        applyPresentation()
    }

    private func collapse() {
        guard !state.activating else { return }
        let inside = isPointerInsideCurrentIsland()
        interaction.movePointer(inside: inside)
        interaction.dismiss()
        applyPresentation()
    }

    private func applyPresentation() {
        let wasExpanded = state.expanded
        guard state.presentation != interaction.presentation else { scheduleHover(); return }
        state.presentation = interaction.presentation
        panel.allowsKeyWindow = state.expanded
        let shouldDeferShrink = wasExpanded && !state.expanded && sessionActive && currentDisplay != nil && !hiddenForFullScreen
        if state.expanded, !wasExpanded {
            setGuidance(nil, kind: nil)
            state.isLoading = state.items.isEmpty
            refreshEnvironment()
        } else if !state.expanded {
            refreshTask?.cancel()
            state.isLoading = false
            setGuidance(nil, kind: nil)
            if !shouldDeferShrink {
                state.items = []
                state.selection = nil
                catalogWindows = []
            }
        }
        positionPanel(animated: true, deferPanelShrink: shouldDeferShrink)
        if state.expanded, !wasExpanded {
            refreshItems(forceImages: true)
        }
        if sessionActive, currentDisplay != nil, !hiddenForFullScreen {
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
        syncBackgroundMonitors()
        if state.expanded, !wasExpanded {
            shell.playHighlight(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        pointerChanged()
    }

    private func isPointerInsideCurrentIsland() -> Bool {
        guard sessionActive, !hiddenForFullScreen, currentDisplay != nil,
              panel.isVisible, let currentLayout else { return false }
        return currentLayout.containsPointer(NSEvent.mouseLocation)
    }

    private func pointerChanged() {
        let inside = isPointerInsideCurrentIsland()
        if inside, !interaction.pointerInside, !contextMenuOpen {
            shell.playHighlight(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        interaction.movePointer(inside: inside)
        scheduleHover()
    }

    private func scheduleHover() {
        let intent = sessionActive && currentDisplay != nil && !hiddenForFullScreen && !contextMenuOpen && !state.activating
            ? interaction.hoverIntent : nil
        guard intent != pendingHover else { return }
        hoverTask?.cancel()
        pendingHover = intent
        guard let intent else { return }
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(for: intent.delay) } catch { return }
            guard let self, self.pendingHover == intent else { return }
            self.pendingHover = nil
            self.interaction.movePointer(inside: self.isPointerInsideCurrentIsland())
            self.interaction.performHover(intent)
            self.applyPresentation()
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers.isEmpty else { return false }
        if event.keyCode == 53, state.expanded {
            collapse()
            return true
        }
        guard state.presentation == .pinned else { return false }
        switch event.keyCode {
        case 123: moveSelection(-1)
        case 124: moveSelection(1)
        case 36, 76, 49:
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
            setGuidance("允许辅助功能后才能打开原生菜单", kind: .accessibilityRequired)
            return
        }
        guard let display = currentDisplay else { return }
        let geometry = display.geometry
        let others = Self.otherDisplays(excluding: display)
        let snapshot = StatusSnapshot(display: geometry, otherDisplays: others)
        guard let current = snapshot.windows.first(where: { $0.id == item.id && $0.owner == item.window.owner }) else {
            refreshItems(forceImages: true)
            setGuidance("该图标已离开菜单栏", kind: .actionError)
            return
        }
        let mirror = item.mirror.flatMap { match in
            snapshot.windows.first(where: { $0.id == match.id && $0.owner == match.owner && $0.visible })
        }
        let applications = NSWorkspace.shared.runningApplications
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let namedOwners = item.bundleIdentifier.map { identifier in
            applications.filter { $0.bundleIdentifier == identifier }.map(\.processIdentifier)
        } ?? []
        let systemHostIDs = AXExtrasCatalog.systemHostBundleIDs
        let systemHostPIDs = Set(applications.filter {
            $0.bundleIdentifier.map(systemHostIDs.contains) ?? false
        }.map(\.processIdentifier))
        let allRunningPIDs = applications.filter {
            $0.processIdentifier != currentPID && $0.activationPolicy != .prohibited
        }.map(\.processIdentifier)

        var seenPrimary = Set<pid_t>()
        let primarySeed: [pid_t] = (item.axOwnerPID.map { [$0] } ?? []) + namedOwners +
            (systemHostPIDs.contains(current.owner) ? [] : [current.owner])
        let primaryPIDs = primarySeed.filter { $0 != currentPID && seenPrimary.insert($0).inserted }

        var seenFallback = seenPrimary
        let fallbackPIDs = (allRunningPIDs + [current.owner] + Array(systemHostPIDs))
            .filter { $0 != currentPID && seenFallback.insert($0).inserted }

        state.selection = item.id
        state.activating = true
        scheduleHover()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                NativeMenu.open(for: current, mirror: current.visible ? current : mirror,
                                notch: geometry.notch,
                                primaryPIDs: primaryPIDs, fallbackPIDs: fallbackPIDs,
                                systemHostPIDs: systemHostPIDs)
            }.value
            guard let self else { return }
            self.state.activating = false
            switch result {
            case .requested:
                self.collapse()
            case .needsVisibleClick(let point):
                self.collapse()
                Task.detached(priority: .userInitiated) {
                    try? await Task.sleep(for: .milliseconds(30))
                    _ = NativeMenu.clickVisibleTarget(at: point)
                }
            case .permissionRequired:
                self.state.accessibility = false
                self.setGuidance("辅助功能权限已关闭", kind: .accessibilityRequired)
            case .unsupportedByApp, .unavailable:
                // Universal fallback for apps/helpers (including LoginItem helpers like iShotProHelper
                // and regular/accessory apps) whose hidden menu bar item does not support AXPress:
                // reopen the enclosing `.app` bundle so the app brings up its UI/main window.
                if await self.reopenOwnerOrEnclosingApp(for: item, fallbackPID: item.axOwnerPID ?? current.owner) {
                    self.collapse()
                } else if result == .unsupportedByApp {
                    self.setGuidance("\(item.name) 不支持辅助功能触发菜单（自定义状态栏图标）", kind: .actionError)
                } else {
                    self.setGuidance("\(item.name) 的原生菜单当前不可访问", kind: .actionError)
                }
            }
            self.scheduleHover()
        }
    }

    private func reopenOwnerOrEnclosingApp(for item: IslandItem, fallbackPID: pid_t) async -> Bool {
        let app = item.axOwnerPID.flatMap(NSRunningApplication.init(processIdentifier:))
            ?? item.bundleIdentifier.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            ?? NSRunningApplication(processIdentifier: fallbackPID)
        guard let app else { return false }
        if let bid = app.bundleIdentifier, AXExtrasCatalog.systemHostBundleIDs.contains(bid) {
            return false
        }
        if app.activationPolicy == .regular {
            app.unhide()
            if app.activate() { return true }
        }
        guard let bundleURL = app.bundleURL else { return false }
        let targetURL = AppBundleResolver.enclosingAppURL(for: bundleURL)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: targetURL, configuration: config)
            return true
        } catch {
            return false
        }
    }

    private func requestPermissions() {
        if !state.screenRecording {
            requestScreenRecording()
        } else if !state.accessibility {
            requestAccessibility()
        }
        refreshEnvironment()
        if state.expanded { refreshItems(forceImages: true) }
    }

    @objc private func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            if !CGRequestScreenCaptureAccess() {
                openPrivacySettings("Privacy_ScreenCapture")
            }
        } else {
            openPrivacySettings("Privacy_ScreenCapture")
        }
        refreshEnvironment()
    }

    @objc private func requestAccessibility() {
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            openPrivacySettings("Privacy_Accessibility")
        } else {
            openPrivacySettings("Privacy_Accessibility")
        }
        refreshEnvironment()
    }

    private func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showContextMenu(_ event: NSEvent) {
        contextMenuOpen = true
        scheduleHover()
        defer {
            contextMenuOpen = false
            pointerChanged()
        }
        refreshEnvironment()
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

        let layouts = NSMenu()
        for mode in IslandLayoutMode.allCases {
            let item = layouts.addItem(withTitle: mode.title, action: #selector(changeLayoutMode), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == layoutMode ? .on : .off
        }
        let layoutMenu = menu.addItem(withTitle: "图标排列", action: nil, keyEquivalent: "")
        menu.setSubmenu(layouts, for: layoutMenu)

        let fullScreenItem = menu.addItem(withTitle: "全屏时隐藏", action: #selector(toggleFullScreenAutoHide), keyEquivalent: "")
        fullScreenItem.target = self
        fullScreenItem.state = hideInFullScreen ? .on : .off

        let loginStatus = SMAppService.mainApp.status
        let loginItem = menu.addItem(withTitle: "开机启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginStatus == .enabled ? .on : loginStatus == .requiresApproval ? .mixed : .off
        if loginStatus == .requiresApproval {
            menu.addItem(withTitle: "在系统设置中允许开机启动…",
                         action: #selector(openLoginItemSettings), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "刷新图标", action: #selector(updateDisplay), keyEquivalent: "").target = self
        let screenRecItem = menu.addItem(withTitle: "屏幕录制授权…", action: #selector(requestScreenRecording), keyEquivalent: "")
        screenRecItem.target = self
        screenRecItem.state = state.screenRecording ? .on : .off
        let axItem = menu.addItem(withTitle: "辅助功能授权…", action: #selector(requestAccessibility), keyEquivalent: "")
        axItem.target = self
        axItem.state = state.accessibility ? .on : .off
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

    @objc private func changeLayoutMode(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let mode = IslandLayoutMode(rawValue: value),
              layoutMode != mode else { return }
        layoutMode = mode
        state.layoutMode = mode
        mode.save(to: .standard)
        positionPanel(animated: true)
    }

    @objc private func toggleFullScreenAutoHide() {
        hideInFullScreen.toggle()
        IslandPreferences.setHideInFullScreen(hideInFullScreen, to: .standard)
        updateFullScreenState(scheduleFollowUp: false)
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
        if let bundleID = Bundle.main.bundleIdentifier {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { $0.processIdentifier != currentPID && !$0.isTerminated }
            if let running {
                running.activate()
                return
            }
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
        let fullScreen = FullScreenDetector.isFullScreen(on: display.geometry)
        print("刘海=\(display.notch) 全屏=\(fullScreen) 菜单栏可见=\(snapshot.menuBarVisible) 溢出项=\(items.count)")
        for item in items {
            print("#\(item.id) \(item.name) AX归属=\(item.axOwnerPID.map(String.init) ?? "无") 图标=\(item.image != nil) 回退应用图标=\(item.isAppIconFallback) 其他屏幕对应项=\(item.mirror?.id.description ?? "无")")
        }
    }
}
