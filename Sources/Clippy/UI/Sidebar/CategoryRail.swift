import SwiftUI

/// The 52pt icon rail: History, categories, then tools, each a
/// `SidebarRailItem` with tooltip, count in the tooltip and selection state.
struct CategoryRail: View {
    @Environment(\.clippyTokens) private var tokens
    @ObservedObject var store: ClipStore
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var scriptStore = ScriptStore.shared
    @Binding var selection: PanelSelection
    @Binding var hover: SidebarDropRow?
    let historyCount: Int
    let onDrop: (SidebarDropAction) -> Bool
    let onNewCategory: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ScrollView {
                VStack(spacing: 4) {
                    historyItem
                    divider
                    ForEach(store.categories) { category in categoryItem(category) }
                    divider
                    ForEach(SidebarTool.visible(
                        onePassword: settings.onePasswordEnabled, suggestions: settings.suggestionsEnabled, ai: settings.aiEnabled),
                        id: \.self) { tool in toolItem(tool) }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            SidebarRailItem("New Category", systemImage: "plus", action: onNewCategory)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(tokens.surfaceSidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Categories")
    }

    private var divider: some View {
        Rectangle().fill(tokens.stroke).frame(width: 24, height: 1).padding(.vertical, 2)
    }

    private var historyItem: some View {
        SidebarRailItem("History", systemImage: "clock", count: historyCount, selected: selection == .history) {
            selection = .history
        }
        .overlay { dropRing(.history) }
        .sidebarDrop(row: .history, hover: $hover, perform: onDrop)
    }

    private func categoryItem(_ category: Category) -> some View {
        let categoryID = category.id ?? -1
        let selected = selection == .category(categoryID)
        let symbol = category.iconKind == .symbol ? category.iconValue : "circle.fill"
        return SidebarRailItem(category.name, systemImage: symbol, count: store.clipCount(inCategory: categoryID), selected: selected) {
            selection = .category(categoryID)
        }
        .overlay(alignment: .topTrailing) {
            Circle().fill(Color(hexString: category.colorHex)).frame(width: 8, height: 8).padding(.top, 3).padding(.trailing, 5)
                .accessibilityHidden(true)
        }
        .overlay { dropRing(.category(categoryID)) }
        .sidebarDrop(row: .category(categoryID), hover: $hover, perform: onDrop)
    }

    private func toolItem(_ tool: SidebarTool) -> some View {
        let count: Int? = {
            switch tool {
            case .scripts: return scriptStore.scripts.count
            case .suggestions: return store.suggestions.isEmpty ? nil : store.suggestions.count
            default: return nil
            }
        }()
        return SidebarRailItem(tool.title, systemImage: tool.symbol, count: count, selected: selection == tool.selection) {
            selection = selection == tool.selection ? .history : tool.selection
        }
    }

    @ViewBuilder
    private func dropRing(_ row: SidebarDropRow) -> some View {
        if hover == row {
            RoundedRectangle(cornerRadius: tokens.metrics.radius.sm).strokeBorder(tokens.accent, lineWidth: 2).allowsHitTesting(false)
        }
    }
}
