import SwiftUI

/// Smart collections manager: list, create, edit and delete rule-based collections.
struct DataSmartCollectionsSection: View {
    @Binding var notice: PaneNotice?
    @State private var collections: [SmartCollection] = []
    @State private var loadFailed = false
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
            if collections.isEmpty && !loadFailed {
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

    private func reload() {
        do {
            collections = try ClipDatabase.shared.smartCollections()
            loadFailed = false
        } catch {
            loadFailed = true
            notice = .failure("Could not load smart collections.")
        }
    }

    private func deleteSelected() {
        guard let collectionID = deleting?.id else { return }
        do { try ClipDatabase.shared.deleteSmartCollection(id: collectionID); reload() } catch { notice = .failure("Could not delete the collection.") }
        deleting = nil
    }
}

/// Create/edit sheet for one smart collection.
struct SmartCollectionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.clippyTokens) private var tokens
    let collection: SmartCollection?
    let onSaved: () -> Void
    @State private var draft = SmartCollectionDraft()
    @State private var errorText: String?

    var body: some View {
        ClippySheet(title: collection == nil ? "New smart collection" : "Edit smart collection") {
            VStack(alignment: .leading, spacing: tokens.metrics.space.three) {
                field("Name") { TextField("", text: $draft.name).labelsHidden() }
                field("Clip types") {
                    SmartCollectionFlowLayout(spacing: tokens.metrics.space.two) {
                        ForEach(ClipKindToken.allCases, id: \.self) { token in
                            Toggle(token.rawValue.capitalized, isOn: Binding(
                                get: { draft.kinds.contains(token) },
                                set: { if $0 { draft.kinds.insert(token) } else { draft.kinds.remove(token) } }))
                                .toggleStyle(AccentToggleStyle()).toggleStyle(.checkbox)
                        }
                    }
                }
                field("Source app bundle id") { TextField("", text: $draft.sourceApp).labelsHidden() }
                field("Text pattern (regular expression)") { TextField("", text: $draft.textPattern).labelsHidden() }
                HStack(alignment: .top, spacing: tokens.metrics.space.three) {
                    field("Older than (days)") { TextField("", text: $draft.olderThanDays).labelsHidden() }
                    field("Newer than (days)") { TextField("", text: $draft.newerThanDays).labelsHidden() }
                }
                field("Sensitive") {
                    Picker("", selection: $draft.sensitive) {
                        Text("Either").tag(Bool?.none)
                        Text("Only sensitive").tag(Bool?.some(true))
                        Text("Not sensitive").tag(Bool?.some(false))
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(tokens.danger) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(.accent).keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 520)
        .onAppear { if let collection { draft = SmartCollectionDraft(collection: collection) } }
    }

    /// Label-above-control row so long labels are never clipped by a trailing column.
    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
            Text(title).font(.caption).foregroundStyle(tokens.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Left-to-right layout that wraps children onto new lines when they exceed the proposed width.
private struct SmartCollectionFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
