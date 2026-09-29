import SwiftUI

// Layout controls for the redesigned clip grid, bound to GridPreferences (replaces the old clipColumns picker).

/// One-time move of the legacy `clipColumns` setting into `GridPreferences.columnMode`.
enum GridColumnMigration {
    /// Flag recording that the migration already ran.
    static let migratedKey = "settingsShell.gridColumnsMigrated"

    /// The mode to adopt, or nil when nothing should change. Only explicitly stored values count:
    /// registered defaults are process-wide and would make an untouched `clipColumns` look like "1".
    static func migratedMode(defaults: UserDefaults, persistentDomain: [String: Any]?) -> GridColumnMode? {
        guard !defaults.bool(forKey: migratedKey) else { return nil }
        guard persistentDomain?[GridPreferences.columnModeKey] == nil else { return nil }
        guard let stored = persistentDomain?[AppSettings.Keys.clipColumns] as? Int, stored > 0 else { return nil }
        return .fixed(stored)
    }

    /// Runs the migration against `preferences`, recording the flag so it never repeats.
    @MainActor
    static func run(defaults: UserDefaults, domainName: String, preferences: GridPreferences) {
        let mode = migratedMode(defaults: defaults, persistentDomain: defaults.persistentDomain(forName: domainName))
        if let mode { preferences.columnMode = mode }
        defaults.set(true, forKey: migratedKey)
    }
}

struct GridSettingsSection: View {
    @ObservedObject private var grid = GridPreferences.shared

    /// Picker tags: 0 is Auto, 1...6 are fixed counts.
    private var columnTag: Binding<Int> {
        Binding(
            get: { if case .fixed(let count) = grid.columnMode { return min(max(count, 1), 6) } else { return 0 } },
            set: { grid.columnMode = $0 == 0 ? .auto : .fixed($0) }
        )
    }

    var body: some View {
        Section("Layout") {
            Picker("Density", selection: $grid.density) {
                ForEach(ClipDensity.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .settingsRow("appearance.density")
            SettingsNote(Self.caption(for: grid.density))
            Picker("Columns", selection: columnTag) {
                Text("Auto").tag(0)
                ForEach(1...6, id: \.self) { Text($0 == 1 ? "1 column" : "\($0) columns").tag($0) }
            }
            .settingsRow("appearance.columns")
            .disabled(grid.density != .cards)
            SettingsNote("Columns apply to the Cards density. Auto adds columns as the panel grows; a fixed count is capped by what the width can hold.")
        }
        .task {
            GridColumnMigration.run(defaults: .standard, domainName: Bundle.main.bundleIdentifier ?? "", preferences: grid)
        }
    }

    /// Short description under the density picker.
    static func caption(for density: ClipDensity) -> String {
        switch density {
        case .compact: return "Single-line rows: the most clips at a glance."
        case .comfortable: return "Two-line rows with a short preview."
        case .cards: return "Full preview cards laid out in a grid."
        }
    }
}
