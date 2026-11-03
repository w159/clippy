import Foundation

/// Which recently added Settings panes the user has opened, so their NEW pill goes
/// away once it has done its job. Stored as a comma-separated list of pane ids.
enum SettingsSeenPanes {
    static let defaultsKey = "settings.seenNewPanes"

    static func showsNewPill(_ pane: SettingsPaneID, seen: String) -> Bool {
        pane.isNew && !ids(in: seen).contains(pane.rawValue)
    }

    /// `seen` with `pane` added; unchanged for panes that never show the pill.
    static func marking(_ pane: SettingsPaneID, in seen: String) -> String {
        guard pane.isNew, !ids(in: seen).contains(pane.rawValue) else { return seen }
        return (ids(in: seen) + [pane.rawValue]).joined(separator: ",")
    }

    private static func ids(in seen: String) -> [String] {
        seen.split(separator: ",").map(String.init)
    }
}
