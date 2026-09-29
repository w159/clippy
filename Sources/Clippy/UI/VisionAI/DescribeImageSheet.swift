import SwiftUI

/// Describe / extract text from an image clip, on-device. Sensitive clips
/// need explicit confirmation before any analysis runs.
struct DescribeImageSheet: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.dismiss) private var dismiss
    let imageURL: URL
    let isSensitive: Bool
    let onSaveAsClip: (String) -> Void

    @State private var confirmed = false
    @State private var result: ImageDescription?
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var saved = false
    @State private var copied = false
    /// Bumped to (re)start analysis: on confirm and on Try again.
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisRequestID = UUID()

    /// `onSaveAsClip` receives the description text when the user saves it.
    init(imageURL: URL, isSensitive: Bool, onSaveAsClip: @escaping (String) -> Void) {
        self.imageURL = imageURL
        self.isSensitive = isSensitive
        self.onSaveAsClip = onSaveAsClip
    }

    var body: some View {
        ClippySheet(title: "Describe image") {
            if isSensitive && !confirmed {
                Text("This image is marked sensitive. Analysis stays on this Mac. Continue?")
                    .foregroundStyle(tokens.textSecondary)
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Analyze anyway") {
                        confirmed = true
                        startAnalysis()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            } else {
                content
            }
        }
        .frame(minWidth: 420, idealWidth: 480)
        .onAppear {
            resetForPresentation()
            if !isSensitive { startAnalysis() }
        }
        .onDisappear {
            analysisTask?.cancel()
            analysisTask = nil
        }
        .onChange(of: imageURL) { _, _ in
            resetForPresentation()
            if !isSensitive { startAnalysis() }
        }
        .onChange(of: isSensitive) { _, sensitive in
            resetForPresentation()
            if !sensitive { startAnalysis() }
        }
    }

    @ViewBuilder private var content: some View {
        if isWorking {
            HStack(spacing: tokens.metrics.space.two) {
                ProgressView().controlSize(.small)
                Text("Analyzing…").foregroundStyle(tokens.textSecondary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        }
        if let errorMessage {
            Text(errorMessage).foregroundStyle(tokens.danger)
            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Try again") { startAnalysis() }.keyboardShortcut(.defaultAction)
            }
        }
        if let result {
            ScrollView { Text(result.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minHeight: 80, maxHeight: 220)
            Text(result.originNote).font(.caption).foregroundStyle(tokens.textTertiary)
            HStack {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text, forType: .string)
                    copied = true
                }
                .keyboardShortcut(.defaultAction)
                Button(saved ? "Saved" : "Save as clip") {
                    guard !saved else { return }
                    onSaveAsClip(result.text)
                    saved = true
                }
                .disabled(saved)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func resetForPresentation() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisRequestID = UUID()
        confirmed = false
        result = nil
        errorMessage = nil
        isWorking = false
        saved = false
        copied = false
    }

    private func startAnalysis() {
        guard !isWorking, !isSensitive || confirmed else { return }
        isWorking = true
        errorMessage = nil
        result = nil
        copied = false
        saved = false
        analysisTask?.cancel()
        let requestID = UUID()
        analysisRequestID = requestID
        analysisTask = Task { await run(requestID: requestID) }
    }

    private func run(requestID: UUID) async {
        defer { if analysisRequestID == requestID { isWorking = false } }
        do {
            let described = try await ImageDescriber.describe(imageURL: imageURL)
            guard !Task.isCancelled, analysisRequestID == requestID else { return }
            result = described
        } catch {
            guard !Task.isCancelled, analysisRequestID == requestID else { return }
            errorMessage = "The image could not be read."
        }
    }
}
