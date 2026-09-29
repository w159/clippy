import SwiftUI

/// Per-script sandbox controls for the options popover (SEC-07): the
/// `Sandboxed` toggle, the network sub-toggle, and the preflight availability.
struct ScriptSandboxControls: View {
    @Environment(\.clippyTokens) private var tokens
    let scriptID: UUID
    private let policy = ScriptSandboxPolicy()
    @State private var sandboxed: Bool
    @State private var allowNetwork: Bool
    @State private var availability: SandboxAvailability?

    init(scriptID: UUID) {
        self.scriptID = scriptID
        let policy = ScriptSandboxPolicy()
        _sandboxed = State(initialValue: policy.isSandboxed(scriptID))
        _allowNetwork = State(initialValue: policy.isNetworkAllowed(scriptID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
            Toggle("Sandboxed", isOn: Binding(get: { sandboxed }, set: { value in
                sandboxed = value
                policy.setSandboxed(value, for: scriptID)
                if !value { allowNetwork = false }
            }))
            Toggle("Allow network access", isOn: Binding(get: { allowNetwork }, set: { value in
                allowNetwork = value
                policy.setNetworkAllowed(value, for: scriptID)
            }))
            .padding(.leading, tokens.metrics.space.four)
            .disabled(!sandboxed)
            if let availability {
                Label(ScriptSandboxPolicy.availabilityCaption(availability),
                      systemImage: availability.isAvailable ? "checkmark.shield" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(availability.isAvailable ? tokens.textSecondary : tokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Checking sandbox...").font(.caption).foregroundStyle(tokens.textSecondary)
            }
        }
        .task {
            availability = await Task.detached(priority: .utility) { SandboxRunner.preflight() }.value
        }
    }
}
