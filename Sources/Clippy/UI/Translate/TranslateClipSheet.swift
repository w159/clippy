import SwiftUI
import Translation

/// Translate a text clip with the on-device Translation framework. Translation
/// runs on this Mac using downloaded language packs; the system UI prompts for
/// any missing pack. Sensitive clips need explicit confirmation first.
struct TranslateClipSheet: View {
    @Environment(\.clippyTokens) private var tokens
    @Environment(\.dismiss) private var dismiss
    let clipID: Int64
    let text: String
    let isSensitive: Bool
    let sink: TranslateActionSink

    @State private var target: Locale.Language
    /// Detected once: language recognition is too costly to redo on every body pass.
    @State private var source: Locale.Language?
    @State private var configuration: TranslationSession.Configuration?
    @State private var result: String?
    @State private var errorMessage: String?
    @State private var confirmed = false
    @State private var isWorking = false
    @State private var status: String?
    @State private var requestID = UUID()
    @State private var confirmReplace = false

    /// `sink` receives Copy / Save as new clip / Replace actions.
    init(clipID: Int64, text: String, isSensitive: Bool, sink: TranslateActionSink) {
        self.clipID = clipID
        self.text = text
        self.isSensitive = isSensitive
        self.sink = sink
        let detected = TranslationSupport.detectLanguage(of: text)
        _source = State(initialValue: detected)
        // Default to the first offered language that differs from the source.
        let first = TranslationSupport.targetIdentifiers
            .map { Locale.Language(identifier: $0) }
            .first { !TranslationSupport.isSameLanguage(detected, $0) }
        _target = State(initialValue: first ?? Locale.Language(identifier: TranslationSupport.targetIdentifiers[0]))
    }

    private var gate: TranslateGate { TranslateGate.evaluate(text: text, isSensitive: isSensitive, confirmed: confirmed) }

    var body: some View {
        ClippySheet(title: "Translate clip") {
            switch gate {
            case .empty:
                VStack(alignment: .leading, spacing: tokens.metrics.space.three) {
                    Text("There is no text to translate.").foregroundStyle(tokens.textSecondary)
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            case .needsConfirmation: confirmation
            case .allowed: content
            }
        }
        .frame(minWidth: 440, idealWidth: 480)
        .onAppear { resetForPresentation() }
        .onChange(of: clipID) { _, _ in resetForPresentation() }
        .onChange(of: target) { _, _ in
            result = nil
            errorMessage = nil
            status = nil
        }
        .translationTask(configuration) { session in
            // The framework hands the session to this closure for exactly one use; nothing
            // else touches it, so it can cross to the concurrent `translate` call.
            let activeRequestID = requestID
            let outcome = await Self.translate(text, with: UncheckedSendable(session))
            finish(outcome, requestID: activeRequestID)
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.three) {
            Text("This clip looks sensitive. Translation runs on this Mac, but the result is a new copy of sensitive text.")
                .foregroundStyle(tokens.textSecondary)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Translate anyway") { confirmed = true }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.three) {
            HStack {
                Text("From: \(source.map(TranslationSupport.displayName) ?? "Unknown")")
                Picker("To", selection: $target) {
                    ForEach(TranslationSupport.targetIdentifiers, id: \.self) { identifier in
                        let language = Locale.Language(identifier: identifier)
                        Text(TranslationSupport.displayName(language)).tag(language)
                    }
                }
                .frame(maxWidth: 240)
                .disabled(isWorking)
                Button(errorMessage == nil ? "Translate" : "Try again") { start() }
                    .keyboardShortcut(result == nil ? .defaultAction : nil)
                    .disabled(isWorking || isSameLanguage)
            }
            statusRow
            if let result { resultView(result) }
            Text("Translation runs on-device using downloaded language packs. macOS may ask to download a pack.")
                .font(.caption).foregroundStyle(tokens.textTertiary)
        }
        .foregroundStyle(tokens.textPrimary)
    }

    private var isSameLanguage: Bool { TranslationSupport.isSameLanguage(source, target) }

    /// Fixed-height row so progress, errors and confirmations never move the content below.
    private var statusRow: some View {
        HStack(spacing: tokens.metrics.space.two) {
            if isWorking {
                ProgressView().controlSize(.small)
                Text("Translating…").foregroundStyle(tokens.textSecondary)
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(tokens.danger)
            } else if let status {
                Text(status).foregroundStyle(tokens.success)
            } else if isSameLanguage {
                Text("Pick a different target language.").foregroundStyle(tokens.textSecondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
    }

    private func resultView(_ translated: String) -> some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.two) {
            ScrollView { Text(translated).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 200)
            HStack {
                Button("Copy") {
                    sink.copy(translated)
                    status = "Copied"
                }
                .keyboardShortcut(.defaultAction)
                Button("Save as new clip") {
                    sink.saveAsNewClip(translated)
                    status = "Saved"
                }
                Button("Replace…") { confirmReplace = true }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .confirmationDialog("Replace the original clip with the translation?", isPresented: $confirmReplace) {
            Button("Replace", role: .destructive) {
                sink.replaceClip(clipID, with: translated)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The original text will be overwritten.")
        }
    }

    private func resetForPresentation() {
        confirmed = false
        source = TranslationSupport.detectLanguage(of: text)
        result = nil
        errorMessage = nil
        status = nil
        confirmReplace = false
        isWorking = false
        requestID = UUID()
        configuration = nil
        target = TranslationSupport.targetIdentifiers
            .map { Locale.Language(identifier: $0) }
            .first { !TranslationSupport.isSameLanguage(source, $0) }
            ?? Locale.Language(identifier: TranslationSupport.targetIdentifiers[0])
    }

    private func start() {
        guard !isWorking else { return }
        result = nil
        errorMessage = nil
        status = nil
        isWorking = true
        requestID = UUID()
        if configuration == nil {
            configuration = TranslationSession.Configuration(source: source, target: target)
        } else {
            configuration?.source = source
            configuration?.target = target
            configuration?.invalidate()
        }
    }

    /// Runs off the main actor: `TranslationSession` is not Sendable, so it stays in the
    /// nonisolated task the framework hands it to and only the outcome crosses back.
    private nonisolated static func translate(_ text: String, with session: UncheckedSendable<TranslationSession>) async
        -> Result<String, Error> {
        do {
            return .success(try await session.value.translate(text).targetText)
        } catch {
            return .failure(error)
        }
    }

    @MainActor private func finish(_ outcome: Result<String, Error>, requestID: UUID) {
        guard self.requestID == requestID else { return }
        switch outcome {
        case .success(let translated):
            result = translated
        case .failure:
            errorMessage = "Translation was not completed. Check that the language pack is installed."
        }
        isWorking = false
    }
}
