import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Snippet manager: folder filter, list and editor, with import/export and duplicate.
struct SnippetsView: View {
    @Environment(\.clippyTokens) private var tokens
    @FocusState private var searchFocused: Bool
    private let store: SnippetStore
    @State private var snippets: [Snippet] = []
    @State private var selection: UUID?
    @State private var folderFilter = ""
    @State private var query = ""
    @State private var errorMessage: String?
    @State private var confirmDelete = false
    @State private var pendingSave: Snippet?
    @State private var saveTask: Task<Void, Never>?

    /// Creates the manager over `store`.
    init(store: SnippetStore = .shared) { self.store = store }

    private var visible: [Snippet] {
        snippets.filter { item in
            (folderFilter.isEmpty || item.folder == folderFilter)
                && (query.isEmpty || [item.title, item.abbreviation, item.body].contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: tokens.metrics.space.two) {
                TextField("Search snippets", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
                Picker("Folder", selection: $folderFilter) {
                    Text("All folders").tag("")
                    ForEach(store.folders, id: \.self) { Text($0).tag($0) }
                }
                List(visible, selection: $selection) { item in
                    VStack(alignment: .leading) {
                        Text(item.displayName).foregroundStyle(item.isEnabled ? tokens.textPrimary : tokens.textSecondary)
                        if !item.abbreviation.isEmpty { Text(item.abbreviation).font(.caption.monospaced()).foregroundStyle(tokens.textSecondary) }
                    }.tag(item.id)
                }
                .onDeleteCommand { if selection != nil { confirmDelete = true } }
                .overlay {
                    if visible.isEmpty {
                        Text(snippets.isEmpty ? "No snippets yet. Press + to add one." : "No snippets match.")
                            .font(.callout).foregroundStyle(tokens.textSecondary).multilineTextAlignment(.center).padding(tokens.metrics.space.three)
                    }
                }
                toolbar
            }
            .frame(minWidth: 220, idealWidth: 260)
            editor.frame(minWidth: 340)
        }
        .onAppear { reload(); searchFocused = true }
        .onDisappear { flushSave() }
        .confirmationDialog("Delete this snippet?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = selection { perform { try store.delete(id: id); selection = nil } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This can't be undone.") }
        .alert("Snippets", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var toolbar: some View {
        HStack(spacing: tokens.metrics.space.two) {
            Button { perform { let item = Snippet(title: "New snippet"); try store.add(item); selection = item.id } } label: {
                Image(systemName: "plus")
            }.accessibilityLabel("New snippet").help("New snippet")
            Button { if let id = selection { perform { selection = try store.duplicate(id: id)?.id } } } label: {
                Image(systemName: "plus.square.on.square")
            }.accessibilityLabel("Duplicate").help("Duplicate snippet").disabled(selection == nil)
            Button { confirmDelete = true } label: {
                Image(systemName: "trash")
            }.accessibilityLabel("Delete").help("Delete snippet").disabled(selection == nil)
            Spacer()
            Button("Import…", action: importJSON)
            Button("Export…", action: exportJSON)
        }
    }

    @ViewBuilder private var editor: some View {
        if let id = selection, let current = snippets.first(where: { $0.id == id }) {
            SnippetEditor(snippet: Binding(
                get: { snippets.first { $0.id == id } ?? current },
                set: { value in
                    guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
                    snippets[index] = value
                    scheduleSave(value)
                }))
        } else {
            Text("Select a snippet, or press + to create one.").foregroundStyle(tokens.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reload() {
        snippets = store.snippets
        if let selection, !snippets.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    private func save(_ snippet: Snippet) { perform(reloadAfter: false) { try store.update(snippet) } }

    /// Coalesces per-keystroke edits so the store and expander are hit once per pause.
    private func scheduleSave(_ snippet: Snippet) {
        pendingSave = snippet
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            flushSave()
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        guard let snippet = pendingSave else { return }
        pendingSave = nil
        save(snippet)
    }

    private func perform(reloadAfter: Bool = true, _ work: () throws -> Void) {
        if reloadAfter, pendingSave != nil { flushSave() }
        do { try work() } catch { errorMessage = error.localizedDescription }
        if reloadAfter { reload() }
        SnippetExpander.shared.reloadSnippets()
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "clippy-snippets.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(reloadAfter: false) { try store.exportJSON().write(to: url, options: .atomic) }
    }

    private func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { _ = try store.importJSON(Data(contentsOf: url)) }
    }
}

/// Editor for one snippet with a placeholder menu and live test expansion.
struct SnippetEditor: View {
    @Binding var snippet: Snippet
    @Environment(\.clippyTokens) private var tokens

    private static let placeholders: [(String, String)] = [
        ("Date", "{date}"), ("Date (custom)", "{date:yyyy-MM-dd}"), ("Time", "{time}"), ("Clipboard", "{clipboard}"),
        ("Cursor position", "{cursor}"), ("Fill-in field", "{fill:Name}"), ("UUID", "{uuid}"), ("Random digits", "{random:6}")
    ]

    var body: some View {
        Form {
            TextField("Title", text: $snippet.title)
            TextField("Abbreviation (e.g. ;sig)", text: $snippet.abbreviation)
            TextField("Folder", text: $snippet.folder)
            TextField("Tags (comma separated)", text: Binding(
                get: { snippet.tags.joined(separator: ", ") },
                set: { snippet.tags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
            Toggle("Enabled", isOn: $snippet.isEnabled)
            HStack(spacing: tokens.metrics.space.two) {
                Text("Body").font(.headline)
                Spacer()
                Menu("Insert placeholder") {
                    ForEach(Self.placeholders, id: \.1) { item in Button(item.0) { snippet.body += item.1 } }
                }
            }
            TextEditor(text: $snippet.body).font(.system(.body, design: .monospaced)).frame(minHeight: 120)
            Text("Test expansion").font(.headline)
            Text(preview).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Used \(snippet.useCount) times. Snippets stay on this Mac.").font(.caption).foregroundStyle(tokens.textSecondary)
        }
        .formStyle(.grouped)
    }

    private var preview: String {
        var context = SnippetContext()
        context.clipboard = "‹clipboard›"
        let labels = SnippetTemplate.fillFields(in: snippet.body)
        context.fillValues = Dictionary(uniqueKeysWithValues: labels.map { ($0, "‹\($0)›") })
        let result = SnippetTemplate.expand(snippet.body, context: context)
        guard let offset = result.cursorOffsetFromEnd else { return result.text }
        return String(result.text.dropLast(offset)) + "▮" + String(result.text.suffix(offset))
    }
}
