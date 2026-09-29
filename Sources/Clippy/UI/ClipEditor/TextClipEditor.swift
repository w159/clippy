import AppKit
import Combine
import GRDB
import SwiftUI

// MARK: - Observation

/// Owns the GRDB observation of the edited clip so it lives and dies with the view.
@MainActor
final class ClipObservationHolder: ObservableObject {
    private var token: AnyDatabaseCancellable?

    func start(id: Int64?, onChange: @escaping (Clip?) -> Void) {
        guard token == nil, let id else { return }
        token = ClipEditorPersistence.live.observe(id: id, onChange: onChange)
    }
}

/// Identity of the unsaved edits, so the draft autosave task restarts on change.
struct DraftKey: Equatable {
    let text: String
    let title: String
}

/// Identity of the inputs to the status-bar counters, so they refresh on text or caret change.
struct StatusKey: Equatable {
    let text: String
    let selection: NSRange
}

// MARK: - Text editor

/// The text clip editor: title, options bar, code/rich editing surface with
/// optional preview, footer. Behavior is split across `TextClipEditor+*.swift`
/// (conflicts, AI actions, save, chrome, surface, export).
struct TextClipEditor: View {
    let clip: Clip
    let store: ClipStore
    let dirtyBridge: EditorDirtyStateBridge?
    let onClose: () -> Void

    @ObservedObject var settings = AppSettings.shared
    @Environment(\.clippyTokens) var dsTokens
    @ObservedObject var prefs = EditorPreferences.shared
    @ObservedObject var actionStore = AIActionStore.shared
    @StateObject var assistant = AIActionRunner()
    @StateObject var observation = ClipObservationHolder()
    @State var text: String
    @State var title: String
    /// Stored text the current edits started from; dirty means text != baseText.
    @State var baseText: String
    @State var baseTitle: String
    /// Stored text that arrived while the editor held unsaved edits.
    @State var conflictText: String?
    @State var showingCompare = false
    @State var clipDeleted = false
    @State var pendingEffects: [PendingEffect] = []
    @State var statusMessage: String?
    /// Shown in red in the footer when a save fails; the window stays open.
    @State var saveError: String?
    /// Cancel pressed while dirty: Save / Discard / Keep Editing.
    @State var showingDiscardPrompt = false
    /// The action awaiting an instruction (for {instruction} templates).
    @State var instructionAction: AIAction?
    // Cached stats for the footer, refreshed by a debounced task.
    @State var unicodeCount: Int
    @State var wordCount: Int
    @State var lineCount: Int
    /// Latest selection (UTF-16) reported by the code editor, and the status-bar snapshot derived from it.
    @State var selectionRange = NSRange(location: 0, length: 0)
    @State var statusSnapshot = EditorStatusMetrics.snapshot(text: "", selection: NSRange(location: 0, length: 0))

    // MARK: Language, preview, rich state

    /// User's explicit grammar choice; nil follows the sniffed one.
    @State var languageOverride: CodeLanguage?
    /// Sniffed grammar, refreshed with the debounced stats.
    @State var detectedLanguage: CodeLanguage
    /// Debounced copy of `text` that drives the preview panes and swatches.
    @State var previewText: String
    @State var colors: [ColorValue]
    /// Parsed table for the CSV preview; nil unless the grammar in effect is CSV.
    @State var csvTable: CSVTable?
    /// The clip's stored formatting (RTF, else sanitized HTML), nil for plain clips.
    let richSource: NSAttributedString?
    /// Editing with the rich `TextEditor` instead of the plain-text editor.
    @State var richMode: Bool
    @State var richText: AttributedString
    /// Rich content the edits started from; `richEdited` is `richText != baseRich`.
    @State var baseRich: AttributedString
    @State var richEdited = false
    @FocusState var richFocused: Bool

    let persistence = ClipEditorPersistence.live

    var tokens: ThemeTokens { settings.theme }

