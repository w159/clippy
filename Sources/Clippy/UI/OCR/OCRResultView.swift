import AppKit
import SwiftUI

/// Sheet shown after Extract Text (OCR-01). Extraction never touches the
/// clipboard; every write here is an explicit user action: Copy, Save as clip,
/// or Paste (through the panel's existing `onPaste`).
struct OCRResultView: View {
    let result: OCRPresenter.Result
    /// Copies to the general pasteboard (only on the Copy tap).
    var onCopy: (String) -> Void
    /// Saves as a new clip; returns whether it succeeded.
    var onSave: (String) -> Bool
    /// Pastes into the previously active app.
    var onPaste: (String) -> Void
    var onDismiss: () -> Void

    @Environment(\.clippyTokens) private var tokens
    @State private var monospaced = false
    @State private var status: String?
    @State private var statusFailed = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.three) {
            titleRow
            textArea
            footer
        }
        .padding(tokens.metrics.space.four)
        .frame(minWidth: 460, idealWidth: 480)
        .onChange(of: result.id) { _, _ in
            monospaced = false
            status = nil
            statusFailed = false
            saved = false
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.two) {
            statsRow
            actionRow
        }
    }

    private var titleRow: some View {
        HStack {
            Text("Extracted text").font(.headline)
            Spacer()
            Toggle("Monospaced", isOn: $monospaced)
                .toggleStyle(.checkbox)
                .controlSize(.small)
        }
    }

    private var textArea: some View {
        ScrollView {
            Group {
                if hasText {
                    Text(result.text)
                        .foregroundStyle(tokens.textPrimary)
                        .font(monospaced ? .system(.body, design: .monospaced) : .body)
                        .textSelection(.enabled)
                } else {
                    Text("No text found. Try a clearer image, then run Extract Text again.")
                        .foregroundStyle(tokens.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(tokens.metrics.space.two)
        }
        .frame(minHeight: 140, maxHeight: 320)
        .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm, style: .continuous))
    }

    private var hasText: Bool { !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var statsRow: some View {
        HStack(spacing: tokens.metrics.space.two) {
            Text("\(result.wordCount) words · \(result.characterCount) characters")
                .foregroundStyle(tokens.textSecondary)
            if let status {
                Text(status).foregroundStyle(statusFailed ? tokens.danger : tokens.success)
            }
            Spacer()
        }
        .font(.caption)
        .frame(minHeight: 16)
    }

    private var actionRow: some View {
        HStack(spacing: tokens.metrics.space.two) {
            Spacer()
            Button("Close", action: onDismiss).keyboardShortcut(.cancelAction).foregroundStyle(tokens.textPrimary)
            Button("Copy") {
                onCopy(result.text)
                statusFailed = false
                status = "Copied"
            }
            .disabled(!hasText)
            .foregroundStyle(tokens.textPrimary)
            Button(saved ? "Saved" : "Save as clip") { save() }
                .disabled(saved || !hasText)
                .foregroundStyle(tokens.textPrimary)
            Button("Paste") {
                onPaste(result.text)
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasText)
        }
    }

    private func save() {
        guard !saved else { return }
        saved = onSave(result.text)
        statusFailed = !saved
        status = saved ? "Saved" : "Couldn't save. Try again."
    }
}
