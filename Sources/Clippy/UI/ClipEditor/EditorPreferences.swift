import Foundation
import SwiftUI

/// How the editor treats a document for defaults: prose is spell-checked and
/// wrapped, code is neither.
enum EditorContentCategory: String {
    case code, prose

    init(language: CodeLanguage) {
        switch language {
        case .plain, .markdown: self = .prose
        default: self = .code
        }
    }
}

/// UserDefaults-backed clip editor preferences (EDT-06). Keys are prefixed
/// `clippy.editor.`; per-category values fall back to the defaults documented
/// on each accessor until the user toggles them. Observable so the toolbar
/// re-renders on change. The defaults store is injectable for tests.
@MainActor
final class EditorPreferences: ObservableObject {
    static let shared = EditorPreferences()

    static let minFontSize = 8.0
    static let maxFontSize = 40.0
    static let fontStep = 1.0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private enum Key {
        static let fontSize = "clippy.editor.fontSize"
        static let lineNumbers = "clippy.editor.showLineNumbers"
        static let preview = "clippy.editor.previewVisible"
        static func wrap(_ category: EditorContentCategory) -> String { "clippy.editor.wrap.\(category.rawValue)" }
        static func spell(_ category: EditorContentCategory) -> String { "clippy.editor.spellCheck.\(category.rawValue)" }
        static func smart(_ category: EditorContentCategory) -> String { "clippy.editor.smartSubstitutions.\(category.rawValue)" }
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    private func set(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
        objectWillChange.send()
    }

    // MARK: Font zoom

    /// The zoomed point size, or nil when the user never zoomed (follow the
    /// app font size). Always within `minFontSize...maxFontSize`.
    var fontSize: Double? {
        guard defaults.object(forKey: Key.fontSize) != nil else { return nil }
        return Self.clamp(defaults.double(forKey: Key.fontSize))
    }

    /// Cmd+=: one step larger than `current` (the size in effect now).
    func zoomIn(from current: Double) { setFontSize(current + Self.fontStep) }
    /// Cmd+-: one step smaller.
    func zoomOut(from current: Double) { setFontSize(current - Self.fontStep) }
    /// Cmd+0: forget the zoom and follow the app font size again.
    func resetZoom() {
        defaults.removeObject(forKey: Key.fontSize)
        objectWillChange.send()
    }

    private func setFontSize(_ value: Double) {
        defaults.set(Self.clamp(value), forKey: Key.fontSize)
        objectWillChange.send()
    }

    static func clamp(_ size: Double) -> Double { min(maxFontSize, max(minFontSize, size)) }

    // MARK: Toggles

    /// Line-number gutter. Default on.
    var showsLineNumbers: Bool {
        get { bool(Key.lineNumbers, default: true) }
        set { set(newValue, Key.lineNumbers) }
    }

    /// Split preview (markdown, CSV, rich source). Default on.
    var previewVisible: Bool {
        get { bool(Key.preview, default: true) }
        set { set(newValue, Key.preview) }
    }

    /// Word wrap. Default on for prose, off for code.
    func wraps(_ category: EditorContentCategory) -> Bool {
        bool(Key.wrap(category), default: category == .prose)
    }
    func setWraps(_ value: Bool, for category: EditorContentCategory) { set(value, Key.wrap(category)) }

    /// Spell and grammar checking. Default on for prose, off for code.
    func checksSpelling(_ category: EditorContentCategory) -> Bool {
        bool(Key.spell(category), default: category == .prose)
    }
    func setChecksSpelling(_ value: Bool, for category: EditorContentCategory) { set(value, Key.spell(category)) }

    /// Smart quotes/dashes/replacements. Default on for prose, off for code.
    func usesSmartSubstitutions(_ category: EditorContentCategory) -> Bool {
        bool(Key.smart(category), default: category == .prose)
    }
    func setUsesSmartSubstitutions(_ value: Bool, for category: EditorContentCategory) {
        set(value, Key.smart(category))
    }
}