    init(clip: Clip, store: ClipStore, dirtyBridge: EditorDirtyStateBridge?, draft: EditorDraft?,
         onClose: @escaping () -> Void) {
        self.clip = clip
        self.store = store
        self.dirtyBridge = dirtyBridge
        self.onClose = onClose
        let startText = draft?.text ?? clip.contentText
        _text = State(initialValue: startText)
        _title = State(initialValue: draft?.title ?? clip.userTitle ?? "")
        _baseText = State(initialValue: draft?.baseText ?? clip.contentText)
        _baseTitle = State(initialValue: clip.userTitle ?? "")
        let stats = Self.stats(for: startText)
        _unicodeCount = State(initialValue: stats.unicode)
        _wordCount = State(initialValue: stats.words)
        _lineCount = State(initialValue: stats.lines)
        _detectedLanguage = State(initialValue: EditorLanguageSniffer.language(forText: startText))
        _previewText = State(initialValue: startText)
        _colors = State(initialValue: ColorValueParser.find(in: startText))
        _csvTable = State(initialValue: nil)
        // Rich clips open in the rich editor unless a recovered plain-text draft is restoring.
        let source = clip.isRich && draft == nil
            ? RichTextConverter.attributedString(rtf: clip.contentRTF, html: clip.contentHTML) : nil
        let previewSource = source ?? (clip.isRich
            ? RichTextConverter.attributedString(rtf: clip.contentRTF, html: clip.contentHTML) : nil)
        richSource = previewSource
        _richMode = State(initialValue: source != nil)
        let attributed = source.map(RichTextConverter.swiftUIValue(from:)) ?? AttributedString(startText)
        _richText = State(initialValue: attributed)
        _baseRich = State(initialValue: attributed)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            optionsBar
            Divider()
            if conflictText != nil {
                EditorConflictBanner(
                    onReload: { reloadFromConflict() },
                    onKeepMine: { keepMine() },
                    onCompare: { showingCompare = true }
                )
            }
            if clipDeleted { EditorDeletedBanner(onCopy: { copyEditedText() }) }
            if !colors.isEmpty && !richMode {
                ColorSwatchStrip(colors: colors)
                Divider()
            }
            editingSurface
            if !pendingEffects.isEmpty {
                EditorPendingBar(effects: pendingEffects) { effect in
                    pendingEffects.removeAll { $0.id == effect.id }
                }
            }
            statusBar
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(tokens.cardSurface)
        .task(id: StatusKey(text: text, selection: selectionRange)) {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            statusSnapshot = EditorStatusMetrics.snapshot(text: text, selection: selectionRange)
        }
        // Debounce the O(n) work (footer stats, sniffing, previews, swatches):
        // one recompute ~200ms after the last keystroke. .task(id:) cancels the
        // in-flight sleep whenever text changes.
        .task {
            // First render: build the CSV table once so the preview shows immediately.
            csvTable = language == .csv ? CSVTable.preview(text) : nil
            if richMode { richFocused = true }
        }
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            refreshDerivedState()
        }
        // Crash/quit safety net: keep a draft of unsaved edits on disk.
        .task(id: DraftKey(text: text, title: title)) {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let id = clip.id else { return }
            if let draft = currentDraft {
                EditorDraftStore.shared.save(draft)
            } else {
                EditorDraftStore.shared.remove(clipID: id)
            }
        }
        .onChange(of: languageOverride) { _, _ in refreshDerivedState() }
        .onChange(of: isDirty) { _, dirty in dirtyBridge?.onDirtyChange(dirty) }
        .onChange(of: richText) { _, newValue in
            guard richMode else { return }
            richEdited = newValue != baseRich
            let plain = String(newValue.characters)
            if plain != text { text = plain }
        }
        // Outside changes to the text (AI rewrite, reload) resync the rich value.
        .onChange(of: title) { _, _ in saveError = nil }
        .onChange(of: text) { _, newValue in
            saveError = nil
            guard richMode, String(richText.characters) != newValue else { return }
            richText = AttributedString(newValue)
        }
        .onAppear {
            // Wire the title-bar close button to the same dirty/save logic as
            // the Cancel button (see EditorWindowController.windowShouldClose).
            dirtyBridge?.isDirty = { isDirty }
            dirtyBridge?.save = { completion in completion(save()) }
            dirtyBridge?.draft = { currentDraft }
            observation.start(id: clip.id) { stored in handleStored(stored) }
        }
        .confirmationDialog(
            "Save changes to this clip?",
            isPresented: $showingDiscardPrompt
        ) {
            Button("Save") { if save() { onClose() } }
            Button("Discard Changes", role: .destructive) { onClose() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your edits will be lost if you don't save them.")
        }
        .sheet(isPresented: aiSheetBinding) {
            AIActionSheet(runner: assistant) { proposal in apply(proposal) }
        }
        .sheet(item: $instructionAction) { action in
            InstructionSheet(action: action) { instruction in
                runActionNow(action, instruction: instruction)
            }
        }
        .sheet(isPresented: $showingCompare) {
            EditorCompareSheet(
                mine: text,
                stored: conflictText ?? baseText,
                onReload: { showingCompare = false; reloadFromConflict() },
                onKeepMine: { showingCompare = false; keepMine() },
                onClose: { showingCompare = false }
            )
        }
    }

    /// Recomputes the state derived from `text`: footer counts, sniffed
    /// grammar, preview text and swatches.
    func refreshDerivedState() {
        let stats = Self.stats(for: text)
        unicodeCount = stats.unicode
        wordCount = stats.words
        lineCount = stats.lines
        detectedLanguage = EditorLanguageSniffer.language(forText: text)
        previewText = text
        colors = ColorValueParser.find(in: text)
        csvTable = (languageOverride ?? detectedLanguage) == .csv ? CSVTable.preview(text) : nil
    }
}
