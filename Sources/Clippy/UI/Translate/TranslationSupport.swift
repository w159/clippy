import Foundation
import NaturalLanguage

/// Pure language helpers for translation (FEAT-25).
enum TranslationSupport {
    /// Languages offered in the target picker (BCP-47 identifiers).
    static let targetIdentifiers = [
        "en", "es", "fr", "de", "it", "pt", "nl", "ru", "ja", "ko", "zh-Hans", "zh-Hant", "ar", "tr", "pl", "sv",
    ]

    /// Maps a recognizer language to a `Locale.Language`; nil for undetermined.
    static func language(for recognized: NLLanguage?) -> Locale.Language? {
        guard let recognized, recognized != .undetermined else { return nil }
        switch recognized {
        case .simplifiedChinese: return Locale.Language(identifier: "zh-Hans")
        case .traditionalChinese: return Locale.Language(identifier: "zh-Hant")
        default: return Locale.Language(identifier: recognized.rawValue)
        }
    }

    /// Detects the dominant language of `text` (first 1000 characters).
    static func detectLanguage(of text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1000)))
        return language(for: recognizer.dominantLanguage)
    }

    /// True when both languages share a language code (translation is pointless).
    static func isSameLanguage(_ lhs: Locale.Language?, _ rhs: Locale.Language) -> Bool {
        guard let lhs else { return false }
        return lhs.languageCode == rhs.languageCode && (lhs.languageCode != "zh" || lhs.script == rhs.script)
    }

    /// Localized display name for a language.
    static func displayName(_ language: Locale.Language) -> String {
        let identifier = language.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// Destination for a finished translation.
protocol TranslateActionSink {
    func copy(_ text: String)
    func saveAsNewClip(_ text: String)
    func replaceClip(_ clipID: Int64, with text: String)
}

/// Decides whether translation may start.
enum TranslateGate: Equatable {
    case allowed
    case needsConfirmation
    case empty

    /// Sensitive clips need explicit confirmation; empty text is refused.
    static func evaluate(text: String, isSensitive: Bool, confirmed: Bool) -> TranslateGate {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        return isSensitive && !confirmed ? .needsConfirmation : .allowed
    }
}
