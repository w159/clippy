import Foundation

/// Shared wording helpers so counts read correctly everywhere ("1 clip", "2 clips").
enum CopyFormat {
    /// `count` followed by the singular or plural noun. `plural` defaults to `noun + "s"`.
    static func counted(_ count: Int, _ noun: String, plural: String? = nil) -> String {
        "\(count.formatted()) \(count == 1 ? noun : (plural ?? noun + "s"))"
    }
}
