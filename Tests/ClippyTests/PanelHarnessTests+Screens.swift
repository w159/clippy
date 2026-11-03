import AppKit
import SwiftUI
import XCTest
@testable import Clippy

/// Capture-only coverage of every Settings pane, panel pane, editor and sheet,
/// in light and dark. Same gate as the rest of the harness (`CLIPPY_UI_HARNESS=1`,
/// enforced by `setUp`); no assertions beyond "the view could be built and shown".
extension PanelHarnessTests {
    private static let appearances: [(name: NSAppearance.Name, suffix: String)] = [(.aqua, "light"), (.darkAqua, "dark")]

    /// Seeds the store and waits for the live observation to deliver it.
    private func loadSeededStore() throws {
        store = try seededStore()
        pump(until: "clips loaded") { self.store.clips.count == 8 && !self.store.categories.isEmpty }
    }

    /// Shows `view` in a harness window, captures it and closes the window.
    private func capture<V: View>(_ name: String, _ view: V, size: NSSize, appearance: NSAppearance.Name,
                                  settle: TimeInterval = 0.8, compositedOnly: Bool = false) {
        show(view, size: size, appearance: appearance)
        pump(seconds: settle)
        screenshot(name, compositedOnly: compositedOnly)
        window.orderOut(nil)
    }

    // MARK: - Settings: every pane

    func testSettingsPaneScreenshots() throws {
        defer { unsetenv("CLIPPY_SETTINGS_SECTION") }
        for pane in SettingsPaneID.allCases {
            for (appearance, suffix) in Self.appearances {
                setenv("CLIPPY_SETTINGS_SECTION", pane.rawValue, 1)
                // cacheDisplay cannot draw the split view's sidebar material.
                capture("10-settings-\(pane.rawValue)-\(suffix)", SettingsView(),
                        size: NSSize(width: 1000, height: 700), appearance: appearance, compositedOnly: true)
            }
        }
    }

    // MARK: - Panel panes

