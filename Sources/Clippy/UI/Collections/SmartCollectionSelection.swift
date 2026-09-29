import Foundation
import Combine

/// Data access used by the selection model; injectable for tests.
protocol SmartCollectionSource {
    /// All collections in sort order.
    func collections() throws -> [SmartCollection]
    /// Number of clips matching the rule (capped by `limit`).
    func count(matching rule: SmartCollectionRule, limit: Int) throws -> Int
    /// Clips matching the rule, newest first.
    func clips(matching rule: SmartCollectionRule, limit: Int) throws -> [Clip]
    /// Deletes the collection rule only.
    func delete(id: Int64) throws
}

/// `ClipDatabase`-backed source. Sensitive clips are excluded from counts and results by the caller's rule evaluation
/// using the shared flag store.
struct DatabaseSmartCollectionSource: SmartCollectionSource {
    let database: ClipDatabase

    /// All collections.
    func collections() throws -> [SmartCollection] { try database.smartCollections() }

    /// Counts matches; sensitive clips are filtered out of the number.
    func count(matching rule: SmartCollectionRule, limit: Int) throws -> Int {
        try clips(matching: rule, limit: limit).count
    }

    /// Matches with sensitive clips removed (they never appear in derived lists).
    func clips(matching rule: SmartCollectionRule, limit: Int) throws -> [Clip] {
        try database.clips(matching: rule, limit: limit, sensitiveStore: SensitiveFlagStore.current)
            .filter { !SensitiveContent.isSensitive(clip: $0) }
    }

    /// Deletes the rule.
    func delete(id: Int64) throws { try database.deleteSmartCollection(id: id) }
}

/// Selection + counts for the sidebar's smart collections. The History list filters by `activeRule`
/// (evaluate it with `ClipDatabase.clips(matching:)` or call `selectedClips()`), nil meaning no smart filter.
@MainActor
final class SmartCollectionSelection: ObservableObject {
    /// Highest count displayed; larger sets show as `countCap+`.
    static let countCap = 999

    /// Loaded collections.
    @Published private(set) var collections: [SmartCollection] = []
    /// Clip counts by collection id.
    @Published private(set) var counts: [Int64: Int] = [:]
    /// Selected collection id, nil when no smart collection filters History.
    @Published private(set) var selectedID: Int64?
    /// Last error message (never contains clip content).
    @Published private(set) var errorText: String?

    private let source: SmartCollectionSource

    /// Creates the model on a source.
    init(source: SmartCollectionSource) { self.source = source }

    /// Default model on the shared database.
    convenience init() { self.init(source: DatabaseSmartCollectionSource(database: ClipDatabase.shared)) }

    /// The selected collection.
    var selected: SmartCollection? { collections.first { $0.id == selectedID } }

    /// Rule the History filter should apply, nil when nothing is selected.
    var activeRule: SmartCollectionRule? { selected?.rule }

    /// Reloads collections and counts; drops a selection whose collection disappeared.
    func reload() {
        do {
            collections = try source.collections()
            counts = Dictionary(uniqueKeysWithValues: collections.compactMap { collection in
                collection.id.map { ($0, (try? source.count(matching: collection.rule, limit: Self.countCap + 1)) ?? 0) }
            })
            if let selectedID, !collections.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
            errorText = nil
        } catch {
            errorText = "Could not load smart collections."
        }
    }

    /// Selects a collection; selecting the selected one again clears the filter.
    func toggle(_ id: Int64) { selectedID = selectedID == id ? nil : id }

    /// Clears the smart filter.
    func clear() { selectedID = nil }

    /// Display text for a count, e.g. `12` or `999+`.
    func countLabel(for id: Int64) -> String {
        let value = counts[id] ?? 0
        return value > Self.countCap ? "\(Self.countCap)+" : "\(value)"
    }

    /// Clips of the selected collection (empty when none selected).
    func selectedClips(limit: Int = 300) -> [Clip] {
        guard let rule = activeRule else { return [] }
        return (try? source.clips(matching: rule, limit: limit)) ?? []
    }

    /// Deletes a collection rule and refreshes.
    func delete(_ id: Int64) {
        do { try source.delete(id: id) } catch { errorText = "Could not delete the collection." }
        if selectedID == id { selectedID = nil }
        reload()
    }
}
