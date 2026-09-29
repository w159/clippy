import Foundation

/// The user-configurable hard ceiling on the total number of stored clips
/// (DAT-06). Backed by its own UserDefaults key so it needs no AppSettings
/// change; the Settings redesign can bind a stepper to `StorageCeiling.current`.
///
/// Pinned/categorized clips are never evicted by the ceiling. When they alone
/// exceed it, the table simply stays over the ceiling and the store warns.
enum StorageCeiling {
    /// UserDefaults key. Prefixed with the storage area.
    static let defaultsKey = "storage.clipCeiling"
    static let defaultValue = 10_000
    /// Floor so a mistyped value cannot make every insert evict the history.
    static let minimum = 100
    /// Usage fraction at which the store starts warning.
    static let warningFraction = 0.9

    /// The active ceiling, clamped to `minimum`. Assign to persist.
    static var current: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: defaultsKey)
            return stored == 0 ? defaultValue : max(minimum, stored)
        }
        set { UserDefaults.standard.set(max(minimum, newValue), forKey: defaultsKey) }
    }

    /// True when `count` has reached the warning threshold for `ceiling`.
    static func isNearCeiling(count: Int, ceiling: Int) -> Bool {
        Double(count) >= Double(ceiling) * warningFraction
    }
}

/// Snapshot of clip-table usage against the ceiling, for the warning banner.
struct StorageUsage: Equatable {
    var count: Int
    var ceiling: Int

    var isNearCeiling: Bool { StorageCeiling.isNearCeiling(count: count, ceiling: ceiling) }
}
