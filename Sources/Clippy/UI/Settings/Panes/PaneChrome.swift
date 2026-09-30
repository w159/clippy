import SwiftUI

// Shared chrome for the redesigned Settings panes: scroll container, titled section, status notice.

/// A transient, content-free status message shown at the top of a pane.
struct PaneNotice: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let severity: BannerSeverity

    /// Success notice.
    static func success(_ message: String) -> PaneNotice { PaneNotice(message: message, severity: .success) }
    /// Failure notice; callers pass metadata only, never clip content.
    static func failure(_ message: String) -> PaneNotice { PaneNotice(message: message, severity: .danger) }
    /// Neutral informational notice.
    static func info(_ message: String) -> PaneNotice { PaneNotice(message: message, severity: .neutral) }
}

/// Scrolling pane body with a title and an optional dismissible notice.
struct PaneScroll<Content: View>: View {
    @Environment(\.clippyTokens) private var tokens
    let title: LocalizedStringKey
    @Binding var notice: PaneNotice?
    let content: Content

    /// Creates a pane container.
    init(title: LocalizedStringKey, notice: Binding<PaneNotice?>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._notice = notice
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tokens.metrics.space.five) {
                // The settings shell already renders the pane title above the pane; repeating it
                // here duplicated the heading, so the title is exposed to accessibility only.
                if let notice {
                    ClippyToast(notice.message, severity: notice.severity) { self.notice = nil }
                }
                content
            }
            .padding(tokens.metrics.space.five)
            .frame(maxWidth: SettingsPaneID.columnMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(tokens.surface)
        .accessibilityLabel(Text(title))
    }
}

/// A titled group of 44pt settings rows with an optional footer explanation.
struct PaneSection<Content: View>: View {
    @Environment(\.clippyTokens) private var tokens
    let title: LocalizedStringKey
    let footer: String?
    let content: Content

    /// Creates a section.
    init(_ title: LocalizedStringKey, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.two) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tokens.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, tokens.metrics.space.four)
                .background(tokens.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tokens.stroke.opacity(0.5), lineWidth: 0.5))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(tokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Human-readable byte count that never includes content.
enum PaneFormat {
    /// "12.4 MB" style size.
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
