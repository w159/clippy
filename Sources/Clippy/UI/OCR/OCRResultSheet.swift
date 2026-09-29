import AppKit
import SwiftUI

/// Attaches the Extract Text result sheet (OCR-01).
///
/// Usage, on the `ClipListView` body next to its other `.sheet` modifiers:
/// `.ocrResultSheet(store: store, onPaste: onPaste)`.
private struct OCRResultSheetModifier: ViewModifier {
    @ObservedObject var presenter: OCRPresenter
    let store: ClipStore
    let onPaste: (Clip, Bool) -> Void

    func body(content: Content) -> some View {
        content.sheet(
            item: Binding(get: { presenter.result }, set: { if $0 == nil { presenter.dismiss() } })
        ) { result in
            OCRResultView(
                result: result,
                onCopy: { text in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                },
                onSave: { text in
                    do {
                        try store.saveOCRText(text)
                        return true
                    } catch {
                        ClippyLog.error("OCR save failed: \(error)", category: ClippyLog.storage)
                        return false
                    }
                },
                onPaste: { text in onPaste(OCRResultSheetModifier.transientClip(text), true) },
                onDismiss: { presenter.dismiss() })
        }
    }

    /// Unsaved plain-text clip: pasting recognised text does not require saving it.
    static func transientClip(_ text: String) -> Clip {
        Clip(
            id: nil, contentText: text, contentRTF: nil, contentHTML: nil,
            typeIdentifier: "public.utf8-plain-text", sourceAppBundleID: nil,
            sourceAppName: "Clippy OCR", createdAt: Date())
    }
}

extension View {
    /// Presents `OCRPresenter.shared`'s pending result as a sheet.
    func ocrResultSheet(store: ClipStore, onPaste: @escaping (Clip, Bool) -> Void) -> some View {
        modifier(OCRResultSheetModifier(presenter: .shared, store: store, onPaste: onPaste))
    }
}
