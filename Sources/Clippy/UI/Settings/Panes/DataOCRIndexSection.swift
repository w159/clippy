import SwiftUI

/// OCR text index toggle with a delete-text confirmation when turning it off.
struct DataOCRIndexSection: View {
    @Binding var notice: PaneNotice?
    @State private var enabled = OCRIndexPreferences.isEnabled
    @State private var pending: Int?
    @State private var confirmOff = false

    /// Creates the section.
    init(notice: Binding<PaneNotice?>) { self._notice = notice }

    var body: some View {
        PaneSection("OCR text index", footer: "Recognizes text in image clips in the background so it becomes searchable. Text is stored locally; sensitive clips are skipped.") {
            SettingsRow(title: "Index text in images", detail: Text(progressText)) {
                Toggle("Index text in images", isOn: Binding(get: { enabled }, set: { toggle($0) })).labelsHidden()
            }
        }
        .task(id: enabled) { await refreshPending() }
        .confirmationDialog("Turn off OCR indexing?", isPresented: $confirmOff, titleVisibility: .visible) {
            Button("Turn Off and Delete Recognized Text", role: .destructive) { apply(false, deleteText: true) }
            Button("Turn Off, Keep Text") { apply(false, deleteText: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting removes all recognized text; image search stops finding words inside images.")
        }
    }

    private var progressText: String {
        guard enabled else { return "Off" }
        guard let pending else { return "Counting\u{2026}" }
        return pending == 0 ? "Up to date" : "\(pending)\(pending >= Self.sampleLimit ? "+" : "") image\(pending == 1 ? "" : "s") waiting"
    }

    private nonisolated static let sampleLimit = 1000

    private func toggle(_ value: Bool) {
        if value { apply(true, deleteText: false) } else { confirmOff = true }
    }

    private func apply(_ value: Bool, deleteText: Bool) {
        OCRIndexer.setIndexingEnabled(value, deleteText: deleteText)
        enabled = value
        notice = .success(value ? "OCR indexing turned on." : (deleteText ? "OCR indexing off; recognized text deleted." : "OCR indexing turned off."))
    }

    private func refreshPending() async {
        guard enabled else { pending = nil; return }
        while !Task.isCancelled && enabled {
            pending = await Task.detached { (try? ClipDatabase.shared.clipsNeedingOCR(limit: DataOCRIndexSection.sampleLimit).count) ?? 0 }.value
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}
