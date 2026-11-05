import SwiftUI

/// Distinct whole-pane states for 1Password; each recovery action is explicit.
enum OnePasswordPanelState {
    case notInstalled
    case needsSignIn(String)
    case loading
    case empty
    case error(String)
}

/// Designed state content for installation, sign-in, load, empty and error states.
struct OnePasswordStatePanel: View {
    let state: OnePasswordPanelState
    var signingIn = false
    let retry: () -> Void
    let signIn: () -> Void

    var body: some View {
        Group {
            if case .loading = state {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(title).font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(title, systemImage: icon)
                } description: {
                    Text(message)
                } actions: {
                    action
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .notInstalled, .empty, .error:
            Button(stateTitle, action: retry).buttonStyle(.glassProminent)
        case .needsSignIn:
            Button(action: signIn) {
                if signingIn { ProgressView().controlSize(.small) }
                else { Text("Sign in with op signin") }
            }
            .buttonStyle(.glassProminent)
            .disabled(signingIn)
        case .loading:
            ProgressView("Reading vault\u{2026}").controlSize(.small)
        }
    }

    private var title: String {
        switch state {
        case .notInstalled: return "1Password CLI not found"
        case .needsSignIn: return "Sign in to 1Password"
        case .loading: return "Loading vault"
        case .empty: return "No items in this vault"
        case .error: return "Could not reach 1Password"
        }
    }

    private var message: String {
        switch state {
        case .notInstalled: return "Install 1Password 8 and turn on the command-line tool in Developer settings."
        case .needsSignIn(let detail):
            return detail.isEmpty ? "Clippy needs an authorized 1Password session to read this vault." : detail
        case .loading: return "The vault request is bounded by a 20-second timeout."
        case .empty: return "This vault contains no items. Choose a different vault in Settings or add an item in 1Password."
        case .error(let detail): return detail
        }
    }

    private var stateTitle: String {
        switch state {
        case .notInstalled: return "Check again"
        case .empty: return "Refresh"
        case .error: return "Try Again"
        default: return "Try Again"
        }
    }

    private var icon: String {
        switch state {
        case .notInstalled: return "key.slash"
        case .needsSignIn: return "person.crop.circle.badge.exclamationmark"
        case .loading: return "key.fill"
        case .empty: return "tray"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}
