import Foundation

/// UserDefaults-backed opt-ins for the semantic features (FEAT-15/16). Every
/// switch defaults to OFF. Nothing here touches the network: embeddings and
/// language models run on this Mac.
///
/// Keys (all in the standard suite unless a suite is injected):
/// - `clippy.semantic.enabled`: semantic search opt-in (default false).
/// - `clippy.semantic.autoFile.enabled`: category suggestions for uncategorized clips (default false).
/// - `clippy.semantic.autoFile.foundationRefinement`: Foundation Models refinement (default false).
struct SemanticSearchPreferences {
    /// UserDefaults key strings, exposed for documentation and tests.
    enum Key {
        static let enabled = "clippy.semantic.enabled"
        static let autoFile = "clippy.semantic.autoFile.enabled"
        static let refinement = "clippy.semantic.autoFile.foundationRefinement"
    }

    /// The store the shipped app reads.
    static let standard = SemanticSearchPreferences(defaults: .standard)

    private let defaults: UserDefaults

    /// `defaults` is injectable so tests use a throwaway suite.
    init(defaults: UserDefaults) { self.defaults = defaults }

    /// Semantic search opt-in. Only an explicit user action may set this true.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        nonmutating set { defaults.set(newValue, forKey: Key.enabled) }
    }

    /// Auto-file suggestions on/off.
    var isAutoFileEnabled: Bool {
        get { defaults.bool(forKey: Key.autoFile) }
        nonmutating set { defaults.set(newValue, forKey: Key.autoFile) }
    }

    /// Optional on-device Foundation Models refinement of category suggestions.
    var isFoundationRefinementEnabled: Bool {
        get { defaults.bool(forKey: Key.refinement) }
        nonmutating set { defaults.set(newValue, forKey: Key.refinement) }
    }
}
