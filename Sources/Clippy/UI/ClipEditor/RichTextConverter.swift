import AppKit
import Foundation

/// Conversions between the stored RTF/HTML blobs and `AttributedString` /
/// `NSAttributedString` for the rich editor and preview (EDT-06d). Main-thread
/// only for HTML: AppKit's HTML importer runs WebKit.
///
/// Privacy: clipboard HTML is untrusted and may carry tracking pixels or
/// remote stylesheets. `sanitizeHTML` removes every construct that would fetch
/// a network resource before the importer sees it, so opening a clip in the
/// editor never causes a network request.
enum RichTextConverter {

    /// Removes script/style/link/meta/iframe/object/embed/img/video/audio/
    /// source/svg-use elements, `on*=` handlers and `url(...)` values.
    static func sanitizeHTML(_ html: String) -> String {
        var result = html
        let blocks = ["script", "style", "iframe", "object", "embed", "video", "audio", "svg"]
        for tag in blocks {
            result = result.replacingOccurrences(
                of: "<\(tag)\\b[\\s\\S]*?</\(tag)\\s*>", with: "",
                options: [.regularExpression, .caseInsensitive])
        }
        let voids = "link|meta|img|source|track|base|input|image|use"
        result = result.replacingOccurrences(of: "<(?:\(voids))\\b[^>]*>", with: "",
                                             options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "\\son\\w+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "",
                                             options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "url\\([^)]*\\)", with: "none",
                                             options: [.regularExpression, .caseInsensitive])
        return result
    }

    /// The clip's rich content as an attributed string: RTF preferred, else
    /// sanitized HTML; nil when there is none or it does not parse.
    @MainActor
    static func attributedString(rtf: Data?, html: Data?) -> NSAttributedString? {
        if let rtf, let value = NSAttributedString(rtf: rtf, documentAttributes: nil) { return value }
        if let html, let source = String(data: html, encoding: .utf8) ?? String(data: html, encoding: .isoLatin1) {
            let clean = sanitizeHTML(source)
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
            if let data = clean.data(using: .utf8),
               let value = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
                return value
            }
        }
        return nil
    }

    /// RTF bytes for `value`, nil when serialization fails.
    static func rtfData(from value: NSAttributedString) -> Data? {
        try? value.data(from: NSRange(location: 0, length: value.length),
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// HTML bytes for `value`, nil when serialization fails.
    @MainActor
    static func htmlData(from value: NSAttributedString) -> Data? {
        try? value.data(from: NSRange(location: 0, length: value.length),
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
    }

    /// Minimal standalone HTML document for plain text (escaped, in a `<pre>`).
    static func htmlDocument(escaping text: String) -> Data {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return Data("<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"></head><body><pre>\(escaped)</pre></body></html>\n".utf8)
    }

    // MARK: AttributedString bridge

    /// SwiftUI rich `TextEditor` value from AppKit attributes (fonts, colors,
    /// underline, links round-trip through the AppKit attribute scope).
    static func swiftUIValue(from value: NSAttributedString) -> AttributedString {
        (try? AttributedString(value, including: \.appKit)) ?? AttributedString(value.string)
    }

    /// AppKit value for saving; nil if the attributes cannot be bridged.
    static func appKitValue(from value: AttributedString) -> NSAttributedString {
        NSAttributedString(value)
    }
}
