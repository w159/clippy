import AppKit
import SwiftUI

/// An AI result staged for the next Save (EDT-09). Rewrite / summary / title
/// stage into the editor fields; the rest are held here until Save applies them.
enum PendingEffect: Equatable, Identifiable {
    case newClip(String)
    case copy(String)
    case category(String)

    var id: String {
        switch self {
        case .newClip: return "newClip"
        case .copy: return "copy"
        case .category: return "category"
        }
    }

    var label: String {
        switch self {
        case .newClip: return "Create a new clip on Save"
        case .copy: return "Copy the result on Save"
        case .category(let name): return "File under \"\(name)\" on Save"
        }
    }
}


// MARK: - Instruction sheet
/// Collects the instruction for an AI action. Run stays disabled until the
/// trimmed input is non-empty, with an inline hint instead of a silent dismiss.
struct InstructionSheet: View {
    let action: AIAction
    let onRun: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var instruction = ""

    private var trimmed: String { instruction.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var message: String {
        switch action.name {
        case "Translate":     return "Which language should this be translated to?"
        case "Change Tone":   return "What tone? (e.g. formal, friendly, concise)"
        case "Rewrite":       return "How should this be rewritten?"
        case "Generate Clip": return "What should the new clip contain?"
        default:              return "Enter an instruction for this action."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(action.name).font(.headline)
            Text(message).foregroundStyle(.secondary)
            TextField("Instruction", text: $instruction)
                .textFieldStyle(.roundedBorder)
                .onSubmit(run)
            if !instruction.isEmpty && trimmed.isEmpty {
                Text("Enter an instruction.")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Run", action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func run() {
        guard !trimmed.isEmpty else { return }
        dismiss()
        onRun(trimmed)
    }
}


/// Side-by-side view of the editor's text and the stored text.
struct EditorCompareSheet: View {
    let mine: String
    let stored: String
    let onReload: () -> Void
    let onKeepMine: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                pane("Your version", text: mine)
                Divider()
                pane("Stored version", text: stored)
            }
            Divider()
            HStack {
                Spacer()
                Button("Reload", action: onReload)
                Button("Keep mine", action: onKeepMine)
                Button("Close", role: .cancel, action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 360)
    }

    private func pane(_ heading: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(.headline)
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
