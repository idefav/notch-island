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
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .hover
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}

enum IslandLayoutMode: String, CaseIterable {
    case wrap
    case scroll

    private static let preferenceKey = "islandLayoutMode"

    var title: String {
        switch self {
        case .wrap: "换行展示"
        case .scroll: "横向滚动"
        }
    }

    static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .wrap
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}

enum IslandPreferences {
    private static let hideInFullScreenKey = "islandHideInFullScreen"

    static func hideInFullScreen(from defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: hideInFullScreenKey) == nil { return true }
        return defaults.bool(forKey: hideInFullScreenKey)
    }

    static func setHideInFullScreen(_ value: Bool, to defaults: UserDefaults) {
        defaults.set(value, forKey: hideInFullScreenKey)
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
            case .open: .milliseconds(200)
            case .close: .milliseconds(320)
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
