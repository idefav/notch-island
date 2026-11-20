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
        #expect(island.hoverIntent?.delay == .milliseconds(250))
        island.movePointer(inside: false)
        island.performHover(.open)
        #expect(island.presentation == .collapsed)
        island.movePointer(inside: true)
        island.performHover(.open)
        #expect(island.presentation == .preview)
        island.movePointer(inside: false)
        #expect(island.hoverIntent == .close)
        #expect(island.hoverIntent?.delay == .milliseconds(350))
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
        #expect(IslandTrigger.load(from: defaults) == .click)
        IslandTrigger.hover.save(to: defaults)
        let reloaded = try #require(UserDefaults(suiteName: suite))
        var island = IslandInteraction(trigger: IslandTrigger.load(from: reloaded))
        island.movePointer(inside: true)
        island.performHover(.open)
        #expect(island.presentation == .preview)
        island.setTrigger(.click)
        #expect(island.presentation == .collapsed)
        #expect(island.hoverIntent == nil)
    }

    @Test func wrappingCanvasAndInteractionRegionShareCorrectScreenAnchor() {
        let screen = CGRect(x: -1728, y: 323, width: 1728, height: 1117)
        func layout(expanded: Bool) -> IslandShellLayout {
            IslandShellLayout(screen: screen, centerX: -864, contentTop: screen.maxY - 32,
                              notchWidth: 185, notchHeight: 32, expanded: expanded, itemCount: 6)
        }
        let closed = layout(expanded: false)
        let open = layout(expanded: true)
        #expect(closed.canvasFrame == open.canvasFrame)
        #expect(closed.canvasFrame.maxY == screen.maxY)
        #expect(closed.contentFrame.maxY == open.contentFrame.maxY)
        #expect(closed.contentFrame.height == 10)
        #expect(closed.visibleDepth == 1)
        #expect(closed.contentFrame.maxY - (closed.canvasFrame.minY + closed.outline().boundingBoxOfPath.minY) == 1)
        #expect(closed.neckWidth == 187)
        #expect(closed.contentFrame.width == 187)
        #expect(closed.outline().boundingBoxOfPath.width == 187)
        let outline = closed.outline()
        let bounds = outline.boundingBoxOfPath
        #expect(!outline.contains(CGPoint(x: bounds.minX + 2, y: bounds.minY + 2)))
        #expect(outline.contains(CGPoint(x: bounds.midX, y: bounds.minY + 0.5)))
        #expect(open.contentFrame.width == 370)
        #expect(open.outline().boundingBoxOfPath.width > closed.outline().boundingBoxOfPath.width)
    }

    @MainActor @Test func reducedMotionOnlyAnimatesOpacity() throws {
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
        #expect((layers.first?.animation(forKey: "fade") as? CABasicAnimation)?.keyPath == "opacity")
        #expect((layers.last?.animation(forKey: "sweep") as? CAKeyframeAnimation)?.keyPath == "opacity")
    }
}
