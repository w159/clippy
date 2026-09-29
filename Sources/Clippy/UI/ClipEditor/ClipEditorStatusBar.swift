import SwiftUI

/// Bottom status bar of the text editor: caret, counts, encoding, language, source (EDT-06).
struct EditorStatusBarView: View {
    @Environment(\.clippyTokens) private var tokens
    let snapshot: EditorStatusSnapshot
    let languageName: String
    let wordCount: Int
    let sourceSummary: String?
    /// Hide the caret column (rich text editing has no line/column).
    var showsCaret = true

    /// Drops the least useful segments first (source, then encoding) instead of truncating in place.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showsSource: true, showsEncoding: true)
            row(showsSource: false, showsEncoding: true)
            row(showsSource: false, showsEncoding: false)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(tokens.textSecondary)
        .padding(.horizontal, tokens.metrics.space.four)
        .padding(.vertical, 4)
        .background(tokens.surfaceInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status")
        .accessibilityValue("\(showsCaret ? snapshot.spokenLabel + ", " : "")\(wordCount) words, \(languageName)")
    }

    private func row(showsSource: Bool, showsEncoding: Bool) -> some View {
        HStack(spacing: tokens.metrics.space.four) {
            if showsCaret { Text(snapshot.caretLabel) }
            Text(snapshot.characterLabel)
                .help("\(snapshot.characters) characters, \(snapshot.utf16Units) UTF-16 units, \(wordCount) words, \(snapshot.lines) lines")
            if showsEncoding { Text("UTF-8") }
            Text(languageName)
            Spacer(minLength: 0)
            if showsSource, let sourceSummary { Text(sourceSummary).lineLimit(1).truncationMode(.tail) }
        }
        .lineLimit(1)
    }
}

#Preview("Editor status bar") {
    EditorStatusBarView(
        snapshot: EditorStatusMetrics.snapshot(text: "Read from https://code.claude.com\nsecond line", selection: NSRange(location: 40, length: 0)),
        languageName: "Plain Text", wordCount: 7, sourceSummary: "Source: Edge")
        .clippyDesignSystem().frame(width: 600)
}

#Preview("Editor banners") {
    VStack(spacing: 0) {
        EditorConflictBanner(onReload: {}, onKeepMine: {}, onCompare: {})
        EditorDeletedBanner()
        EditorPendingBar(effects: [.newClip("x"), .category("claude")], onDismiss: { _ in })
    }
    .clippyDesignSystem().frame(width: 640)
}
