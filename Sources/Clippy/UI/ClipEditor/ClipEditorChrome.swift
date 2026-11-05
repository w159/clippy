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
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Instruction", text: $instruction)
                        .onSubmit(run)
                } header: {
                    Label(action.name, systemImage: "sparkles").font(.headline)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message)
                        if !instruction.isEmpty && trimmed.isEmpty {
                            Text("Enter an instruction.").foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .buttonStyle(.glass).tint(nil)
                        .keyboardShortcut(.cancelAction)
                    Button("Run", action: run)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmed.isEmpty)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 4)
        }
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
            HStack(alignment: .top, spacing: 12) {
                pane("Your version", text: mine)
                pane("Stored version", text: stored)
            }
            .padding(12)
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Spacer()
                    Button("Use Stored Version", action: onReload)
                        .buttonStyle(.glass).tint(nil)
                        .help("Discard your edits and load the stored text")
                    Button("Keep My Version", action: onKeepMine)
                        .buttonStyle(.glassProminent)
                        .help("Keep your edits; Save overwrites the stored text")
                    Button("Close", role: .cancel, action: onClose)
                        .buttonStyle(.glass).tint(nil)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .frame(minWidth: 560, minHeight: 300)
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
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
