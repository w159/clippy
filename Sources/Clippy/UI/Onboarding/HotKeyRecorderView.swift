import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Only one recorder may capture keys at a time; a second click hands capture over.
@MainActor
private final class ActiveHotKeyRecorder: ObservableObject {
    static let shared = ActiveHotKeyRecorder()
    @Published var action: HotKeyAction?
}

/// Reusable recorder for one `HotKeyAction`. Click the field, press a chord;
/// Escape cancels, Delete clears the binding. Shows conflicts and registration
/// errors from `HotKeyCenter`. Embed in Settings or onboarding.
struct HotKeyRecorderView: View {
    /// The action being bound.
    let action: HotKeyAction
    @ObservedObject private var center = HotKeyCenter.shared
    @Environment(\.clippyTokens) private var tokens
    @ObservedObject private var recorder = ActiveHotKeyRecorder.shared
    @State private var isHovered = false
    @State private var warning: String?
    @FocusState private var fieldFocused: Bool

    /// Creates a recorder for `action`.
    init(action: HotKeyAction) { self.action = action }

    private var isRecording: Bool { recorder.action == action }

    private func setRecording(_ on: Bool) {
        if on { recorder.action = action } else if recorder.action == action { recorder.action = nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(action.title).foregroundStyle(tokens.textPrimary)
                Spacer(minLength: 8)
                Button(action: { setRecording(!isRecording); warning = nil }, label: { fieldLabel })
                    .buttonStyle(HotKeyRecorderButtonStyle(isRecording: isRecording, isHovered: isHovered,
                                                          isFocused: fieldFocused, tokens: tokens))
                    .focused($fieldFocused)
                    .onHover { isHovered = $0 }
                    .accessibilityLabel("\(action.title) shortcut")
                    .accessibilityValue(center.chords[action]?.spokenString ?? "Not set")
                    .accessibilityHint(isRecording ? "Press the new key combination" : "Activate to record a new shortcut")
                // Reset only shows once the chord differs from its default (Height/Discord pattern).
                if !(center.chords[action] == action.defaultChord && center.errors[action] == nil) {
                    Button("Reset") { center.resetChord(for: action); warning = nil }
                        .controlSize(.small)
                }
            }
            .background(RecorderKeyCatcher(isActive: isRecording, onChord: commit, onCancel: { setRecording(false) },
                                           onClear: { center.setChord(nil, for: action); setRecording(false) }))
            // A recorder must never keep swallowing keys once it is off screen or the app is in the background.
            .onDisappear { setRecording(false) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                setRecording(false)
            }
            if let message = warning ?? center.errors[action] {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(tokens.warning)
            }
        }
    }

    private var fieldLabel: some View {
        Text(isRecording ? "Press shortcut\u{2026}" : (center.chords[action]?.displayString ?? "Not set"))
            .font(.system(size: 12, weight: .medium, design: .rounded).monospaced())
            .foregroundStyle(isRecording ? tokens.accentText : tokens.textPrimary)
            .lineLimit(1)
            .frame(minWidth: 96)
            .padding(.horizontal, 8).padding(.vertical, 3)
    }

    private func commit(_ chord: HotKeyChord) {
        if let message = center.conflictMessage(for: chord, action: action) {
            warning = message
            // Conflicting or invalid chords are refused; the field stays armed.
            return
        }
        setRecording(false)
        if !center.setChord(chord, for: action) { warning = center.errors[action] }
    }
}

/// Distinct hover, pressed, focus and recording treatments for the key field.
private struct HotKeyRecorderButtonStyle: ButtonStyle {
    let isRecording: Bool
    let isHovered: Bool
    let isFocused: Bool
    let tokens: ClippyTokens

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        return configuration.label
            .background(shape.fill(configuration.isPressed ? tokens.selection : (isHovered ? tokens.surfaceElevated : tokens.surfaceInset)))
            .overlay(shape.stroke(isFocused || isRecording ? tokens.focusRing : tokens.stroke,
                                  lineWidth: isFocused || isRecording ? 2 : 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .contentShape(shape)
    }
}

/// Invisible view capturing key presses via a local monitor while active.
private struct RecorderKeyCatcher: NSViewRepresentable {
    let isActive: Bool
    let onChord: (HotKeyChord) -> Void
    let onCancel: () -> Void
    let onClear: () -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.remove()
        guard isActive else { return }
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape: onCancel()
            case kVK_Delete, kVK_ForwardDelete: onClear()
            default:
                let mods = HotKeyChord.carbonModifiers(from: event.modifierFlags)
                onChord(HotKeyChord(keyCode: UInt32(event.keyCode), modifiers: mods))
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }

    final class Coordinator {
        var monitor: Any?
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

#Preview("Hotkey recorder") {
    VStack { ForEach(HotKeyAction.allCases, id: \.self) { HotKeyRecorderView(action: $0) } }
        .padding(20).frame(width: 460)
}
