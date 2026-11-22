import AppKit
import QuartzCore
import Testing
@testable import NotchIsland

struct IslandInteractionTests {
    @Test func clickNeverArmsHover() {
        var island = IslandInteraction(trigger: .click)
        island.movePointer(inside: true)
        #expect(island.hoverIntent == nil)
        island.pin()
        island.movePointer(inside: false)
        #expect(island.presentation == .pinned)
        #expect(island.hoverIntent == nil)
    }

    @Test func briefEntryDoesNotOpenAndReturningCancelsClose() {
        var island = IslandInteraction(trigger: .hover)
        island.movePointer(inside: true)
        #expect(island.hoverIntent == .open)
        #expect(island.hoverIntent?.delay == .milliseconds(200))
        island.movePointer(inside: false)
        island.performHover(.open)
        #expect(island.presentation == .collapsed)
        island.movePointer(inside: true)
        island.performHover(.open)
        #expect(island.presentation == .preview)
        island.movePointer(inside: false)
        #expect(island.hoverIntent == .close)
        #expect(island.hoverIntent?.delay == .milliseconds(320))
        island.movePointer(inside: true)
        island.performHover(.close)
        #expect(island.presentation == .preview)
        island.movePointer(inside: false)
        island.performHover(.close)
        #expect(island.presentation == .collapsed)
    }

    @Test func pinKeepsHoverPreviewOpenAndDismissWaitsForReentry() {
        var island = IslandInteraction(trigger: .hover)
        island.movePointer(inside: true)
        island.performHover(.open)
        island.pin()
        island.movePointer(inside: false)
        island.performHover(.close)
        #expect(island.presentation == .pinned)
        island.movePointer(inside: true)
        island.dismiss()
        #expect(island.hoverIntent == nil)
        island.movePointer(inside: false)
        island.movePointer(inside: true)
        #expect(island.hoverIntent == .open)
    }

    @Test func preferenceSurvivesReloadAndModeChangesCancelPreview() throws {
        let suite = "notch-island-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(IslandTrigger.load(from: defaults) == .hover)
        #expect(IslandLayoutMode.load(from: defaults) == .wrap)
        #expect(IslandPreferences.hideInFullScreen(from: defaults) == true)

        IslandTrigger.click.save(to: defaults)
        IslandLayoutMode.scroll.save(to: defaults)
        IslandPreferences.setHideInFullScreen(false, to: defaults)
        let reloaded = try #require(UserDefaults(suiteName: suite))
        #expect(IslandTrigger.load(from: reloaded) == .click)
        #expect(IslandLayoutMode.load(from: reloaded) == .scroll)
        #expect(IslandPreferences.hideInFullScreen(from: reloaded) == false)

        IslandTrigger.hover.save(to: reloaded)
        var island = IslandInteraction(trigger: IslandTrigger.load(from: reloaded))
        island.movePointer(inside: true)
        island.performHover(.open)
        #expect(island.presentation == .preview)
        island.setTrigger(.click)
        #expect(island.presentation == .collapsed)
        #expect(island.hoverIntent == nil)
    }

    @Test func fullNotchHitZoneAndTShapedExpandedRegion() {
        let screen = CGRect(x: -1728, y: 323, width: 1728, height: 1117)
        let contentTop = screen.maxY - 32
        func layout(expanded: Bool) -> IslandShellLayout {
            IslandShellLayout(screen: screen, centerX: -864, contentTop: contentTop,
                              notchWidth: 185, notchHeight: 32, expanded: expanded, itemCount: 6)
        }
        let closed = layout(expanded: false)
        let open = layout(expanded: true)

        // Canvas stays constant across states so CoreAnimation morph works smoothly.
        #expect(closed.canvasFrame == open.canvasFrame)
        #expect(closed.canvasFrame.maxY == screen.maxY)
        #expect(closed.neckWidth == 187)
        #expect(closed.visibleDepth == 1)

        // Collapsed panel covers the entire physical notch + 2pt lip (no 10pt dead zone hanging over app windows).
        #expect(closed.panelFrame == closed.notchHitFrame)
        #expect(closed.notchHitFrame.maxY == screen.maxY)
        #expect(closed.notchHitFrame.height == 34)
        #expect(closed.notchHitFrame.width == 187)
        #expect(closed.bodyFrame.maxY - (closed.canvasFrame.minY + closed.outline().boundingBoxOfPath.minY) == 1)

        // Full-notch hit detection including inclusive top bezel (y == screen.maxY).
        #expect(closed.containsPointer(CGPoint(x: -864, y: screen.maxY)))
        #expect(closed.containsPointer(CGPoint(x: -864, y: screen.maxY - 16)))
        #expect(closed.containsPointer(CGPoint(x: -864, y: contentTop - 1)))
        // Below the 2pt lip should NOT trigger or steal clicks from windows underneath.
        #expect(!closed.containsPointer(CGPoint(x: -864, y: contentTop - 6)))

        // Expanded panel forms a T-shape: notch neck + body are inside; left/right menu bar wings are outside.
        #expect(open.panelFrame.maxY == screen.maxY)
        #expect(open.bodyFrame.width == 366)
        #expect(open.rowCount == 1)
        #expect(!open.needsVerticalScroll)
        #expect(open.containsPointer(CGPoint(x: -864, y: screen.maxY)))
        #expect(open.containsPointer(CGPoint(x: -864, y: contentTop - 80)))
        #expect(!open.containsPointer(CGPoint(x: open.panelFrame.minX + 12, y: screen.maxY - 10)))
        #expect(!open.containsPointer(CGPoint(x: open.panelFrame.maxX - 12, y: screen.maxY - 10)))

        // Outline & highlight paths keep identical segment topologies for smooth morphing.
        #expect(pathElementCount(closed.outline()) == pathElementCount(open.outline()))
        #expect(pathElementCount(closed.highlightPath()) == pathElementCount(open.highlightPath()))
        #expect(closed.outline().boundingBoxOfPath.width == 187)
        #expect(open.outline().boundingBoxOfPath.width > closed.outline().boundingBoxOfPath.width)
    }

