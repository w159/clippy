import AppKit
import Foundation
import UniformTypeIdentifiers

/// Export formats for the clip editor's Save As (EDT-06e).
enum EditorExportFormat: String, CaseIterable, Identifiable {
    case text, markdown, rtf, html

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "Plain Text (.txt)"
        case .markdown: return "Markdown (.md)"
        case .rtf: return "Rich Text (.rtf)"
        case .html: return "HTML (.html)"
        }
    }

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
        case .rtf: return "rtf"
        case .html: return "html"
        }
    }

    var contentType: UTType {
        switch self {
        case .text: return .plainText
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .rtf: return .rtf
        case .html: return .html
        }
    }

    /// Format implied by a chosen file extension; plain text when unknown.
    init(fileExtension: String) {
        self = Self.allCases.first { $0.fileExtension == fileExtension.lowercased() } ?? .text
    }
}

enum EditorExport {
    /// Bytes to write for `format`. `rich` is the styled version of the
    /// document when the clip has one (rich clips); without it RTF/HTML are
    /// built from the plain text.
    @MainActor
    static func data(text: String, rich: NSAttributedString?, format: EditorExportFormat) -> Data? {
        switch format {
        case .text, .markdown:
            return Data(text.utf8)
        case .rtf:
            return RichTextConverter.rtfData(from: rich ?? NSAttributedString(string: text))
        case .html:
            if let rich { return RichTextConverter.htmlData(from: rich) }
            return RichTextConverter.htmlDocument(escaping: text)
        }
    }

    /// A safe default filename (no path separators) with the format's extension.
    static func suggestedName(title: String, format: EditorExportFormat) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? "Clip" : String(cleaned.prefix(60))
        return "\(base).\(format.fileExtension)"
    }

    /// Shows the save panel and writes the file. Returns the saved URL, nil
    /// when cancelled; throws when the write fails. Nothing is logged: the
    /// content may be client data.
    @MainActor
    static func saveAs(text: String, rich: NSAttributedString?, title: String,
                       format: EditorExportFormat, window: NSWindow?) async throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = suggestedName(title: title, format: format)
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        let chosen = EditorExportFormat(fileExtension: url.pathExtension)
        guard let payload = data(text: text, rich: rich, format: chosen) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try payload.write(to: url, options: .atomic)
        return url
    }
}
