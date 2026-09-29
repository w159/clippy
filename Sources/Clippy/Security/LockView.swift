import SwiftUI

/// Shown in place of the clip list while `AppLock` is locked. Contains no clip
/// data. Authenticates automatically on appear and offers a retry button.
struct LockView: View {
    @ObservedObject var lock: AppLock
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Clippy is locked")
                .font(.headline)
            if lock.lastAttemptFailed {
                Text("Authentication failed or was cancelled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Unlock") { lock.unlock() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(lock.isAuthenticating)
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clippy is locked")
        .onAppear { lock.unlock() }
    }
}
