import ApplicationServices
import Carbon.HIToolbox
import os

/// Simulates a human typing text into the frontmost app via CGEvent.
///
/// Layout-independent unicode approach: instead of looking up a virtual key
/// for each character (which only works for keys on the current keyboard layout),
/// we set virtualKey=0 and use keyboardSetUnicodeString(_:_:) to embed the
/// exact UTF-16 code unit directly in the event. The kernel's HID subsystem
/// delivers it to the focused app without any layout translation, so arbitrary
/// Unicode characters (emoji, accented letters, CJK, etc.) type correctly on
/// every keyboard layout.
///
/// A small usleep between characters is mandatory: posting events faster than
/// the target app's event queue drains them causes dropped characters, especially
/// in Electron apps and remote-desktop sessions.
@MainActor
final class KeystrokeService {

    // MARK: - Public API

    /// Handle for one typing run. Cancel it from any thread; the run stops before
    /// the next character.
    final class TypingHandle: Sendable {
        private struct State { var cancelled = false; var finished = false }
        private let state = OSAllocatedUnfairLock(initialState: State())

        var isCancelled: Bool { state.withLock { $0.cancelled } }
        var isFinished: Bool { state.withLock { $0.finished } }

        func cancel() { state.withLock { $0.cancelled = true } }
        fileprivate func finish() { state.withLock { $0.finished = true } }
    }

    private var currentHandle: TypingHandle?

    /// Stops the run in progress, if any.
    func cancelTyping() {
        currentHandle?.cancel()
    }

    /// Types `text` into the frontmost app one character at a time. A new run
    /// cancels one still in progress so the two never interleave. Returns a
    /// handle to cancel this run; the handle is already finished when
    /// Accessibility permission has not been granted (nothing is typed).
    /// Runs on a background thread; never blocks the main thread.
    @discardableResult
    func type(_ text: String) -> TypingHandle {
        let handle = TypingHandle()
        guard AXIsProcessTrusted() else { handle.finish(); return handle }
        let previous = currentHandle
        currentHandle = handle
        previous?.cancel()
        let delay = AppSettings.shared.keystrokeSpeed.perCharDelayMicros

        DispatchQueue.global(qos: .userInitiated).async {
            // Created on the worker: CGEventSource is not Sendable.
            let source = CGEventSource(stateID: .combinedSessionState)
            // Iterate by Character (extended grapheme cluster), NOT unicodeScalars.
            // A scalar loop splits combining marks and emoji skin-tone modifiers
            // into separate events, so "cafe\u{0301}" or a skin-tone emoji types
            // mangled. Iterating Characters keeps each user-perceived glyph intact
            // and encodes the whole cluster's UTF-16 in a single key event.
            defer { handle.finish() }
            for character in text {
                if handle.isCancelled { break }
                if character == "\n" {
                    // Newline: post a real Return key so apps that intercept
                    // the Return key (terminal emulators, chat apps) receive it.
                    Self.postKey(CGKeyCode(kVK_Return), source: source)
                } else if character == "\t" {
                    // Tab: post a real Tab key for form navigation.
                    Self.postKey(CGKeyCode(kVK_Tab), source: source)
                } else {
                    // All other characters: encode the cluster as UTF-16 and embed
                    // directly in the event via keyboardSetUnicodeString so it
                    // arrives unmodified regardless of keyboard layout.
                    var utf16: [UniChar] = Array(String(character).utf16)
                    let len = utf16.count
                    if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                       let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                        // Zero modifier flags: .combinedSessionState folds in live
                        // hardware modifiers, so a still-held Cmd/Shift (from the
                        // trigger hotkey) would turn typed characters into shortcuts.
                        keyDown.flags = []
                        keyUp.flags = []
                        keyDown.keyboardSetUnicodeString(stringLength: len, unicodeString: &utf16)
                        keyUp.keyboardSetUnicodeString(stringLength: len, unicodeString: &utf16)
                        keyDown.post(tap: .cghidEventTap)
                        keyUp.post(tap: .cghidEventTap)
                    }
                }
                usleep(delay)
            }
        }
        return handle
    }

    // MARK: - Private helpers

    private nonisolated static func postKey(_ keyCode: CGKeyCode, source: CGEventSource?) {
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        // Same reason as the unicode path: do not leak live modifier flags into
        // the synthesized Return/Tab keys.
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