    func testPanelPaneScreenshots() throws {
        let paneSize = NSSize(width: 620, height: 600)
        let snippetsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-harness-snippets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snippetsURL) }
        let snippetStore = SnippetStore(fileURL: snippetsURL)
        for snippet in [
            Snippet(abbreviation: ";sig", title: "Email signature", body: "Best,\nJerry\n{date}", folder: "Mail", tags: ["mail"]),
            Snippet(abbreviation: ";addr", title: "Office address", body: "100 Main Street\nKennesaw, GA", folder: "Work"),
            Snippet(abbreviation: ";id", title: "Random id", body: "{uuid}", isEnabled: false),
        ] { try snippetStore.add(snippet) }

        for (appearance, suffix) in Self.appearances {
            try loadSeededStore()
            let store = try XCTUnwrap(self.store)

            capture("20-pane-scripts-\(suffix)",
                    ScriptsPanelView(store: store, onOpenSettings: {}).clippyDesignSystem(),
                    size: paneSize, appearance: appearance)

            store.suggestions = store.clips.prefix(3).enumerated().map { index, clip in
                Suggestion(clip: clip, score: 0.9 - Double(index) * 0.2, reason: "Similar to what you are writing")
            }
            store.suggestionsState = .ready
            store.suggestionsContextSummary = "Xcode, Clippy.xcodeproj"
            capture("20-pane-suggestions-\(suffix)",
                    SuggestionsPaneHost(store: store, onOpenSettings: {}) { _ in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(store.suggestions) { suggestion in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.clip.contentText).lineLimit(2)
                                        Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                }
                            }
                            .padding(10)
                        }
                    }
                    .clippyDesignSystem(),
                    size: paneSize, appearance: appearance)

            capture("20-pane-snippets-\(suffix)", SnippetsView(store: snippetStore).clippyDesignSystem(),
                    size: paneSize, appearance: appearance)

            capture("20-pane-pastestack-\(suffix)", PasteStackTray(onPasteNext: {}).clippyDesignSystem(),
                    size: paneSize, appearance: appearance)

            capture("20-pane-assistant-\(suffix)",
                    AIAssistantPanelView(store: store, contextClip: store.clips.first, onOpenSettings: {}),
                    size: paneSize, appearance: appearance)

            capture("20-pane-aiactions-\(suffix)", AIActionsManagerView().clippyDesignSystem(),
                    size: paneSize, appearance: appearance)

            capture("20-pane-onepassword-\(suffix)", OnePasswordView().clippyDesignSystem(),
                    size: paneSize, appearance: appearance)
        }
    }

    // MARK: - Editors and sheets

    func testEditorAndSheetScreenshots() throws {
        let sheetSize = NSSize(width: 520, height: 560)
        for (appearance, suffix) in Self.appearances {
            try loadSeededStore()
            let store = try XCTUnwrap(self.store)
            // Inject persistence over the harness store's own test database so the editor never opens
            // the on-disk app database.
            let clip = try XCTUnwrap(store.clips.first)
            let persistence = ClipEditorPersistence(database: store.database)

            capture("30-editor-clip-\(suffix)",
                    ClipEditorView(clip: clip, store: store, persistence: persistence, onClose: {}),
                    size: NSSize(width: 720, height: 560), appearance: appearance)

            capture("31-sheet-category-\(suffix)",
                    CategoryEditorView(category: nil, knownBundleIDs: [], existingNames: store.categories.map(\.name),
                                       onSave: { _, _, _, _ in })
                        .clippyDesignSystem(),
                    size: sheetSize, appearance: appearance)

            capture("32-sheet-smartcollection-\(suffix)",
                    SmartCollectionEditorSheet(collection: nil, onSaved: {}).clippyDesignSystem(),
                    size: sheetSize, appearance: appearance)

            capture("33-sheet-snippet-\(suffix)",
                    SnippetEditorHarness().clippyDesignSystem(),
                    size: sheetSize, appearance: appearance)

            capture("34-sheet-aiaction-\(suffix)",
                    AIActionEditorView(action: nil, onSave: { _ in }, onCancel: {}).clippyDesignSystem(),
                    size: NSSize(width: 900, height: 600), appearance: appearance)

            capture("35-palette-\(suffix)",
                    CommandPaletteHost(commands: BuiltInCommands.all(Self.paletteContext), onDismiss: {})
                        .clippyDesignSystem(),
                    size: NSSize(width: 640, height: 480), appearance: appearance)

            capture("36-aiactions-manager-\(suffix)", AIActionsManagerView().clippyDesignSystem(),
                    size: NSSize(width: 720, height: 560), appearance: appearance)
        }
    }

    // MARK: - Empty and error states

    /// Panel list with an unseeded store (no clips yet) and with a failed search.
    func testEmptyAndErrorStateScreenshots() throws {
        let snippetsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clippy-harness-empty-snippets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: snippetsURL) }
        let emptySnippets = SnippetStore(fileURL: snippetsURL)
        let size = NSSize(width: 820, height: 600)
        for (appearance, suffix) in Self.appearances {
            let empty = ClipStore(database: try makeTestDatabase(self),
                                  pasteboard: NSPasteboard(name: NSPasteboard.Name("ClippyHarness-\(UUID())")))
            capture("40-empty-history-\(suffix)", emptyList(empty), size: size, appearance: appearance)

            // A search error only exists alongside a query: the store clears it when
            // the query is empty, so run a real search to completion first.
            empty.query = "invoice"
            pump(until: "the empty-store search to complete", { empty.completedQuery == "invoice" })
            empty.searchError = "The search index could not be read."
            capture("41-search-error-\(suffix)", emptyList(empty), size: size, appearance: appearance)

            capture("42-snippets-empty-\(suffix)", SnippetsView(store: emptySnippets).clippyDesignSystem(),
                    size: NSSize(width: 620, height: 600), appearance: appearance)
        }
    }

    private func emptyList(_ store: ClipStore) -> some View {
        ClipListView(
            store: store, onPaste: { _, _ in }, onPasteMany: { _, _, _ in }, onPasteFile: { _, _ in },
            onPrimary: { _ in }, onSendKeystrokes: { _ in }, onEdit: { _ in }, onClose: {}, onOpenSettings: {}
        ).clippyDesignSystem()
    }

    private static var paletteContext: PanelCommandContext {
        PanelCommandContext(
            hasSelectedClip: true, hasQuery: true, canExtractText: false, canFindSimilar: true, isPinned: false,
            paste: {}, pastePlain: {}, togglePin: {}, deleteSelection: {}, findSimilar: {}, openSettings: {},
            toggleSidebar: {}, currentDensity: .comfortable, setDensity: { _ in }, suggestionsEnabled: true,
            toggleSuggestions: {}, clearSearch: {}, extractText: {}, newCategory: {})
    }
}

/// Owns the binding `SnippetEditor` edits, with a populated snippet.
private struct SnippetEditorHarness: View {
    @State private var snippet = Snippet(
        abbreviation: ";sig", title: "Email signature", body: "Best,\nJerry\n{date:yyyy-MM-dd}", folder: "Mail",
        tags: ["mail", "work"], useCount: 12)

    var body: some View { SnippetEditor(snippet: $snippet) }
}
