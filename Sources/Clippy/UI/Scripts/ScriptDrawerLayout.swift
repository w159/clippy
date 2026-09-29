import AppKit
import SwiftUI

/// Editor above, drag handle, output drawer below. One region per scroller: the
/// code editor and the output text each own their AppKit scroller, and this
/// container never scrolls. The drawer height is clamped by `OutputDrawerMetrics`
/// and persisted when a drag ends.
struct ScriptDrawerLayout<Editor: View, Drawer: View>: View {
    @Environment(\.clippyTokens) private var tokens
    @State private var height = OutputDrawerMetrics.stored()
    @State private var dragStart: CGFloat?
    let showsDrawer: Bool
    let editor: Editor
    let drawer: Drawer

    init(showsDrawer: Bool, @ViewBuilder editor: () -> Editor, @ViewBuilder drawer: () -> Drawer) {
        self.showsDrawer = showsDrawer
        self.editor = editor()
        self.drawer = drawer()
    }

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.height
            let drawerHeight = OutputDrawerMetrics.clamp(height, available: available)
            VStack(spacing: 0) {
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsDrawer {
                    handle(available: available, current: drawerHeight)
                    drawer.frame(height: drawerHeight)
                }
            }
        }
    }

    private func handle(available: CGFloat, current: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(tokens.stroke).frame(height: 1)
            Capsule().fill(tokens.strokeStrong).frame(width: 36, height: 4)
        }
        .frame(height: 10)
        .frame(maxWidth: .infinity)
        .background(tokens.surfaceInset)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? current
                dragStart = start
                height = OutputDrawerMetrics.height(start: start, translation: value.translation.height, available: available)
            }
            .onEnded { _ in
                dragStart = nil
                OutputDrawerMetrics.store(height)
            })
        .onTapGesture(count: 2) {
            height = OutputDrawerMetrics.defaultHeight
            OutputDrawerMetrics.store(height)
        }
        .focusable()
        .accessibilityElement()
        .accessibilityLabel("Resize output drawer")
        .accessibilityValue("\(Int(current)) points tall")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = direction == .increment ? 24 : -24
            height = OutputDrawerMetrics.clamp(current + step, available: available)
            OutputDrawerMetrics.store(height)
        }
        .help("Drag to resize the output drawer. Double-click to reset.")
    }
}


#Preview("Script output drawer") {
    ScriptDrawerLayout(showsDrawer: true) {
        Text("Editor area").frame(maxWidth: .infinity, maxHeight: .infinity)
    } drawer: {
        Text("Run output").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(width: 800, height: 520)
    .clippyDesignSystem()
}
