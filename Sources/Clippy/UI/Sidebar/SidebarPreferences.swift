import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted (Cmd+Ctrl+S) to toggle the sidebar between expanded and icon rail.
    static let clippyToggleSidebar = Notification.Name("clippyToggleSidebar")
}

/// Persisted sidebar width and collapsed state (SBR-01, SBR-02).
///
/// UserDefaults keys (prefixed `sidebar.`): `sidebar.width` (Double, expanded
/// width in points) and `sidebar.collapsed` (Bool, user chose the icon rail).
@MainActor
final class SidebarPreferences: ObservableObject {
    /// Shared instance backed by `UserDefaults.standard`.
    static let shared = SidebarPreferences()

    /// UserDefaults key for the expanded width.
    nonisolated static let widthKey = "sidebar.width"
    /// UserDefaults key for the collapsed flag.
    nonisolated static let collapsedKey = "sidebar.collapsed"

    /// Expanded width; clamped for display by `SidebarSplitView`, persisted as set.
    @Published var width: CGFloat {
        didSet { defaults.set(Double(width), forKey: Self.widthKey) }
    }
    /// True when the user collapsed the sidebar to the icon rail.
    @Published var isCollapsed: Bool {
        didSet { defaults.set(isCollapsed, forKey: Self.collapsedKey) }
    }

    private let defaults: UserDefaults

    /// Loads persisted values from `defaults`; a missing or non-positive width falls back to the default.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.widthKey)
        width = stored > 0 ? CGFloat(stored) : SidebarMetrics.defaultWidth
        isCollapsed = defaults.bool(forKey: Self.collapsedKey)
    }

    /// Flips the collapsed state.
    func toggleCollapsed() { isCollapsed.toggle() }

    /// Restores the default expanded width.
    func resetWidth() { width = SidebarMetrics.defaultWidth }
}
