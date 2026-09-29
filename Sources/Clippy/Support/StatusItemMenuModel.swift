import Foundation

/// Pure model for the "recent clips" section of the status-item menu (PNL-10).
enum StatusItemMenuModel {
    /// Default number of clips listed.
    static let defaultLimit = 10
    /// Maximum characters of a clip title before truncation.
    static let maxTitleLength = 48

    /// One menu row. `clipIndex` points into the original clip array.
    struct Row: Equatable {
        let clipIndex: Int
        let title: String
    }

    /// The newest `limit` non-sensitive clips (input is newest first), titled by
    /// a single-line truncated preview. Sensitive clips are skipped entirely so
    /// their content can never reach a menu title or accessibility label; they
    /// do not consume a slot.
    static func rows(clips: [Clip], limit: Int = defaultLimit, isSensitive: (Clip) -> Bool) -> [Row] {
        var out: [Row] = []
        for (index, clip) in clips.enumerated() {
            if out.count >= limit { break }
            if isSensitive(clip) { continue }
            out.append(Row(clipIndex: index, title: title(for: clip)))
        }
        return out
    }

    /// Single-line, whitespace-collapsed, truncated title with a kind fallback.
    static func title(for clip: Clip) -> String {
        switch clip.contentKind {
        case .image: return "Image" + dimensions(clip)
        case .file: return clip.filePath.map { ($0 as NSString).lastPathComponent } ?? "File"
        case .text:
            let flat = clip.contentText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if flat.isEmpty { return "Empty text" }
            return truncate(flat, to: maxTitleLength)
        }
    }

    /// Truncates to `length` characters, ending with an ellipsis when cut.
    static func truncate(_ text: String, to length: Int) -> String {
        text.count <= length ? text : String(text.prefix(max(length - 1, 1))) + "\u{2026}"
    }

    private static func dimensions(_ clip: Clip) -> String {
        guard let width = clip.pixelWidth, let height = clip.pixelHeight else { return "" }
        return " \(width)\u{00D7}\(height)"
    }
}

/// How clicking the status item behaves (PNL-10). Persisted under
/// `statusItem.clickBehavior`; Settings can bind to `StatusItemPreferences.clickBehavior`.
enum StatusItemClickBehavior: String, CaseIterable {
    /// Left click toggles the panel, right click opens the menu (default).
    case panelOnLeftClick
    /// Any click opens the menu.
    case menuOnAnyClick

    /// Settings label.
    var title: String {
        switch self {
        case .panelOnLeftClick: return "Left click opens the panel, right click opens the menu"
        case .menuOnAnyClick: return "Any click opens the menu"
        }
    }
}

/// UserDefaults-backed status item preferences.
enum StatusItemPreferences {
    /// Key for `clickBehavior`.
    static let clickBehaviorKey = "statusItem.clickBehavior"
    /// Backing store; tests swap in a scratch suite.
    private static let seam = DefaultsSeam()
    static var defaults: UserDefaults {
        get { seam.value }
        set { seam.value = newValue }
    }

    /// Click behavior; defaults to `.panelOnLeftClick`.
    static var clickBehavior: StatusItemClickBehavior {
        get { defaults.string(forKey: clickBehaviorKey).flatMap(StatusItemClickBehavior.init(rawValue:)) ?? .panelOnLeftClick }
        set { defaults.set(newValue.rawValue, forKey: clickBehaviorKey) }
    }
}
