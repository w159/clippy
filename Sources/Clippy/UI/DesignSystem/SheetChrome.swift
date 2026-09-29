import SwiftUI

/// Content-only sheet chrome; system sheet presentation supplies native glass/material.
struct ClippySheet<Content: View>: View {
    @Environment(\.clippyTokens) private var tokens
    let title: LocalizedStringKey
    let content: Content

    /// Creates a system-material sheet body with a semantic title and spacing.
    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.four) {
            Text(title).font(.title2.weight(.semibold)).foregroundStyle(tokens.textPrimary)
            content
        }
        .padding(tokens.metrics.space.five)
        .background(tokens.surface)
        .frame(minWidth: 320, minHeight: 180)
    }
}
