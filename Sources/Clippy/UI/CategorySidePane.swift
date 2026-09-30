import SwiftUI

/// The category sidebar. Expanded it shows Library / Categories / Tools groups;
/// with `isRail` it renders the 52pt `CategoryRail`. Category rows accept clip
/// drops (file) and category drops (reorder), rename inline, and are keyboard
/// operable. Row views live in `CategorySidePane+Rows`, behavior in `+Actions`.
struct CategorySidePane: View {
    @ObservedObject var store: ClipStore
    @Binding var selection: PanelSelection
    /// Render the icon rail instead of the expanded list.
    var isRail: Bool
    /// History badge count; nil derives it from the store (unpinned clips, as displayed).
    var historyCount: Int?
    /// Smart collections model; nil hides the section.
    var smartCollections: SmartCollectionSelection?

    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var scriptStore = ScriptStore.shared
    @StateObject var dragState = SidebarDragState()
    @StateObject var undo: CategoryUndo
    @Environment(\.clippyTokens) var tokens
    @Environment(\.undoManager) var undoManager
    @FocusState var focus: SidebarRowID?
    @Namespace var rotorNamespace
    /// Category whose editor popover is open.
    @State var editingCategory: Category?
    @State var isCreating = false
    /// Category pending deletion (confirmation alert).
    @State var categoryToDelete: Category?
    /// Row currently under a drag, for drop indicators.
    @State var hoverRow: SidebarDropRow?
    /// Category being renamed inline, its draft text and duplicate-name flag.
    @State var renamingID: Int64?
    @State var renameDraft = ""
    @State var renameDuplicate = false
    /// Persisted open sidebar sections (`PanelDisclosure.encode`).
    @AppStorage("sidebar.expandedSections") var expandedRaw = PanelDisclosure.encode(PanelDisclosure.defaultExpanded)

    /// Legacy hook kept for external callers; the AI Actions row drives `selection` directly.
    var onNavigateAIActions: () -> Void = {}

    /// Source-compatible initializer: `isRail` and `historyCount` are optional.
    init(store: ClipStore, selection: Binding<PanelSelection>, isRail: Bool = false, historyCount: Int? = nil,
         smartCollections: SmartCollectionSelection? = nil) {
        self.store = store
        self._selection = selection
        self.isRail = isRail
        self.historyCount = historyCount
        self.smartCollections = smartCollections
        self._undo = StateObject(wrappedValue: CategoryUndo(backend: ClipStoreCategoryBackend(store: store)))
    }

    var body: some View {
        Group {
            if isRail { rail } else { expanded }
        }
        .popover(isPresented: $isCreating) {
            CategoryEditorView(category: nil, knownBundleIDs: store.knownBundleIDs, existingNames: store.existingCategoryNames()) { name, colorHex, iconKind, iconValue in
                store.createCategory(named: name, colorHex: colorHex, iconKind: iconKind, iconValue: iconValue)
            }
        }
        .alert("Delete \"\(categoryToDelete?.name ?? "")\"?", isPresented: Binding(get: { categoryToDelete != nil }, set: { if !$0 { categoryToDelete = nil } })) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { categoryToDelete = nil }
        } message: {
            Text("Clips in this category will be unfiled. You can undo this with \u{2318}Z.")
        }
        .onAppear { undo.undoManager = undoManager }
    }

    private var rail: some View {
        CategoryRail(
            store: store, selection: $selection, hover: $hoverRow,
            historyCount: historyCount ?? SidebarCounts.displayedHistoryCount(store: store),
            onDrop: performDrop, onNewCategory: { isCreating = true })
    }

    /// Sections open by user choice; the section holding the selection is always open.
    func isOpen(_ section: PanelDisclosure.SidebarSection) -> Bool {
        let holdsSelection: Bool
        switch (section, selection) {
        case (.library, .history), (.categories, .category): holdsSelection = true
        case (.tools, .history), (.tools, .category): holdsSelection = false
        case (.tools, _): holdsSelection = true
        default: holdsSelection = false
        }
        return PanelDisclosure.isExpanded(section, stored: PanelDisclosure.decode(expandedRaw), containsSelection: holdsSelection)
    }

    func toggleSection(_ section: PanelDisclosure.SidebarSection) {
        var stored = PanelDisclosure.decode(expandedRaw)
        if stored.contains(section) { stored.remove(section) } else { stored.insert(section) }
        expandedRaw = PanelDisclosure.encode(stored)
    }

    private var visibleTools: [SidebarTool] {
        SidebarTool.visible(onePassword: settings.onePasswordEnabled, suggestions: settings.suggestionsEnabled, ai: settings.aiEnabled)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Library", .library)
                    if isOpen(.library) { historyRow }
                    sectionHeader("Categories", .categories, count: store.categories.count, addLabel: "New category") { isCreating = true }
                    if isOpen(.categories) {
                        ForEach(store.categories) { category in categoryRow(category) }
                        trailingDropZone
                    }
                    if let smartCollections {
                        sectionHeader("Smart collections", .smartCollections)
                        if isOpen(.smartCollections) {
                            SmartCollectionsSidebarSection(selection: smartCollections, showsTitle: false).padding(.horizontal, 6)
                        }
                    }
                    sectionHeader("Tools", .tools, count: visibleTools.count)
                    if isOpen(.tools) {
                        ForEach(visibleTools, id: \.self) { tool in
                            toolRow(tool)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
            }
            .accessibilityRotor("Categories") {
                ForEach(store.categories) { category in
                    AccessibilityRotorEntry(Text(category.name), id: category.id ?? -1, in: rotorNamespace)
                }
            }
            newCategoryRow.padding(.horizontal, 6).padding(.bottom, 6)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(tokens.surfaceSidebar.opacity(settings.panelOpacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Categories")
        .onKeyPress(phases: .down) { press in handleKey(press) }
    }
}
