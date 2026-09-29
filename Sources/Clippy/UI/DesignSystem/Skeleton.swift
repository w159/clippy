import SwiftUI

/// Animated neutral skeleton line; shimmer is suppressed under Reduce Motion.
struct Skeleton: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false
    let width: CGFloat?
    let height: CGFloat

    /// Creates a skeleton bar with optional width and standard line height.
    init(width: CGFloat? = nil, height: CGFloat = 12) {
        self.width = width
        self.height = height
    }

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(tokens.masked.opacity(shimmer && !reduceMotion ? 0.62 : 1))
                .overlay(alignment: .leading) {
                    if !reduceMotion {
                        Capsule().fill(LinearGradient(colors: [.clear, .white.opacity(0.32), .clear], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(30, proxy.size.width * 0.28))
                            .offset(x: shimmer ? proxy.size.width : -proxy.size.width * 0.3)
                    }
                }
                .clipShape(Capsule())
                .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) { shimmer = true }
        }
        .accessibilityHidden(true)
    }
}

/// Stable three-line row skeleton for loading lists.
struct SkeletonRow: View {
    let index: Int
    @Environment(\.clippyTokens) private var tokens
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(tokens.masked.opacity(0.7)).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 6) {
                Skeleton(width: CGFloat(180 - index * 17), height: 10)
                Skeleton(width: CGFloat(115 + index * 11), height: 8)
            }
            Spacer(minLength: 12)
            Skeleton(width: 40, height: 8)
        }
        .frame(height: 36)
        .accessibilityHidden(true)
    }
}
