import Foundation

/// Section a palette command is grouped under.
enum PaletteSection: String, CaseIterable {
    case actions = "Actions"
    case navigate = "Navigate"
    case settings = "Settings"
}

/// One entry in the Cmd+K command palette. Later tasks contribute their own
/// commands by conforming to this protocol; the host only reads these members.
protocol PaletteCommand {
    /// Stable identifier (unique within one palette).
    var id: String { get }
    /// Primary line, matched with the highest weight.
    var title: String { get }
    /// Secondary line, matched with a low weight. Must never carry masked clip content.
    var subtitle: String? { get }
    /// SF Symbol name.
    var symbol: String { get }
    /// Extra search terms that are not shown.
    var keywords: [String] { get }
    /// Display-only shortcut hint such as "Cmd+P".
    var shortcut: String? { get }
    /// Group the command is listed under.
    var section: PaletteSection { get }
    /// False when the command cannot run in the current state (it is hidden).
    var isEnabled: Bool { get }
    /// Runs the command; the host closes the palette first.
    func perform()
}

extension PaletteCommand {
    var subtitle: String? { nil }
    var keywords: [String] { [] }
    var shortcut: String? { nil }
    var section: PaletteSection { .actions }
    var isEnabled: Bool { true }
}

/// Closure-backed command used for the built-ins and by feature code that has
/// no need for its own type.
struct ClosurePaletteCommand: PaletteCommand {
    let id: String
    let title: String
    let subtitle: String?
    let symbol: String
    let keywords: [String]
    let shortcut: String?
    let section: PaletteSection
    let isEnabled: Bool
    private let action: () -> Void

    init(id: String, title: String, subtitle: String? = nil, symbol: String, keywords: [String] = [],
         shortcut: String? = nil, section: PaletteSection = .actions, isEnabled: Bool = true,
         perform: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.keywords = keywords
        self.shortcut = shortcut
        self.section = section
        self.isEnabled = isEnabled
        self.action = perform
    }

    func perform() { action() }
}
