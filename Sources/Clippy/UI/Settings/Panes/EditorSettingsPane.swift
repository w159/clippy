import SwiftUI

/// Editor settings: font size, line numbers, and code/prose behavior, with a live sample.
struct EditorSettingsPane: View {
    @Environment(\.clippyTokens) private var tokens
    @ObservedObject private var preferences = EditorPreferences.shared
    @State private var notice: PaneNotice?

    /// Creates the pane.
    init() {}

    private var effectiveSize: Double { preferences.fontSize ?? 13 }

    var body: some View {
        PaneScroll(title: "Editor", notice: $notice) {
            PaneSection("Text", footer: "Zoom also works inside the editor with Cmd+= , Cmd+- and Cmd+0.") {
                SettingsRow(title: "Follow app font size", detail: Text("Off lets you pick an editor-only size.")) {
                    Toggle("Follow app font size", isOn: followBinding).labelsHidden()
                }
                Divider()
                SettingsRow(title: "Font size", detail: Text("\(Int(effectiveSize)) pt"), enabled: preferences.fontSize != nil) {
                    Stepper("Font size", value: sizeBinding, in: EditorPreferences.minFontSize...EditorPreferences.maxFontSize, step: EditorPreferences.fontStep)
                        .labelsHidden()
                }
                Divider()
                SettingsRow(title: "Line numbers") {
                    Toggle("Line numbers", isOn: $preferences.showsLineNumbers).labelsHidden()
                }
                Divider()
                SettingsRow(title: "Show preview", detail: Text("Split preview for Markdown, CSV and rich source.")) {
                    Toggle("Show preview", isOn: $preferences.previewVisible).labelsHidden()
                }
            }
            behaviorSection(title: "Code", category: .code)
            behaviorSection(title: "Prose", category: .prose)
            PaneSection("Live sample") {
                sample.padding(.vertical, tokens.metrics.space.three)
            }
        }
    }

    private var followBinding: Binding<Bool> {
        Binding(get: { preferences.fontSize == nil },
                set: { follow in if follow { preferences.resetZoom() } else { preferences.zoomIn(from: effectiveSize - EditorPreferences.fontStep) } })
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { effectiveSize },
                set: { newValue in
                    if newValue > effectiveSize { preferences.zoomIn(from: effectiveSize) } else if newValue < effectiveSize { preferences.zoomOut(from: effectiveSize) }
                })
    }

    private func behaviorSection(title: LocalizedStringKey, category: EditorContentCategory) -> some View {
        PaneSection(title) {
            SettingsRow(title: "Word wrap") {
                Toggle("Word wrap", isOn: Binding(get: { preferences.wraps(category) }, set: { preferences.setWraps($0, for: category) })).labelsHidden()
            }
            Divider()
            SettingsRow(title: "Check spelling") {
                Toggle("Check spelling", isOn: Binding(get: { preferences.checksSpelling(category) }, set: { preferences.setChecksSpelling($0, for: category) })).labelsHidden()
            }
            Divider()
            SettingsRow(title: "Smart quotes and dashes") {
                Toggle("Smart quotes and dashes", isOn: Binding(
                    get: { preferences.usesSmartSubstitutions(category) },
                    set: { preferences.setUsesSmartSubstitutions($0, for: category) }))
                    .labelsHidden()
            }
        }
    }

    private var sample: some View {
        HStack(alignment: .top, spacing: tokens.metrics.space.four) {
            if preferences.showsLineNumbers {
                Text("1\n2\n3").font(.system(size: effectiveSize, design: .monospaced)).foregroundStyle(tokens.textTertiary)
            }
            Text("let greeting = \"Hello, Clippy\"\nprint(greeting)\n// \(preferences.wraps(.code) ? "Wraps" : "Scrolls") long lines")
                .font(.system(size: effectiveSize, design: .monospaced))
                .foregroundStyle(tokens.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Editor sample at \(Int(effectiveSize)) points")
    }
}

#Preview("Editor settings") {
    EditorSettingsPane().frame(width: 560, height: 620)
}
