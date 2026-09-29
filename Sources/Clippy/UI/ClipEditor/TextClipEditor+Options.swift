import AppKit
import SwiftUI

// Options bar: language, wrap, line numbers, zoom, proofing, preview, rich toggle, export.
extension TextClipEditor {
    var optionsBar: some View {
        HStack(spacing: 4) {
            if richSource != nil {
                Toggle("Rich text", isOn: Binding(get: { richMode }, set: { setRichMode($0) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Edit with formatting. Off edits as plain text; saving then removes the formatting.")
            }
            languageMenu.disabled(richMode)
            IconButton("magnifyingglass", label: "Find", help: "Find (Cmd F)") { showFindBar() }
                .disabled(richMode)
            toolbarToggle("text.word.spacing", "Word wrap", isOn: prefs.wraps(category), disabled: richMode) {
                prefs.setWraps(!prefs.wraps(category), for: category)
            }
            toolbarToggle("list.number", "Line numbers", isOn: prefs.showsLineNumbers, disabled: richMode) {
                prefs.showsLineNumbers.toggle()
            }
            toolbarToggle("textformat.abc", "Spell check", isOn: prefs.checksSpelling(category), disabled: richMode) {
                prefs.setChecksSpelling(!prefs.checksSpelling(category), for: category)
            }
            toolbarToggle("quote.opening", "Smart quotes, dashes and text replacement",
                          isOn: prefs.usesSmartSubstitutions(category), disabled: richMode) {
                prefs.setUsesSmartSubstitutions(!prefs.usesSmartSubstitutions(category), for: category)
            }
            Divider().frame(height: 14)
            IconButton("textformat.size.smaller", label: "Smaller text", help: "Smaller text (Cmd -)",
                       state: richMode ? .disabled : .rest) { prefs.zoomOut(from: effectiveFontSize) }
            IconButton("textformat.size.larger", label: "Larger text", help: "Larger text (Cmd =)",
                       state: richMode ? .disabled : .rest) { prefs.zoomIn(from: effectiveFontSize) }
            if previewKind != nil {
                toolbarToggle("rectangle.split.2x1", "Show preview", isOn: prefs.previewVisible, disabled: false) {
                    prefs.previewVisible.toggle()
                }
            }
            Spacer()
            exportMenu
            zoomShortcuts
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(dsTokens.surfaceElevated)
    }

    /// Compact toggle icon with a selected state, tooltip and VoiceOver on/off value.
    func toolbarToggle(_ image: String, _ label: String, isOn: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        IconButton(image, label: label, help: label, state: disabled ? .disabled : (isOn ? .selected : .rest), action: action)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(.isToggle)
    }

    /// Opens the text view's native find bar (first responder is the editor).
    func showFindBar() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
    }

    var languageMenu: some View {
        Menu {
            Picker("Syntax", selection: Binding(get: { languageOverride }, set: { languageOverride = $0 })) {
                Text("Auto (\(detectedLanguage.displayName))").tag(CodeLanguage?.none)
                ForEach(CodeLanguage.allCases) { language in
                    Text(language.displayName).tag(CodeLanguage?.some(language))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(language.displayName, systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Syntax: \(language.displayName)")
    }

    var exportMenu: some View {
        Menu {
            ForEach(EditorExportFormat.allCases) { format in
                Button("Save As \(format.label)…") { export(format) }
            }
            Divider()
            ShareLink(item: text) { Label("Share…", systemImage: "square.and.arrow.up") }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Cmd+= / Cmd+- / Cmd+0. Hidden buttons: the window resolves the key
    /// equivalents whichever view has focus.
    var zoomShortcuts: some View {
        Group {
            Button("") { prefs.zoomIn(from: effectiveFontSize) }.keyboardShortcut("=", modifiers: .command)
            Button("") { prefs.zoomOut(from: effectiveFontSize) }.keyboardShortcut("-", modifiers: .command)
            Button("") { prefs.resetZoom() }.keyboardShortcut("0", modifiers: .command)
        }
        .hidden()
        .frame(width: 0, height: 0)
    }

    // MARK: Export

    /// Save As via the save panel. Rich content is exported styled when the
    /// clip has formatting; the panel's chosen extension picks the final format.
    func export(_ format: EditorExportFormat) {
        let rich: NSAttributedString?
        if richMode {
            rich = RichTextConverter.appKitValue(from: richText)
        } else {
            rich = text == baseText ? richSource : nil
        }
        let exportTitle = title.isEmpty ? (clip.sourceAppName ?? "Clip") : title
        let payload = text
        Task { @MainActor in
            do {
                if let url = try await EditorExport.saveAs(text: payload, rich: rich, title: exportTitle,
                                                           format: format, window: NSApp.keyWindow) {
                    showStatus("Saved \(url.lastPathComponent)")
                }
            } catch {
                saveError = "Could not export the file."
            }
        }
    }
}

extension CodeLanguage {
    /// Name shown in the syntax menu.
    var displayName: String {
        switch self {
        case .plain: return "Plain Text"
        case .shell: return "Shell"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .ruby: return "Ruby"
        case .swift: return "Swift"
        case .applescript: return "AppleScript"
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .sql: return "SQL"
        case .markup: return "HTML/XML"
        case .csv: return "CSV"
        }
    }
}
