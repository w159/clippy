import Foundation

/// Wording for the multi-select category submenu. `ClipStore.fileClip` only
/// removes other memberships when multiple categories are NOT allowed, so with
/// the setting on the action adds rather than moves.
enum BatchCategoryMenuLabel {
    /// `count` must be the number of clips the action really touches.
    static func title(count: Int, allowsMultipleCategories: Bool) -> String {
        "\(allowsMultipleCategories ? "Add" : "Move") \(count) to Category"
    }
}