    @Test func wrapModeGrowsHeightAcrossRowsWhileScrollModeStaysSingleRow() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let contentTop = screen.maxY - 32
        let twelveItems = Array(repeating: 60 as CGFloat, count: 12)
        let fortyItems = Array(repeating: 60 as CGFloat, count: 40)

        let oneRow = IslandShellLayout(screen: screen, centerX: 864, contentTop: contentTop,
                                       notchWidth: 185, notchHeight: 32, expanded: true,
                                       itemCount: 4, layoutMode: .wrap,
                                       itemWidths: Array(repeating: 60 as CGFloat, count: 4))
        let multiRow = IslandShellLayout(screen: screen, centerX: 864, contentTop: contentTop,
                                         notchWidth: 185, notchHeight: 32, expanded: true,
                                         itemCount: 12, layoutMode: .wrap, itemWidths: twelveItems)
        let capped = IslandShellLayout(screen: screen, centerX: 864, contentTop: contentTop,
                                       notchWidth: 185, notchHeight: 32, expanded: true,
                                       itemCount: 40, layoutMode: .wrap, itemWidths: fortyItems)
        let scrollMode = IslandShellLayout(screen: screen, centerX: 864, contentTop: contentTop,
                                           notchWidth: 185, notchHeight: 32, expanded: true,
                                           itemCount: 12, layoutMode: .scroll, itemWidths: twelveItems)

        #expect(oneRow.canvasFrame == multiRow.canvasFrame)
        #expect(multiRow.canvasFrame == capped.canvasFrame)
        #expect(oneRow.rowCount == 1)
        #expect(multiRow.rowCount == 2)
        #expect(!multiRow.needsVerticalScroll)
        #expect(multiRow.bodyFrame.height > oneRow.bodyFrame.height)
        #expect(capped.rowCount > IslandShellLayout.maxVisibleWrapRows)
        #expect(capped.needsVerticalScroll)
        #expect(capped.bodyFrame.height == IslandShellLayout.maxExpandedHeight)
        #expect(scrollMode.rowCount == 1)
        #expect(!scrollMode.needsVerticalScroll)
        #expect(scrollMode.bodyFrame.height == oneRow.bodyFrame.height)
    }

    @MainActor @Test func reducedMotionOnlyAnimatesOpacityAndSetsShadowPath() throws {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        func layout(_ expanded: Bool) -> IslandShellLayout {
            IslandShellLayout(screen: screen, centerX: 864, contentTop: 1085,
                              notchWidth: 185, notchHeight: 32, expanded: expanded, itemCount: 6)
        }
        let view = IslandShellView(frame: layout(false).canvasFrame)
        view.display(layout(false), animated: false, reduceMotion: true)
        view.display(layout(true), animated: true, reduceMotion: true)
        view.playHighlight(reduceMotion: true)
        let layers = try #require(view.layer?.sublayers)
        #expect(layers.allSatisfy { $0.animation(forKey: "shape") == nil })
        #expect(layers.allSatisfy { $0.contentsScale >= 1 })
        #expect(layers.first?.shadowPath != nil)
        #expect((layers.first?.animation(forKey: "fade") as? CABasicAnimation)?.keyPath == "opacity")
        #expect((layers.last?.animation(forKey: "sweep") as? CAKeyframeAnimation)?.keyPath == "opacity")
    }

    private func pathElementCount(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { _ in count += 1 }
        return count
    }
}
