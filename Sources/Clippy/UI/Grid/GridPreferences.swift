import SwiftUI

/// How many columns the clip grid uses in the `cards` density.
enum GridColumnMode: Codable, Equatable {
    /// Derive the count from the panel width (default).
    case auto
    /// Request a fixed count; still capped by what the width can hold.
    case fixed(Int)

    /// Compact string used for UserDefaults persistence (`auto`, `fixed:3`).
    var storageValue: String {
        switch self {
        case .auto: return "auto"
        case .fixed(let count): return "fixed:\(max(1, count))"
        }
    }

    /// Parses `storageValue`; anything unrecognised falls back to `.auto`.
    init(storageValue: String?) {
        guard let raw = storageValue, raw.hasPrefix("fixed:"), let count = Int(raw.dropFirst(6)), count >= 1 else {
            self = .auto
            return
        }
        self = .fixed(count)
    }
}

/// Row density of the clip list (LAY-08).
enum ClipDensity: String, CaseIterable {
    /// Single-line ~32pt rows.
    case compact
    /// Two-line rows with a short preview.
    case comfortable
    /// Full preview cards laid out in a grid.
    case cards

    /// Segmented-control title.
    var title: String {
        switch self {
        case .compact: return "Rows"
        case .comfortable: return "Comfortable"
        case .cards: return "Cards"
        }
    }

    /// SF Symbol shown in the density switch.
    var symbolName: String {
        switch self {
        case .compact: return "list.bullet"
        case .comfortable: return "list.bullet.below.rectangle"
        case .cards: return "square.grid.2x2"
        }
    }
}

/// Persisted grid presentation choices for the History pane.
///
/// UserDefaults keys (all prefixed `grid.`): `grid.columnMode` (`auto` or
/// `fixed:N`, default `auto`) and `grid.density` (`compact`, `comfortable`,
/// `cards`, default `compact`).
@MainActor
final class GridPreferences: ObservableObject {
    /// Process-wide instance used by the panel.
    static let shared = GridPreferences()

    /// UserDefaults key for `columnMode`.
    nonisolated static let columnModeKey = "grid.columnMode"
    /// UserDefaults key for `density`.
    nonisolated static let densityKey = "grid.density"

    private let defaults: UserDefaults

    /// Column selection used in the cards density.
    @Published var columnMode: GridColumnMode {
        didSet { defaults.set(columnMode.storageValue, forKey: Self.columnModeKey) }
    }

    /// Row density.
    @Published var density: ClipDensity {
        didSet { defaults.set(density.rawValue, forKey: Self.densityKey) }
    }

    /// Reads persisted values; `defaults` is injectable for tests.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        columnMode = GridColumnMode(storageValue: defaults.string(forKey: Self.columnModeKey))
        density = defaults.string(forKey: Self.densityKey).flatMap(ClipDensity.init(rawValue:)) ?? .compact
    }
}
