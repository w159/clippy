import SwiftUI

/// SEC-01: the powers the assistant currently has, derived from settings.
struct AssistantCapabilities: Equatable {
    var codeExecution: Bool
    var scripts: Bool
    var webSearch: Bool

    /// True when any switch that lets the assistant act beyond reading clips is on.
    var anyEnabled: Bool { codeExecution || scripts || webSearch }

    /// Short chip label, e.g. "Code · Scripts · Web".
    var label: String {
        var parts: [String] = []
        if codeExecution { parts.append("Code") }
        if scripts { parts.append("Scripts") }
        if webSearch { parts.append("Web") }
        return parts.joined(separator: " · ")
    }

    /// One explanation line per enabled capability, for the popover.
    var explanations: [String] {
        var lines: [String] = []
        if codeExecution {
            lines.append("Code execution: the assistant can run code it writes. It runs in a sandbox "
                + "with no network and a read-only filesystem unless you approve otherwise, "
                + "and you confirm each run.")
        }
        if scripts {
            lines.append("Scripts: the assistant can run your saved scripts, which have the same access you do unless a script is marked sandboxed.")
        }
        if webSearch {
            lines.append("Web search: the assistant's search queries are sent to a web search service.")
        }
        return lines
    }
}

/// Persistent header chip shown while code execution, script execution or web
/// search is enabled. Tapping it explains what is on and offers a way to Settings.
struct AssistantCapabilityChip: View {
    let capabilities: AssistantCapabilities
    let onOpenSettings: () -> Void
    @Environment(\.clippyTokens) private var tokens
    @State private var showDetails = false

    var body: some View {
        if capabilities.anyEnabled {
            Button {
                showDetails.toggle()
            } label: {
                Label(capabilities.label, systemImage: "exclamationmark.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tokens.warning)
                    .padding(.horizontal, tokens.metrics.space.two)
                    .padding(.vertical, tokens.metrics.space.one)
                    .background(Capsule().fill(tokens.warning.opacity(0.15)))
                    .overlay(Capsule().strokeBorder(tokens.warning.opacity(0.45), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .help("The assistant has extra powers enabled. Click for details.")
            .accessibilityLabel("Assistant powers enabled: \(capabilities.label)")
            .popover(isPresented: $showDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Assistant powers enabled").font(.headline)
                    ForEach(capabilities.explanations, id: \.self) { line in
                        Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Open Settings") {
                        showDetails = false
                        onOpenSettings()
                    }
                }
                .padding(12)
                .frame(width: 300, alignment: .leading)
            }
        }
    }
}
