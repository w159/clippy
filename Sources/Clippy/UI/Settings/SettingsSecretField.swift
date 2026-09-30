import AppKit
import SwiftUI

/// Pure presentation rules for masked secret fields.
enum SecretFieldLogic {
    /// Fixed-length placeholder shown for a read-only secret so its length never leaks.
    static let placeholderMask = String(repeating: "\u{2022}", count: 24)

    /// Text shown in a read-only field: the loaded value only while revealed.
    static func readOnlyDisplay(value: String?, revealed: Bool) -> String {
        guard revealed, let value else { return placeholderMask }
        return value
    }
}

/// A labeled secret value: the reveal eye sits inside the field's trailing edge and copy is a
/// separate icon button after it. Editable (bound draft) or read-only (value loaded on demand).
struct SettingsSecretField: View {
    @Environment(\.clippyTokens) private var tokens
    @State private var revealed = false
    @State private var loaded: String?
    @State private var copied = false

    let typeLabel: String
    let prompt: String
    private let draft: Binding<String>?
    private let load: (@Sendable () async -> String?)?

    /// Editable secret backed by a draft binding.
    init(typeLabel: String, prompt: String, text: Binding<String>) {
        self.typeLabel = typeLabel
        self.prompt = prompt
        self.draft = text
        self.load = nil
    }

    /// Read-only secret; `load` runs only when the user reveals or copies it.
    init(typeLabel: String, load: @escaping @Sendable () async -> String?) {
        self.typeLabel = typeLabel
        self.prompt = ""
        self.draft = nil
        self.load = load
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
            Text("\(typeLabel) \u{00B7} masked")
                .font(.caption).foregroundStyle(tokens.textSecondary)
            HStack(spacing: tokens.metrics.space.two) {
                field
                IconButton(copied ? "checkmark" : "doc.on.doc", label: "Copy \(typeLabel)", help: "Copy \(typeLabel)",
                           state: canCopy ? .rest : .disabled) { copy() }
            }
        }
    }

    private var canCopy: Bool { draft.map { !$0.wrappedValue.isEmpty } ?? true }

    private var field: some View {
        HStack(spacing: tokens.metrics.space.one) {
            content
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(tokens.textPrimary)
                .lineLimit(1)
            IconButton(revealed ? "eye.slash" : "eye", label: revealed ? "Hide \(typeLabel)" : "Reveal \(typeLabel)") { toggleReveal() }
        }
        .padding(.leading, tokens.metrics.space.three)
        .padding(.trailing, tokens.metrics.space.one)
        .frame(minHeight: 32)
        .background(tokens.surfaceInset, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm, style: .continuous).stroke(tokens.stroke, lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        if let draft {
            if revealed { TextField(typeLabel, text: draft, prompt: Text(prompt)) }
            else { SecureField(typeLabel, text: draft, prompt: Text(prompt)) }
        } else {
            Text(SecretFieldLogic.readOnlyDisplay(value: loaded, revealed: revealed))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggleReveal() {
        if revealed { revealed = false; loaded = nil; return }
        guard let load else { revealed = true; return }
        Task { loaded = await load(); revealed = loaded != nil }
    }

    private func copy() {
        if let draft { write(draft.wrappedValue); return }
        guard let load else { return }
        Task { if let value = await load() { write(value) } }
    }

    /// Concealed write so the clipboard monitor never records the secret in history.
    private func write(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}
