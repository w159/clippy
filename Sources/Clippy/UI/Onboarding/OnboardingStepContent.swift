import SwiftUI
import UserNotifications

/// The body of the current onboarding step. Each step reads live state from the view model.
struct OnboardingStepContent: View {
    var viewModel: OnboardingViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heroTick = 0

    var body: some View {
        VStack(spacing: 16) {
            switch viewModel.model.current {
            case .welcome: welcome
            case .accessibility: accessibility
            case .suggestions: suggestions
            case .ocr: ocr
            case .hotkey: hotkey
            case .launchAtLogin: launchAtLogin
            case .notifications: notifications
            case .privacy: privacy
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { if !reduceMotion { heroTick += 1 } }
    }

    /// Large symbol, title and body, centered. The symbol bounces once when the step appears.
    private func hero(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.clippyAccent)
                .symbolEffect(.bounce, options: .nonRepeating, value: heroTick)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text(title).font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(detail).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    /// A rounded card holding a group of rows.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// A permission row: title on the left, live status on the right.
    private func permissionRow(_ title: String, ok: Bool, okText: String, pendingText: String) -> some View {
        card {
            HStack {
                Text(title).font(.headline)
                Spacer(minLength: 12)
                status(ok ? okText : pendingText, ok: ok)
            }
        }
    }

    /// The "what you get" checklist for a permission step.
    private func benefits(_ step: OnboardingStep) -> some View {
        card {
            Text("What you get").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(step.benefits, id: \.self) { item in
                Label(item, systemImage: "checkmark.circle.fill").font(.callout)
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }

    private func status(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(ok ? Color.green : Color.orange)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            hero("paperclip", "Your clipboard, remembered",
                 "Clippy keeps what you copy so you can paste it again. This short tour sets up permissions, optional features and your shortcut. " +
                     "Every step can be skipped and changed later in Settings.")
            card {
                welcomeFeature("magnifyingglass", "Find anything you copied", "Search text, links, files and the words inside images.")
                welcomeFeature("folder", "Keep what matters", "File clips into categories so they stay out of the way of history.")
                welcomeFeature("keyboard", "Paste without leaving the keyboard", "Open the panel with your shortcut, pick a clip, press Return.")
            }
        }
    }

    private func welcomeFeature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.clippyAccent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var accessibility: some View {
        VStack(spacing: 16) {
            hero("hand.raised.fill", "Allow Accessibility",
                 "Clippy uses Accessibility to send the paste keystroke and to find your text caret so the panel opens " +
                     "beside it. It reads only the caret position, never the content of other apps here. " +
                     "Everything stays on this Mac.")
            permissionRow("Accessibility", ok: viewModel.accessibilityTrusted, okText: "Access granted", pendingText: "Not granted yet")
            benefits(.accessibility)
            if !viewModel.accessibilityTrusted {
                Button("Grant Access") { viewModel.grantAccessibility() }
                    .buttonStyle(.glass).tint(nil)
                    .controlSize(.large)
                note("This updates automatically when you return from System Settings.")
            }
        }
    }

    private var suggestions: some View {
        VStack(spacing: 16) {
            hero("sparkles", "Smart Suggestions (optional)",
                 "Suggests clips that fit the app you are typing in, using its name and window title. On-device only. " +
                     "Off unless you turn it on.")
            card {
                Toggle("Turn on Smart Suggestions", isOn: Binding(get: { viewModel.suggestionsOn }, set: { viewModel.setSuggestions($0) }))
            }
            if !viewModel.accessibilityTrusted {
                note("Suggestions also need Accessibility access (previous step).")
            }
        }
    }

    private var ocr: some View {
        VStack(spacing: 16) {
            hero("text.viewfinder", "Search text inside images (optional)",
                 "Clippy can recognize text in copied images on this Mac so you can find them by search. " +
                     "Recognized text never leaves the device and can be deleted in Settings.")
            card {
                Toggle("Index text in images", isOn: Binding(get: { viewModel.ocrOn }, set: { viewModel.setOCR($0) }))
            }
        }
    }

    private var hotkey: some View {
        VStack(spacing: 16) {
            hero("command", "Choose your shortcut", "Press this from any app to open Clippy. Conflicts with system shortcuts are flagged.")
            card {
                HotKeyRecorderView(action: .showPanel)
                HotKeyRecorderView(action: .pastePlain)
                HotKeyRecorderView(action: .pastePrevious)
            }
        }
    }

    private var launchAtLogin: some View {
        VStack(spacing: 16) {
            hero("power", "Open Clippy at login", "Clippy lives in the menu bar and only captures while it is running.")
            card {
                Toggle("Launch Clippy at login", isOn: Binding(
                    get: { viewModel.launchStatus == .enabled || viewModel.launchStatus == .requiresApproval },
                    set: { viewModel.setLaunchAtLogin($0) }))
                switch viewModel.launchStatus {
                case .requiresApproval:
                    status("Waiting for approval in System Settings", ok: false)
                    Button("Open Login Items") { LaunchAtLogin.openSystemSettings() }
                        .buttonStyle(.glass).tint(nil)
                case .notFound:
                    Text("Not available in this build (run the packaged app).").font(.caption).foregroundStyle(.secondary)
                default: EmptyView()
                }
                if let error = viewModel.launchError { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    private var notificationsAllowed: Bool {
        switch viewModel.notificationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    private var notifications: some View {
        VStack(spacing: 16) {
            hero("bell.badge.fill", "Notifications (optional)",
                 "Get a notice when Clippy clears a sensitive clip from the clipboard automatically.")
            permissionRow("Notifications",
                          ok: notificationsAllowed,
                          okText: "Allowed", pendingText: viewModel.notificationStatus == .denied ? "Off for Clippy" : "Not asked yet")
            benefits(.notifications)
            switch viewModel.notificationStatus {
            case .authorized, .provisional, .ephemeral: EmptyView()
            case .denied:
                note("Enable them in System Settings > Notifications.")
            default:
                Button {
                    viewModel.requestNotifications()
                } label: {
                    if viewModel.requestingNotifications {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Requesting…")
                        }
                    } else {
                        Text("Allow notifications")
                    }
                }
                .buttonStyle(.glass).tint(nil)
                .controlSize(.large)
                .disabled(viewModel.requestingNotifications)
            }
        }
    }

    private var privacy: some View {
        VStack(spacing: 16) {
            hero("lock.shield.fill", "Your data stays yours", "A summary of how Clippy handles what you copy.")
            card {
                Label("History is stored locally on this Mac.", systemImage: "internaldrive")
                Label("Passwords, card numbers and keys are masked, and reveal only while held.", systemImage: "eye.slash")
                Label("Nothing is sent anywhere unless you enable AI or sync.", systemImage: "network.slash")
                Label(viewModel.accessibilityTrusted ? "Accessibility: granted" : "Accessibility: not granted",
                      systemImage: "hand.raised")
                Label(viewModel.suggestionsOn ? "Smart Suggestions: on" : "Smart Suggestions: off", systemImage: "sparkles")
                Label(viewModel.ocrOn ? "Image text search: on" : "Image text search: off", systemImage: "text.viewfinder")
            }
            .font(.callout)
        }
    }
}
