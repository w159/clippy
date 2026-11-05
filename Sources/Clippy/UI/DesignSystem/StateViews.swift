import SwiftUI

/// Empty-result content with a plain title, optional guidance and one action.
struct EmptyState: View {
    @Environment(\.clippyTokens) private var tokens
    let systemImage: String
    let title: String
    let message: String?
    let actionTitle: String?
    let action: (() -> Void)?

    /// Creates an empty state with an optional single primary action.
    init(systemImage: String, title: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.glass) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Stable loading indicator with an optional non-sensitive progress description.
struct LoadingState: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    let rows: Int

    /// Creates loading skeleton rows; shimmer is disabled under Reduce Motion.
    init(_ label: String = "Loading", rows: Int = 3) {
        self.label = label
        self.rows = max(1, rows)
    }

    var body: some View {
        VStack(spacing: tokens.metrics.space.two) {
            ForEach(0..<rows, id: \.self) { index in SkeletonRow(index: index) }
            ProgressView(label).controlSize(.small).padding(.top, tokens.metrics.space.two)
        }
        .padding(tokens.metrics.space.three)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Recoverable error with a plain explanation and optional retry action.
struct ErrorState: View {
    @Environment(\.clippyTokens) private var tokens
    let title: String
    let message: String
    let retryTitle: String?
    let retry: (() -> Void)?

    /// Creates an error state; diagnostic text should exclude clipboard payloads.
    init(title: String = "Something went wrong", message: String, retryTitle: String? = "Try Again", retry: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.retry = retry
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
        } actions: {
            if let retryTitle, let retry { Button(retryTitle, action: retry).buttonStyle(.glass) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
