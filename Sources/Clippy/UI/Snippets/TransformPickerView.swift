import SwiftUI

/// Actions the integrator provides so the picker never touches ClipStore or the pasteboard itself.
protocol TransformActionSink {
    /// Saves `text` as a new clip.
    func saveAsNewClip(_ text: String)
    /// Replaces the source clip's text with `text`.
    func replaceText(_ text: String)
    /// Copies `text` to the pasteboard.
    func copyResult(_ text: String)
}

/// Sheet for picking and chaining local text transforms with a live preview.
struct TransformPickerView: View {
    @Environment(\.clippyTokens) private var tokens
    @FocusState private var searchFocused: Bool
    /// Text being transformed.
    let sourceText: String
    /// True when the source clip is sensitive; applying then requires confirmation.
    let isSensitive: Bool
    /// Receives the chosen action.
    let sink: TransformActionSink
    /// Closes the sheet.
    let onClose: () -> Void

    @State private var query = ""
    @State private var chainIDs: [String] = []
    @State private var regexPattern = ""
    @State private var regexTemplate = ""
    @State private var pendingAction: ((String) -> Void)?
    @State private var confirmSensitive = false
    @State private var didApply = false
    @State private var confirmReplace = false

    /// Creates the picker for a clip's text.
    init(clip: Clip, sink: TransformActionSink, onClose: @escaping () -> Void) {
        self.sourceText = clip.contentText
        self.isSensitive = SensitiveContent.isSensitive(clip: clip)
        self.sink = sink
        self.onClose = onClose
    }

    private var chain: TransformChain {
        var steps = chainIDs.compactMap { TransformRegistry.transform(id: $0) }
        if !regexPattern.isEmpty { steps.append(RegexReplaceTransform(pattern: regexPattern, template: regexTemplate)) }
        return TransformChain(steps: steps)
    }

    var body: some View {
        let preview = chain.preview(for: sourceText)
        ClippySheet(title: "Transform text") {
            HStack(alignment: .top, spacing: tokens.metrics.space.three) { catalogue; chainBuilder(preview) }
            HStack(spacing: tokens.metrics.space.two) {
                Text("Runs on this Mac only. Nothing is sent anywhere.").font(.caption).foregroundStyle(tokens.textSecondary)
                Spacer()
                Button("Close", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                Button("Copy result") { request(sink.copyResult) }.disabled(!canApply(preview))
                Button("Replace text") { requestReplace(sink.replaceText) }
                    .disabled(!canApply(preview))
                    .confirmationDialog("Replace the original text?", isPresented: $confirmReplace, titleVisibility: .visible) {
                        Button("Replace", role: .destructive) { runPending() }
                        Button("Cancel", role: .cancel) { pendingAction = nil }
                    } message: {
                        Text("This replaces the source clip. Save as a new clip to keep the original.")
                    }
                Button("Save as new clip") { request(sink.saveAsNewClip) }
                    .keyboardShortcut(.defaultAction).disabled(!canApply(preview))
            }
        }
        .frame(minWidth: 720, idealWidth: 760, minHeight: 460)
        .onAppear { searchFocused = true; query = ""; chainIDs = []; regexPattern = ""; regexTemplate = ""; pendingAction = nil; confirmSensitive = false; confirmReplace = false; didApply = false }
        .confirmationDialog("This clip looks sensitive", isPresented: $confirmSensitive, titleVisibility: .visible) {
            Button("Transform anyway", role: .destructive) { runPending() }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: {
            Text("The clip may contain a password, key or personal data. The result would be stored or copied as plain text.")
        }
    }

    private var catalogue: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.two) {
            TextField("Search transforms", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
            let matches = TransformRegistry.search(query)
            if matches.isEmpty {
                Text("No transforms match. Try a shorter search.").font(.caption).foregroundStyle(tokens.textSecondary)
            }
            List(matches, id: \.id) { item in
                Button { chainIDs.append(item.id) } label: {
                    HStack { Text(item.title); Spacer(); Text(item.category.rawValue).font(.caption).foregroundStyle(tokens.textSecondary) }
                }.buttonStyle(.plain)
            }
        }
        .frame(width: 280)
    }

    private func chainBuilder(_ preview: TransformPreview) -> some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.two) {
            Text("Chain").font(.headline)
            if chainIDs.isEmpty {
                Text("Pick transforms on the left; they run top to bottom.").font(.caption).foregroundStyle(tokens.textSecondary)
            }
            ForEach(Array(chainIDs.enumerated()), id: \.offset) { index, chainID in
                HStack {
                    Text("\(index + 1). \(TransformRegistry.transform(id: chainID)?.title ?? chainID)")
                    Spacer()
                    Button { if chainIDs.indices.contains(index) { chainIDs.remove(at: index) } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).accessibilityLabel("Remove step")
                }
            }
            HStack {
                TextField("Regex find", text: $regexPattern).textFieldStyle(.roundedBorder)
                TextField("Replace ($1)", text: $regexTemplate).textFieldStyle(.roundedBorder)
            }
            Divider()
            previewBox("Before", preview.before)
            previewBox(preview.error == nil ? "After" : "Error", preview.after, isError: preview.error != nil)
            if preview.isTruncated { Text("Preview is shortened; the full text is transformed.").font(.caption).foregroundStyle(tokens.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewBox(_ label: String, _ text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(tokens.textSecondary)
            ScrollView { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 90).padding(tokens.metrics.space.two)
                .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm))
                .foregroundStyle(isError ? tokens.danger : tokens.textPrimary)
        }
    }

    private func canApply(_ preview: TransformPreview) -> Bool { preview.error == nil && !(chainIDs.isEmpty && regexPattern.isEmpty) }

    private func requestReplace(_ action: @escaping (String) -> Void) {
        guard !didApply else { return }
        pendingAction = action
        if isSensitive { confirmSensitive = true } else { confirmReplace = true }
    }

    private func request(_ action: @escaping (String) -> Void) {
        guard !didApply else { return }
        pendingAction = action
        if isSensitive { confirmSensitive = true } else { runPending() }
    }

    private func runPending() {
        defer { pendingAction = nil }
        guard !didApply, let action = pendingAction, let output = chain.run(sourceText).output else { return }
        didApply = true
        action(output)
        onClose()
    }
}
