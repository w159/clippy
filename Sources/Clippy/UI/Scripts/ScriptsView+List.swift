import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension ScriptsView {
    // MARK: - List pane

    var listPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("\(store.scripts.count) scripts")
                    .font(.caption)
                    .foregroundStyle(tokens.textSecondary)
                Spacer()
                Button { showBadgeLegend.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain)
                    .help("What the badges mean")
                    .accessibilityLabel("Badge legend")
                    .popover(isPresented: $showBadgeLegend, arrowEdge: .bottom) { ScriptBadgeLegendView().padding() }
                Button { requestNew() } label: { Image(systemName: "plus") }
                    .help("New script")
                Menu {
                    Button("Import Scripts...") { importScripts() }
                    Button("Export Selected...") { exportScripts() }
                        .disabled(editing == nil && selection.isEmpty)
                    Divider()
                    Toggle("Keep run history on disk (no output)", isOn: Binding(
                        get: { store.persistHistory }, set: { store.persistHistory = $0 }))
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Import, export and history options")
            }
            .padding(10)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.textSecondary)
                TextField("Search names and bodies", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if let quarantine = store.quarantineNotice {
                bannerRow(quarantine, icon: "exclamationmark.triangle", dismiss: { store.quarantineNotice = nil })
            }
            if let notice {
                bannerRow(notice, icon: "info.circle", dismiss: { self.notice = nil })
            }
            scriptRows
            if selection.count > 1 { batchBar }
        }
        .background(tokens.sidebar)
    }

    /// Narrow layout: a script picker plus new/legend/menu actions in one row.
    var compactListBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(store.scripts) { script in
                    Button { click(script.id) } label: {
                        if editing?.id == script.id { Label(displayName(script.name), systemImage: "checkmark") }
                        else { Text(displayName(script.name)) }
                    }
                }
                if store.scripts.isEmpty { Text("No scripts yet") }
            } label: {
                Text(editing.map { displayName($0.name) } ?? "Choose script")
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { requestNew() } label: { Image(systemName: "plus") }
                .help("New script")
            Menu {
                Button("Import Scripts...") { importScripts() }
                Button("Export Selected...") { exportScripts() }
                    .disabled(editing == nil && selection.isEmpty)
                Divider()
                Toggle("Keep run history on disk (no output)", isOn: Binding(
                    get: { store.persistHistory }, set: { store.persistHistory = $0 }))
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(tokens.sidebar)
    }

    func bannerRow(_ text: String, icon: String, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(tokens.textSecondary)
        .padding(8)
    }

    var scriptRows: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if filteredScripts.isEmpty && !isDraft {
                    Text(searchQuery.isEmpty ? "No scripts yet. Click + to create one." : "No scripts match")
                        .font(.caption)
                        .foregroundStyle(tokens.textSecondary)
                        .padding(.vertical, 16)
                }
                ForEach(filteredScripts) { script in row(for: script) }
                // The unsaved draft sits where Save will put it: at the end of the
                // list. On Save the row is replaced in place by the stored script.
                if isDraft, let editing { draftRow(editing) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    func rowBackground(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(selected ? tokens.cardSurface : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? tokens.cardBorder : Color.clear, lineWidth: 1))
    }

    func row(for script: Script) -> some View {
        let selected = selection.contains(script.id)
        let open = editing?.id == script.id
        let bodyOnly = !searchQuery.isEmpty
            && script.name.range(of: searchQuery, options: [.caseInsensitive, .diacriticInsensitive]) == nil
        return Button { click(script.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9))
                    .foregroundStyle(tokens.textSecondary)
                    .reorderDraggable(id: script.id.uuidString)
                    .help("Drag to reorder")
                if center.isRunning(script.id) { ProgressView().controlSize(.mini) }
                Text(displayName(script.name))
                    .font(.body)
                    .foregroundStyle(open ? Color.accentColor : tokens.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if bodyOnly { Text("in body").font(.caption2).foregroundStyle(tokens.textSecondary) }
                ForEach(ScriptBadge.allCases.filter { $0.applies(to: script) }, id: \.title) { badge in
                    Image(systemName: badge.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(tokens.textSecondary)
                        .help("\(badge.title). \(badge.detail)")
                }
                Text(script.interpreter.displayName)
                    .font(.caption2)
                    .foregroundStyle(tokens.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(rowBackground(selected: selected || open))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .reorderDropDestination(id: script.id.uuidString, draggingOver: $draggingOverScriptID) { dragged, target in
            if let from = UUID(uuidString: dragged), let to = UUID(uuidString: target) {
                store.moveScript(draggedID: from, before: to)
            }
        }
    }

    func draftRow(_ draft: Script) -> some View {
        HStack {
            Text(draft.name.isEmpty ? "New script" : draft.name)
                .font(.body.italic())
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
            Spacer()
            Text("unsaved").font(.caption2).foregroundStyle(tokens.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(rowBackground(selected: true))
    }

    var batchBar: some View {
        HStack(spacing: 8) {
            if let progress = center.batchProgress {
                ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                    .frame(maxWidth: .infinity)
                Button("Stop") { center.cancelBatch() }.controlSize(.small)
            } else {
                Text("\(selection.count) selected").font(.caption).foregroundStyle(tokens.textSecondary)
                Button("Select all") { batchSelection.selectAll(filteredScripts.map(\.id)) }
                    .controlSize(.small)
                Button("Clear") { batchSelection.clear() }
                    .controlSize(.small)
                Button("Run Selected") { activeDialog = .batch }
                    .controlSize(.small)
                    .disabled(selectedScripts.isEmpty)
            }
        }
        .padding(8)
        .background(tokens.headerBar)
    }
}
