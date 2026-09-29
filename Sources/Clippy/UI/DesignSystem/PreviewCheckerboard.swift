import SwiftUI

/// Accessibility-labeled checkerboard that makes image transparency visible.
struct PreviewCheckerboard<Content: View>: View {
    @Environment(\.clippyTokens) private var tokens
    let tileSize: CGFloat
    let content: Content

    /// Creates an alpha-preview background around the provided image content.
    init(tileSize: CGFloat = 8, @ViewBuilder content: () -> Content) {
        self.tileSize = max(2, tileSize)
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let columns = Int(ceil(proxy.size.width / tileSize))
            let rows = Int(ceil(proxy.size.height / tileSize))
            ZStack(alignment: .topLeading) {
                tokens.surfaceInset
                ForEach(0..<rows, id: \.self) { row in
                    ForEach(0..<columns, id: \.self) { column in
                        if (row + column).isMultiple(of: 2) {
                            Rectangle()
                                .fill(tokens.textSecondary.opacity(0.13))
                                .frame(width: tileSize, height: tileSize)
                                .offset(x: CGFloat(column) * tileSize, y: CGFloat(row) * tileSize)
                        }
                    }
                }
                content
            }
            .clipped()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transparent image preview background")
    }
}
