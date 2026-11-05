import SwiftUI
import AppKit

// Pane routing for `ClipListView`: the main pane (list with status overlay), the History/category/tool pane switch and the
// slide transition between panes.

extension ClipListView {
    // MARK: - Main pane

    var mainPane: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                if selection == .history {
                    paneContent
                        .transition(paneTransition(edge: .leading))
                } else {
                    paneContent
                        .id(selection)
                        .transition(paneTransition(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(ClippyMotion.animation(.standard, reduce: reduceMotion), value: selection)
            .clipped()

            PanelStatusOverlay(item: statusItem, action: statusRetry, dismiss: { dismissStatus() })
        }
    }

    func paneTransition(edge: Edge) -> AnyTransition {
        .move(edge: edge).combined(with: .opacity)
    }

    @ViewBuilder
    var paneContent: some View {
        if selection == .scripts {
            ScriptsPanelView(store: store, onOpenSettings: onOpenSettings)
        } else if selection == .onePassword {
            OnePasswordView()
        } else if selection == .assistant {
            AIAssistantPanelView(store: store, contextClip: assistantContextClip, onOpenSettings: onOpenSettings)
        } else if selection == .aiActions {
            AIActionsManagerView()
        } else if selection == .suggestions {
            suggestionsPane
        } else if selection == .snippets {
            SnippetsView()
        } else if selection == .pasteStack {
            PasteStackTray(onPasteNext: { PasteStackController.shared.pasteNext() })
        } else if visibleClips.isEmpty {
            // A calm opaque card: empty-state text sits on a solid surface, not on the panel material.
            emptyState
                .background(tokens.surfaceElevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        } else {
            sectionedList
        }
    }
}
