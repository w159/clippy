import Foundation

/// OCR recognition preferences (OCR-07, OCR-08). UserDefaults-backed under the
/// `ocr.` prefix; the language list shares its key with
/// `CapturePreferences.ocrLanguages` so there is a single source of truth.
enum OCRPreferences {
    /// Speed/quality trade-off for Vision text recognition.
    enum Level: String, CaseIterable {
        case fast
        case accurate
    }

    /// Store the accessors read from; tests swap in an isolated suite.
    private static let seam = DefaultsSeam()
    static var defaults: UserDefaults {
        get { seam.value }
        set { seam.value = newValue }
    }

    private enum Key {
        static let level = "ocr.level"
        static let pdfMaxPages = "ocr.pdfMaxPages"
        static let documentRecognition = "ocr.useDocumentRecognition"
    }

    /// Default number of PDF pages read per extraction.
    static let defaultPDFMaxPages = 20
    /// Upper bound accepted for `pdfMaxPages`.
    static let maxPDFMaxPages = 500

    /// Explicit BCP-47 recognition languages; empty means Vision detects the
    /// language automatically.
    static var languages: [String] {
        get { CapturePreferences.ocrLanguages }
        set { CapturePreferences.ocrLanguages = newValue }
    }

    /// True when Vision should auto-detect the language.
    static var isAutomaticLanguage: Bool { languages.isEmpty }

    /// Recognition level; `.accurate` unless the user picked `.fast`.
    static var level: Level {
        get { defaults.string(forKey: Key.level).flatMap(Level.init(rawValue:)) ?? .accurate }
        set { defaults.set(newValue.rawValue, forKey: Key.level) }
    }

    /// Number of leading PDF pages processed, clamped to `1...maxPDFMaxPages`.
    static var pdfMaxPages: Int {
        get {
            guard defaults.object(forKey: Key.pdfMaxPages) != nil else { return defaultPDFMaxPages }
            return min(max(defaults.integer(forKey: Key.pdfMaxPages), 1), maxPDFMaxPages)
        }
        set { defaults.set(min(max(newValue, 1), maxPDFMaxPages), forKey: Key.pdfMaxPages) }
    }

    /// Whether macOS 26 document recognition (paragraphs, tables) is preferred
    /// over plain line recognition when the OS provides it. Default on.
    static var useDocumentRecognition: Bool {
        get {
            guard defaults.object(forKey: Key.documentRecognition) != nil else { return true }
            return defaults.bool(forKey: Key.documentRecognition)
        }
        set { defaults.set(newValue, forKey: Key.documentRecognition) }
    }
}
