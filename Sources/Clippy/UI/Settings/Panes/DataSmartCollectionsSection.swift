import SwiftUI

/// Smart collections manager: list, create, edit and delete rule-based collections.
struct DataSmartCollectionsSection: View {
    @Binding var notice: PaneNotice?
    @State private var collections: [SmartCollection] = []
    @State private var editing: EditTarget?
    @State private var deleting: SmartCollection?

    /// Sheet target: a new collection or an existing one.
    struct EditTarget: Identifiable {
        let id = UUID()
        var collection: SmartCollection?
    }

    /// Creates the section.
    init(notice: Binding<PaneNotice?>) { self._notice = notice }

    var body: some View {
        PaneSection("Smart collections", footer: "Rules that group clips automatically by type, source app, text pattern, age or sensitivity.") {
            if collections.isEmpty {
                SettingsRow(title: "No smart collections") { EmptyView() }
                Divider()
            }
            ForEach(collections) { collection in
                SettingsRow(title: LocalizedStringKey(collection.name), detail: Text(SmartCollectionDraft.summary(of: collection.rule))) {
                    HStack {
                        Button("Edit") { editing = EditTarget(collection: collection) }
                        Button("Delete\u{2026}") { deleting = collection }
                    }
                }
                Divider()
            }
            SettingsRow(title: "New smart collection") {
                Button("New\u{2026}") { editing = EditTarget(collection: nil) }
            }
        }
        .onAppear(perform: reload)
        .sheet(item: $editing) { target in
            SmartCollectionEditorSheet(collection: target.collection) { reload(); notice = .success("Smart collection saved.") }
        }
        .confirmationDialog("Delete this smart collection?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: {
            Text("Only the rule is deleted. The clips stay in your history.")
        }
    }

    private func reload() { collections = (try? ClipDatabase.shared.smartCollections()) ?? [] }

    private func deleteSelected() {
        guard let collectionID = deleting?.id else { return }
        do { try ClipDatabase.shared.deleteSmartCollection(id: collectionID); reload() } catch { notice = .failure("Could not delete the collection.") }
        deleting = nil
    }
}

/// Create/edit sheet for one smart collection.
struct SmartCollectionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let collection: SmartCollection?
    let onSaved: () -> Void
    @State private var draft = SmartCollectionDraft()
    @State private var errorText: String?

    var body: some View {
        ClippySheet(title: collection == nil ? "New smart collection" : "Edit smart collection") {
            Form {
                TextField("Name", text: $draft.name)
                HStack {
                    ForEach(ClipKindToken.allCases, id: \.self) { token in
                        Toggle(token.rawValue.capitalized, isOn: Binding(
                            get: { draft.kinds.contains(token) },
                            set: { if $0 { draft.kinds.insert(token) } else { draft.kinds.remove(token) } }))
                            .toggleStyle(.checkbox)
                    }
                }
                TextField("Source app bundle id", text: $draft.sourceApp)
                TextField("Text pattern (regular expression)", text: $draft.textPattern)
                TextField("Older than (days)", text: $draft.olderThanDays)
                TextField("Newer than (days)", text: $draft.newerThanDays)
                Picker("Sensitive", selection: $draft.sensitive) {
                    Text("Either").tag(Bool?.none)
                    Text("Only sensitive").tag(Bool?.some(true))
                    Text("Not sensitive").tag(Bool?.some(false))
                }
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 460)
        .onAppear { if let collection { draft = SmartCollectionDraft(collection: collection) } }
    }

    private func save() {
        do {
            let rule = try draft.makeRule()
            if let collectionID = collection?.id {
                try ClipDatabase.shared.updateSmartCollection(id: collectionID, name: draft.name, rule: rule)
            } else {
                _ = try ClipDatabase.shared.createSmartCollection(name: draft.name, rule: rule)
            }
            onSaved()
            dismiss()
        } catch {
            errorText = SmartCollectionDraft.message(for: error)
        }
    }
}
