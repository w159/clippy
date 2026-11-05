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

/// Pane body: a grouped Form with an optional dismissible notice as its first section.
struct PaneScroll<Content: View>: View {
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
        // The settings shell shows the pane title in the window toolbar; the title here is for accessibility only.
        Form {
            if let notice {
                Section {
                    ClippyToast(notice.message, severity: notice.severity, dismiss: { self.notice = nil })
                }
            }
            content
        }
        .formStyle(.grouped)
        .accessibilityLabel(Text(title))
    }
}

/// A titled Form section with an optional footer explanation.
struct PaneSection<Content: View>: View {
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
        Section {
            content
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
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
