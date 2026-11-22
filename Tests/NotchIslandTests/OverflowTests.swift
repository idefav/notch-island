import CoreGraphics
import Testing
@testable import NotchIsland

struct OverflowTests {
    private let notch = CGRect(x: 771, y: 0, width: 185, height: 32)

    private func item(_ id: CGWindowID, x: CGFloat, width: CGFloat, visible: Bool = false) -> StatusWindow {
        StatusWindow(id: id, owner: 100, title: "", frame: CGRect(x: x, y: 0, width: width, height: 33), visible: visible)
    }

    @Test func sixContiguousItemsStraddlingTheNotch() {
        let firstVisible = item(20, x: 1003, width: 65, visible: true)
        let items = [
            item(10, x: 629, width: 38), item(11, x: 667, width: 86),
            item(12, x: 753, width: 38), item(13, x: 791, width: 38),
            item(14, x: 829, width: 130), item(15, x: 959, width: 44),
            firstVisible, item(21, x: 1068, width: 44, visible: true),
            item(30, x: 20, width: 40),
        ]
        #expect(StatusSnapshot.overflow(in: items.reversed(), notch: notch).map(\.id) == [10, 11, 12, 13, 14, 15])
    }

    @Test func invisibleWindowsAwayFromCurrentNotchAreIgnored() {
        let items = [item(10, x: 400, width: 40), item(20, x: 1100, width: 60, visible: true)]
        #expect(StatusSnapshot.overflow(in: items, notch: notch).isEmpty)
    }

    @Test func noVisibilityAnchorMeansNoOverflow() {
        #expect(StatusSnapshot.overflow(in: [item(10, x: 900, width: 80)], notch: notch).isEmpty)
    }

    @Test func coordinatesUseDisplayOrigin() {
        let external = CGRect(x: -1920, y: -180, width: 1920, height: 1080)
        #expect(StatusSnapshot.onMenuBar(CGRect(x: -198, y: -180, width: 42, height: 30), external))
        #expect(!StatusSnapshot.onMenuBar(CGRect(x: -198, y: 0, width: 42, height: 30), external))
    }

    @Test func overlappingWideOffSpaceWindowDoesNotSwallowRealItems() {
        let firstVisible = item(20, x: 1000, width: 50, visible: true)
        let staleWide = item(99, x: 840, width: 160) // same maxX = 1000, stale wide overlay from another Space
        let realLeft = item(11, x: 920, width: 40)
        let realRight = item(12, x: 960, width: 40)
        let result = StatusSnapshot.overflow(in: [staleWide, realLeft, realRight, firstVisible], notch: notch)
        #expect(result.map(\.id) == [11, 12])
    }

    @Test func narrowSpacerGapDoesNotBreakOverflowChain() {
        let firstVisible = item(20, x: 1000, width: 50, visible: true)
        let leftItem = item(11, x: 900, width: 44)  // ends at 944, 16pt gap before rightItem (e.g. narrow divider)
        let rightItem = item(12, x: 960, width: 40) // 960..1000
        let result = StatusSnapshot.overflow(in: [leftItem, rightItem, firstVisible], notch: notch)
        #expect(result.map(\.id) == [11, 12])
    }
}
