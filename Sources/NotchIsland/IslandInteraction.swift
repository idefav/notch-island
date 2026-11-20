import Foundation

enum IslandTrigger: String, CaseIterable {
    case click
    case hover

    private static let preferenceKey = "islandExpansionTrigger"

    var title: String {
        switch self {
        case .click: "点击展开"
        case .hover: "悬停展开"
        }
    }

    static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .click
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}

enum IslandPresentation: Equatable {
    case collapsed
    case preview
    case pinned

    var expanded: Bool { self != .collapsed }
}

struct IslandInteraction {
    enum HoverIntent: Equatable {
        case open
        case close

        var delay: Duration {
            switch self {
            case .open: .milliseconds(250)
            case .close: .milliseconds(350)
            }
        }
    }

    private(set) var trigger: IslandTrigger
    private(set) var presentation = IslandPresentation.collapsed
    private(set) var pointerInside = false
    private var waitForPointerExit = false

    init(trigger: IslandTrigger) {
        self.trigger = trigger
    }

    var hoverIntent: HoverIntent? {
        guard trigger == .hover else { return nil }
        switch presentation {
        case .collapsed: return pointerInside && !waitForPointerExit ? .open : nil
        case .preview: return pointerInside ? nil : .close
        case .pinned: return nil
        }
    }

    mutating func movePointer(inside: Bool) {
        pointerInside = inside
        if !inside { waitForPointerExit = false }
    }

    mutating func setTrigger(_ value: IslandTrigger) {
        guard trigger != value else { return }
        trigger = value
        if presentation == .preview { dismiss() }
        waitForPointerExit = pointerInside
    }

    mutating func pin() {
        presentation = .pinned
    }

    mutating func dismiss() {
        presentation = .collapsed
        waitForPointerExit = pointerInside
    }

    mutating func performHover(_ intent: HoverIntent) {
        guard hoverIntent == intent else { return }
        switch intent {
        case .open: presentation = .preview
        case .close: dismiss()
        }
    }
}
