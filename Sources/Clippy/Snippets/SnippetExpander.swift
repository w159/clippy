import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Global text expansion via a listen-only CGEventTap on keyDown.
///
/// Guards: Accessibility trusted, global toggle on, AppLock unlocked, secure input off, frontmost app not
/// excluded. Typed characters live only in the in-memory `TriggerMatcher` buffer and are never logged.
@MainActor
final class SnippetExpander {
    /// Shared instance.
    static let shared = SnippetExpander()

    /// Supplies values for `{fill:Label}` fields (main thread); return nil to cancel. Set by the integrator
    /// (present `SnippetFillView`). When nil, fields expand empty.
    var fillProvider: ((_ snippet: Snippet, _ labels: [String], _ done: @escaping ([String: String]?) -> Void) -> Void)?
    /// Supplies the clipboard text for `{clipboard}`; set by the integrator (default: empty).
    var clipboardProvider: () -> String = { "" }

    private let store: SnippetStore
    private let keystrokes = KeystrokeService()
    private var matcher = TriggerMatcher()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var injecting = false

    /// Creates an expander over `store`.
    init(store: SnippetStore = .shared) { self.store = store }

    /// True while the tap is installed.
    var isRunning: Bool { tap != nil }

    /// Installs the tap when expansion is enabled and Accessibility is granted; safe to call repeatedly.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard SnippetSettings.isExpansionEnabled, CaretLocator.isTrusted else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let expander = Unmanaged<SnippetExpander>.fromOpaque(refcon).takeUnretainedValue()
            expander.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = runLoopSource
        reloadSnippets()
        return true
    }

    /// Removes the tap and clears the typed buffer.
    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        source = nil
        matcher.reset()
    }

    /// Re-reads snippets and settings into the matcher; call after editing snippets or settings.
    func reloadSnippets() {
        matcher = TriggerMatcher(snippets: store.snippets, mode: SnippetSettings.triggerMode,
                                 caseSensitive: SnippetSettings.isCaseSensitive)
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            matcher.reset()
            return
        }
        guard type == .keyDown, !injecting else { return }
        guard isActive else { matcher.reset(); return }
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) { matcher.reset(); return }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if keyCode == kVK_Delete { matcher.deleteBackward(); return }
        guard let character = Self.character(of: event, keyCode: keyCode) else { matcher.reset(); return }
        guard let match = matcher.feed(character) else { return }
        DispatchQueue.main.async { [weak self] in self?.expand(match) }
    }

    /// The single typed character of a key event, or nil for navigation/function/multi-character keys.
    private static func character(of event: CGEvent, keyCode: Int) -> Character? {
        switch keyCode {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "\n"
        case kVK_Tab: return "\t"
        case kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp,
             kVK_PageDown, kVK_ForwardDelete: return nil
        default: break
        }
        var length = 0
        var units = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &units)
        guard length > 0 else { return nil }
        let text = String(utf16CodeUnits: units, count: length)
        guard text.count == 1, let char = text.first, !char.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return char
    }

    /// True when every safety condition allows expansion right now.
    private var isActive: Bool {
        guard SnippetSettings.isExpansionEnabled, CaretLocator.isTrusted, !IsSecureEventInputEnabled() else { return false }
        if MainActor.assumeIsolated({ AppLock.shared.isLocked }) { return false }
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let bundle, SnippetSettings.excludedBundleIDs.contains(bundle) { return false }
        return true
    }

    // MARK: - Insertion

    private func expand(_ match: TriggerMatcher.Match) {
        guard !MainActor.assumeIsolated({ AppLock.shared.isLocked }) else { return }
        var context = baseContext()
        let labels = SnippetTemplate.fillFields(in: match.snippet.body)
        guard !labels.isEmpty, let provider = fillProvider else { finish(match, context); return }
        provider(match.snippet, labels) { [weak self] values in
            guard let self, let values else { return }
            context.fillValues = values
            self.finish(match, context)
        }
    }

    private func baseContext() -> SnippetContext {
        var context = SnippetContext()
        context.clipboard = clipboardProvider()
        context.allowEnvironment = SnippetSettings.allowEnvironmentPlaceholder
        return context
    }

    private func finish(_ match: TriggerMatcher.Match, _ context: SnippetContext) {
        let expansion = SnippetTemplate.expand(match.snippet.body, context: context)
        injecting = true
        let deleteCount = match.deleteCount
        let cursorBack = expansion.cursorOffsetFromEnd ?? 0
        Task { [weak self] in
            // Key posting sleeps between events, so it runs on a worker queue; typing
            // itself starts from the main actor (`KeystrokeService` is main-actor).
            await Self.onWorker {
                let source = CGEventSource(stateID: .combinedSessionState)
                for _ in 0..<deleteCount { Self.press(CGKeyCode(kVK_Delete), source: source) }
            }
            guard let self else { return }
            let handle = self.keystrokes.type(expansion.text)
            await Self.onWorker {
                while !handle.isFinished { usleep(2_000) }
                let source = CGEventSource(stateID: .combinedSessionState)
                for _ in 0..<cursorBack { Self.press(CGKeyCode(kVK_LeftArrow), source: source) }
            }
            self.injecting = false
            self.matcher.reset()
            self.store.recordUse(id: match.snippet.id)
        }
    }

    /// Runs blocking key-posting work off the main actor.
    private nonisolated static func onWorker(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                work()
                continuation.resume()
            }
        }
    }

    private nonisolated static func press(_ key: CGKeyCode, source: CGEventSource?) {
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
        usleep(4_000)
    }
}
