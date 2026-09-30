import SwiftUI
import UserNotifications

/// The body of the current onboarding step. Each step reads live state from the view model.
struct OnboardingStepContent: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @Environment(\.clippyTokens) private var tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold)).foregroundStyle(tokens.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(detail).foregroundStyle(tokens.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A permission row: title and detail on the left, live status on the right, action below when needed.
    private func permissionRow(_ title: String, ok: Bool, okText: String, pendingText: String) -> some View {
        HStack {
            Text(title).foregroundStyle(tokens.textPrimary)
            Spacer(minLength: tokens.metrics.space.three)
            status(ok ? okText : pendingText, ok: ok)
        }
        .padding(tokens.metrics.space.three)
        .background(tokens.surfaceElevated, in: RoundedRectangle(cornerRadius: tokens.metrics.radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: tokens.metrics.radius.sm, style: .continuous).stroke(tokens.stroke, lineWidth: 1))
    }

    /// The "what you get" checklist for a permission step.
    private func benefits(_ step: OnboardingStep) -> some View {
        VStack(alignment: .leading, spacing: tokens.metrics.space.one) {
            Text("What you get").font(.caption.weight(.semibold)).foregroundStyle(tokens.textSecondary)
            ForEach(step.benefits, id: \.self) { item in
                Label(item, systemImage: "checkmark").font(.callout).foregroundStyle(tokens.textPrimary)
            }
        }
    }

    private func status(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(ok ? tokens.success : tokens.warning)
    }

    private var welcome: some View {
        heading("Your clipboard, remembered",
                "Clippy keeps what you copy so you can paste it again. This short tour sets up permissions, optional features and your shortcut. " +
                    "Every step can be skipped and changed later in Settings.")
    }

    private var accessibility: some View {
        Group {
            heading("Allow Accessibility",
                    "Clippy uses Accessibility to send the paste keystroke and to find your text caret so the panel opens " +
                        "beside it. It reads only the caret position, never the content of other apps here. " +
                        "Everything stays on this Mac.")
            permissionRow("Accessibility", ok: viewModel.accessibilityTrusted, okText: "Access granted", pendingText: "Not granted yet")
            benefits(.accessibility)
            if !viewModel.accessibilityTrusted {
                Button("Grant Access") { viewModel.grantAccessibility() }
                Text("This updates automatically when you return from System Settings.")
                    .font(.caption).foregroundStyle(tokens.textSecondary)
            }
        }
    }

    private var suggestions: some View {
        Group {
            heading("Smart Suggestions (optional)",
                    "Suggests clips that fit the app you are typing in, using its name and window title. On-device only. " +
                        "Off unless you turn it on.")
            Toggle("Turn on Smart Suggestions", isOn: Binding(get: { viewModel.suggestionsOn }, set: { viewModel.setSuggestions($0) }))
            if !viewModel.accessibilityTrusted {
                Text("Suggestions also need Accessibility access (previous step).")
                    .font(.caption).foregroundStyle(tokens.textSecondary)
            }
        }
    }

    private var ocr: some View {
        Group {
            heading("Search text inside images (optional)",
                    "Clippy can recognize text in copied images on this Mac so you can find them by search. " +
                        "Recognized text never leaves the device and can be deleted in Settings.")
            Toggle("Index text in images", isOn: Binding(get: { viewModel.ocrOn }, set: { viewModel.setOCR($0) }))
        }
    }

    private var hotkey: some View {
        Group {
            heading("Choose your shortcut", "Press this from any app to open Clippy. Conflicts with system shortcuts are flagged.")
            HotKeyRecorderView(action: .showPanel)
            HotKeyRecorderView(action: .pastePlain)
            HotKeyRecorderView(action: .pastePrevious)
        }
    }

    private var launchAtLogin: some View {
        Group {
            heading("Open Clippy at login", "Clippy lives in the menu bar and only captures while it is running.")
            Toggle("Launch Clippy at login", isOn: Binding(
                get: { viewModel.launchStatus == .enabled || viewModel.launchStatus == .requiresApproval },
                set: { viewModel.setLaunchAtLogin($0) }))
            switch viewModel.launchStatus {
            case .requiresApproval:
                status("Waiting for approval in System Settings", ok: false)
                Button("Open Login Items") { LaunchAtLogin.openSystemSettings() }
            case .notFound:
                Text("Not available in this build (run the packaged app).").font(.caption).foregroundStyle(tokens.textSecondary)
            default: EmptyView()
            }
            if let error = viewModel.launchError { Text(error).font(.caption).foregroundStyle(tokens.danger) }
        }
    }

    private var notificationsAllowed: Bool {
        switch viewModel.notificationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    private var notifications: some View {
        Group {
            heading("Notifications (optional)",
                    "Get a notice when Clippy clears a sensitive clip from the clipboard automatically.")
            permissionRow("Notifications",
                          ok: notificationsAllowed,
                          okText: "Allowed", pendingText: viewModel.notificationStatus == .denied ? "Off for Clippy" : "Not asked yet")
            benefits(.notifications)
            switch viewModel.notificationStatus {
            case .authorized, .provisional, .ephemeral: EmptyView()
            case .denied:
                Text("Enable them in System Settings > Notifications.").font(.caption).foregroundStyle(tokens.textSecondary)
            default:
                Button {
                    viewModel.requestNotifications()
                } label: {
                    if viewModel.requestingNotifications {
                        HStack(spacing: tokens.metrics.space.two) {
                            ProgressView().controlSize(.small)
                            Text("Requesting…")
                        }
                    } else {
                        Text("Allow notifications")
                    }
                }
                .disabled(viewModel.requestingNotifications)
            }
        }
    }

    private var privacy: some View {
        Group {
            heading("Your data stays yours", "A summary of how Clippy handles what you copy.")
            VStack(alignment: .leading, spacing: 8) {
                Label("History is stored locally on this Mac.", systemImage: "internaldrive")
                Label("Passwords, card numbers and keys are masked, and reveal only while held.", systemImage: "eye.slash")
                Label("Nothing is sent anywhere unless you enable AI or sync.", systemImage: "network.slash")
                Label(viewModel.accessibilityTrusted ? "Accessibility: granted" : "Accessibility: not granted",
                      systemImage: "hand.raised")
                Label(viewModel.suggestionsOn ? "Smart Suggestions: on" : "Smart Suggestions: off", systemImage: "sparkles")
                Label(viewModel.ocrOn ? "Image text search: on" : "Image text search: off", systemImage: "text.viewfinder")
            }
            .foregroundStyle(tokens.textPrimary)
        }
    }
}
