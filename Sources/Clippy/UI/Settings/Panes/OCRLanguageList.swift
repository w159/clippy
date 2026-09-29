import Foundation
import Vision

/// A selectable OCR recognition language.
struct OCRLanguage: Equatable, Identifiable {
    let code: String
    var id: String { code }
    /// Localized display name, falling back to the code.
    var name: String { Locale.current.localizedString(forIdentifier: code) ?? code }
}

/// Supported-language list with a static fallback and selection helpers.
enum OCRLanguageList {
    /// Used when Vision cannot report its languages.
    static let fallback = ["en-US", "fr-FR", "it-IT", "de-DE", "es-ES", "pt-BR", "zh-Hans", "zh-Hant", "yue-Hans", "yue-Hant", "ko-KR", "ja-JP", "ru-RU", "uk-UA", "th-TH", "vi-VT", "ar-SA"]

    /// Languages for the picker: Vision's own list when available, else the fallback. Sorted, deduplicated.
    static func supported(query: () -> [String]? = visionQuery) -> [OCRLanguage] {
        let reported = query() ?? []
        let codes = reported.isEmpty ? fallback : reported
        return Array(Set(codes)).sorted().map(OCRLanguage.init(code:))
    }

    /// Lightweight Vision call for accurate-level languages.
    static func visionQuery() -> [String]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return try? request.supportedRecognitionLanguages()
    }

    /// Returns `selected` with `code` toggled. Order follows first selection.
    static func toggled(_ code: String, in selected: [String]) -> [String] {
        selected.contains(code) ? selected.filter { $0 != code } : selected + [code]
    }

    /// Summary line for the pane: empty selection means automatic detection.
    static func summary(_ selected: [String]) -> String {
        selected.isEmpty ? "Automatic (Vision detects the language)" : selected.map { Locale.current.localizedString(forIdentifier: $0) ?? $0 }.joined(separator: ", ")
    }
}
