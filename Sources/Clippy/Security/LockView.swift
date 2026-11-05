import SwiftUI

/// Shown in place of the clip list while `AppLock` is locked. Contains no clip
/// data. Authenticates automatically on appear and offers a retry button.
struct LockView: View {
    var lock: AppLock
    var onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, isActive: lock.isAuthenticating && !reduceMotion)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Clippy is locked")
                    .font(.title2.weight(.semibold))
                if lock.lastAttemptFailed {
                    Label("Authentication failed or was cancelled.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unlock to see your clipboard history.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button("Close", action: onClose)
                        .buttonStyle(.glass).tint(nil)
                        .keyboardShortcut(.cancelAction)
                    Button("Unlock") { lock.unlock() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(lock.isAuthenticating)
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clippy is locked")
        .onAppear { lock.unlock() }
    }
}
