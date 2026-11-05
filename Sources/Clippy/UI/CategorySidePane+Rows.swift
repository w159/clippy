import SwiftUI

extension CategorySidePane {
    // MARK: - Pieces

    func sectionHeader(
        _ title: String, _ section: PanelDisclosure.SidebarSection, count: Int? = nil, addLabel: String? = nil,
        onAdd: (() -> Void)? = nil
    ) -> some View {
        let open = isOpen(section)
        return HStack(spacing: 4) {
            Button { toggleSection(section) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(title)
                        .font(.footnote.weight(.semibold))
                    if let count {
                        Text("\(count)")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(tokens.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(CountCopy.sectionLabel(title: title, count: count))
            .accessibilityValue(open ? "expanded" : "collapsed")
            .accessibilityHint("Shows or hides this section.")
            if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        // The bare 10pt glyph was a ~12pt hit target.
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(addLabel ?? "Add")
                .accessibilityLabel(addLabel ?? "Add")
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    func indicator(for row: SidebarDropRow) -> SidebarDropIndicator {
        guard hoverRow == row else { return .none }
        return SidebarDropTarget.indicator(isCategoryDrag: dragState.draggingCategoryID != nil, over: row)
    }

    @ViewBuilder
    func categoryIcon(_ category: Category) -> some View {
        switch category.iconKind {
        case .symbol:
            Image(systemName: category.iconValue).font(.body.weight(.medium))
        case .emoji:
            Text(category.iconValue).font(.system(size: 13))
        case .appLogo:
            if let icon = AppIconProvider.shared.icon(forBundleID: category.iconValue) {
                Image(nsImage: icon).resizable().frame(width: 15, height: 15)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 12))
            }
        }
    }

    // MARK: - Rows

    var historyRow: some View {
        let count = historyCount ?? SidebarCounts.displayedHistoryCount(store: store)
        let activate = { focus = .history; selection = .history }
        return SidebarRow(
            rowID: .history, focus: $focus, title: "History", tint: settings.accentColor, count: count,
            isSelected: selection == .history, help: "All history (\u{2318}1)",
            accessibilityText: "History, \(CopyFormat.counted(count, "clip"))", indicator: indicator(for: .history)
        ) {
            Image(systemName: "clock").font(.body.weight(.medium))
        }
        .onTapGesture(perform: activate)
        .accessibilityAction(.default, activate)
        .sidebarDrop(row: .history, hover: $hoverRow, perform: performDrop)
    }

    func categoryRow(_ category: Category) -> some View {
        let categoryID = category.id ?? -1
        let count = SidebarCounts.displayedCategoryCount(store: store, categoryID: categoryID)
        let renaming = renamingID == categoryID
        let activate = {
            focus = .category(categoryID)
            selection = selection == .category(categoryID) ? .history : .category(categoryID)
        }
        return SidebarRow(
            rowID: .category(categoryID), focus: $focus, title: category.name, tint: Color(hexString: category.colorHex),
            count: count, isSelected: selection == .category(categoryID), help: category.name,
            accessibilityText: "\(category.name), \(CopyFormat.counted(count, "clip"))", indicator: indicator(for: .category(categoryID)),
            renameText: Binding(get: { renaming ? renameDraft : nil }, set: { renameDraft = $0 ?? ""; renameDuplicate = false }),
            renameError: renaming && renameDuplicate,
            onCommitRename: { commitRename(category) }, onCancelRename: { cancelRename() },
            onRenameFocusLost: { commitRename(category, focusLost: true) }
        ) {
            categoryIcon(category)
        }
        .onTapGesture(count: 2) { beginRename(category) }
        .onTapGesture(perform: activate)
        .accessibilityAction(.default, activate)
        .onDrag {
            dragState.begin(categoryID)
            return NSItemProvider(object: SidebarDragState.token(forCategory: categoryID) as NSString)
        }
        .sidebarDrop(row: .category(categoryID), hover: $hoverRow, perform: performDrop)
        .accessibilityRotorEntry(id: categoryID, in: rotorNamespace)
        .accessibilityAction(named: "Rename") { beginRename(category) }
        .accessibilityAction(named: "Delete") { categoryToDelete = category }
        .contextMenu {
            Button("Edit\u{2026}") { editingCategory = category }
            Button("Rename") { beginRename(category) }
            Divider()
            Button("Delete", role: .destructive) { categoryToDelete = category }
        }
        .popover(isPresented: Binding(get: { editingCategory?.id == category.id }, set: { if !$0 { editingCategory = nil } })) {
            CategoryEditorView(category: category, knownBundleIDs: store.knownBundleIDs, existingNames: store.existingCategoryNames(excluding: category)) { name, colorHex, iconKind, iconValue in
                var updated = category
                updated.name = name
                updated.colorHex = colorHex
                updated.iconKind = iconKind
                updated.iconValue = iconValue
                store.updateCategory(updated)
            }
        }
    }

    func toolRow(_ tool: SidebarTool) -> some View {
        var count: Int?
        if tool == .scripts { count = scriptStore.scripts.count }
        if tool == .suggestions, !store.suggestions.isEmpty { count = store.suggestions.count }
        if tool == .pasteStack, PasteStack.shared.count > 0 { count = PasteStack.shared.count }
        let activate = { focus = tool.rowID; selection = selection == tool.selection ? .history : tool.selection }
        return SidebarRow(
            rowID: tool.rowID, focus: $focus, title: tool.title, tint: tool.tint, count: count,
            isSelected: selection == tool.selection, help: tool.help, accessibilityText: tool.accessibilityText
        ) {
            Image(systemName: tool.symbol).font(.body.weight(.medium))
        }
        .onTapGesture(perform: activate)
        .accessibilityAction(.default, activate)
    }

    var newCategoryRow: some View {
        SidebarRow(
            rowID: .newCategory, focus: $focus, title: "New Category", tint: tokens.textSecondary, count: nil,
            isSelected: false, help: "Create a category", accessibilityText: "New Category"
        ) {
            Image(systemName: "plus").font(.body.weight(.medium))
        }
        .onTapGesture { isCreating = true }
        .accessibilityAction(.default) { isCreating = true }
    }

    /// Zone after the last category: dropping a dragged category here moves it to the end.
    var trailingDropZone: some View {
        Rectangle().fill(.clear).frame(maxWidth: .infinity).frame(height: 10).contentShape(Rectangle())
            .overlay(alignment: .top) {
                if indicator(for: .trailing) == .reorderLine { Rectangle().fill(tokens.accent).frame(height: 2).padding(.horizontal, 4) }
            }
            .sidebarDrop(row: .trailing, hover: $hoverRow, perform: performDrop)
            .accessibilityHidden(true)
    }
}
