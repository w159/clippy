import Foundation

/// What the main pane is showing: the chronological history, one category,
/// the virtual 1Password vault (secrets shared to Clippy), the Scripts panel,
/// or the AI Assistant chat pane.
enum PanelSelection: Hashable {
    case history
    case category(Int64)
    case onePassword
    case scripts
    case assistant
    /// Manage built-in and custom AI actions. Routed to AIActionsManagerView
    /// in the main pane, mirroring the Scripts/Assistant side-pane rows.
    case aiActions
}
