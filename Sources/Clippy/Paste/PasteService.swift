import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Writes a clip to the pasteboard and simulates Cmd-V into the frontmost
/// app. The keystroke needs Accessibility permission; without it the clip
/// still lands on the clipboard for a manual paste.
///
/// Pasteboard writes are checked (CAP-01): a failed write returns
/// `.failed(...)` and no keystroke is sent. The delivery step waits for the
/// paste target to be key again via an activation notification rather than a
/// fixed sleep (CAP-06). Every final outcome is also sent to `onResult` so the
/// app can show a banner.
@MainActor
final class PasteService {
    private let monitor: ClipboardMonitor
    /// Always the monitor's pasteboard, so own-write accounting measures the
    /// pasteboard that is actually written.
    private var pasteboard: NSPasteboard { monitor.pasteboard }
    private let settings = AppSettings.shared
    private let flavorStore: FlavorStore
    private let media: MediaStore

    /// Sends Cmd+V (`move == false`) or Cmd+Option+V; returns false when the
    /// keystroke could not be posted (no Accessibility permission).
    private let sendKeystroke: (_ move: Bool) -> Bool
    /// Bundle id of the frontmost app.
    private let frontmostBundleID: () -> String?
    private let activationCenter: NotificationCenter
    private let activationTimeout: TimeInterval
    /// Clippy's own bundle id: never a paste target.
    private let ownBundleID: String?

    /// Called on the main thread with the final outcome of every paste.
    var onResult: ((PasteResult) -> Void)?

    /// Minimum gap between the discrete Cmd+V events of a sequence: the time the
    /// target needs to read the pasteboard before it is overwritten. It is a
    /// pacing floor, not a focus wait; focus is verified per step.
    static let interPasteInterval: TimeInterval = 0.15

    static let finderBundleID = "com.apple.finder"

    init(
        monitor: ClipboardMonitor,
        sendKeystroke: @escaping (_ move: Bool) -> Bool = PasteService.postKeystroke,
        frontmostBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        activationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        activationTimeout: TimeInterval = 0.6,
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.monitor = monitor
        self.media = monitor.database.media
        self.flavorStore = FlavorStore(directory: monitor.database.media.sidecarDirectory)
        self.sendKeystroke = sendKeystroke
        self.frontmostBundleID = frontmostBundleID
        self.activationCenter = activationCenter
        self.activationTimeout = activationTimeout
        self.ownBundleID = ownBundleID
    }

    // MARK: - Public API

    /// Writes `clip` to the pasteboard and sends Cmd+V into the target app.
    /// Returns `.failed` immediately when the write fails; otherwise `.pasted`
    /// means the keystroke is scheduled, and the final outcome (which may be
    /// `.copiedOnly`) arrives through `completion` and `onResult`.
    /// Terminals and IDEs get plain text regardless of `asPlainText` (see
    /// `PasteProfiles`); `route` selects the FEAT-19 rule (`PasteProfileDecision`).
    @discardableResult
    func paste(_ clip: Clip, asPlainText: Bool, route: PasteRoute = .paste,
               completion: ((PasteResult) -> Void)? = nil) -> PasteResult {
        let target = pasteTarget()
        let plain = PasteProfileDecision.shouldPastePlain(route: route, bundleID: target, callerAsksPlain: asPlainText)
        if case .failure(let error) = write(clip, asPlainText: plain) {
            return finish(.failed(error), completion)
        }
        deliver(move: false, target: target, completion: completion)
        return .pasted
    }

    /// Pastes several clips one after another as discrete Cmd-V events, in order.
    /// Each lands at the current cursor; Clippy cannot move the target's cursor
    /// between events, so consecutive pastes concatenate where the caret is.
    /// Stops with `.failed(.targetChanged)` if the active app changes mid-way.
    func pasteSequence(_ clips: [Clip], asPlainText: Bool, completion: ((PasteResult) -> Void)? = nil) {
        guard !clips.isEmpty else { _ = finish(.failed(.nothingToPaste), completion); return }
        let target = pasteTarget()
        let plain = PasteProfileDecision.shouldPastePlain(
            route: .multiPasteSequence, bundleID: target, callerAsksPlain: asPlainText)
        func step(_ index: Int) {
            guard index < clips.count else { _ = finish(.pasted, completion); return }
            ActivationWaiter.wait(
                until: { [self] in isTargetActive(target) }, timeout: activationTimeout, center: activationCenter
            ) { [self] ready in
                guard ready else {
                    _ = finish(index == 0 ? .copiedOnly(.targetNotActivated) : .failed(.targetChanged), completion)
                    return
                }
                if case .failure(let error) = write(clips[index], asPlainText: plain) {
                    _ = finish(.failed(error), completion)
                    return
                }
                guard sendKeystroke(false) else { _ = finish(.copiedOnly(.accessibilityNotGranted), completion); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.interPasteInterval) { step(index + 1) }
            }
        }
        step(0)
    }

    /// Joins the text of several clips with `separator` and pastes once.
    /// Image clips are skipped (text-only join).
    @discardableResult
    func pasteCombined(_ clips: [Clip], separator: String = "\n", asPlainText: Bool,
                       completion: ((PasteResult) -> Void)? = nil) -> PasteResult {
        guard let text = ClipMerge.mergedText(clips, separator: separator) else {
            return finish(.failed(.nothingToPaste), completion)
        }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              performWrite({ pasteboard.clearContents(); return pasteboard.writeObjects([item]) })
        else { return finish(.failed(.pasteboardWriteFailed), completion) }
        deliver(move: false, target: pasteTarget(), completion: completion)
        return .pasted
    }

    /// Pastes a file clip, optionally using Cmd+Option+V (Finder "Move Item Here")
    /// instead of Cmd+V. The move keystroke is only sent while Finder is the
    /// active app; anywhere else a plain Cmd+V is sent, since Cmd+Option+V means
    /// something else in other apps. No effect when the clip is not a file kind.
    @discardableResult
    func pasteFile(_ clip: Clip, move: Bool, completion: ((PasteResult) -> Void)? = nil) -> PasteResult {
        guard clip.contentKind == .file else { return finish(.failed(.nothingToPaste), completion) }
        if case .failure(let error) = write(clip, asPlainText: false) {
            return finish(.failed(error), completion)
        }
        deliver(move: move, target: pasteTarget(), completion: completion)
        return .pasted
    }

    /// Writes `clip` to the pasteboard without sending Cmd+V. Used by the
    /// copy-only click mode and the keystroke engine (which types the text
    /// directly instead of pasting).
    @discardableResult
    func copy(_ clip: Clip, asPlainText: Bool) -> Result<Void, PasteError> {
        let result = write(clip, asPlainText: asPlainText)
        if case .failure(let error) = result { onResult?(.failed(error)) }
        return result
    }

    // MARK: - Delivery

    /// The app a paste should land in: the frontmost app, or the last external
    /// app while Clippy itself is frontmost.
    private func pasteTarget() -> String? {
        let front = frontmostBundleID()
        if front != nil, front != ownBundleID { return front }
        return monitor.sourceTracker.lastExternalApp?.bundleID ?? front
    }

    private func isTargetActive(_ target: String?) -> Bool {
        guard let front = frontmostBundleID() else { return false }
        if let target { return front == target }
        return front != ownBundleID
    }

    private func deliver(move: Bool, target: String?, completion: ((PasteResult) -> Void)?) {
        ActivationWaiter.wait(
            until: { [self] in isTargetActive(target) }, timeout: activationTimeout, center: activationCenter
        ) { [self] ready in
            guard ready else { _ = finish(.copiedOnly(.targetNotActivated), completion); return }
            let useMove = move && frontmostBundleID() == Self.finderBundleID
            let sent = sendKeystroke(useMove)
            _ = finish(sent ? .pasted : .copiedOnly(.accessibilityNotGranted), completion)
        }
    }

    private func finish(_ result: PasteResult, _ completion: ((PasteResult) -> Void)?) -> PasteResult {
        onResult?(result)
        completion?(result)
        return result
    }

    // MARK: - Pasteboard writing

    /// With move-to-top off (the default), our own pasteboard write is
    /// invisible to the monitor so history order stays stable; exactly the
    /// change counts this write produced are skipped (CAP-02).
    private func performWrite(_ body: () -> Bool) -> Bool {
        settings.movePastedItemToTop ? body() : monitor.performOwnWrite(body)
    }

    private func write(_ clip: Clip, asPlainText: Bool) -> Result<Void, PasteError> {
        var failure: PasteError?
        let wrote = performWrite {
            switch writeContents(of: clip, asPlainText: asPlainText) {
            case .success: return true
            case .failure(let error): failure = error; return false
            }
        }
        if wrote { return .success(()) }
        return .failure(failure ?? .pasteboardWriteFailed)
    }

    /// Everything is loaded and validated before the pasteboard is cleared, so a
    /// clip whose bytes are gone fails without wiping what the user had copied.
    private func writeContents(of clip: Clip, asPlainText: Bool) -> Result<Void, PasteError> {
        switch clip.contentKind {
        case .image:
            guard let filename = clip.mediaFilename,
                  let data = try? Data(contentsOf: media.url(for: filename))
            else { return .failure(.mediaMissing) }
            let flavors = flavorStore.restore(key: clip.contentKey)?.items.first?.flavors ?? []
            pasteboard.clearContents()
            guard pasteboard.setData(data, forType: .png) else { return .failure(.pasteboardWriteFailed) }
            // Original flavors (JPEG, TIFF, PDF...) captured with the image go
            // back exactly as they were; a derived TIFF is only added when none
            // was preserved, because some AppKit apps only read TIFF.
            var hasTIFF = false
            for flavor in flavors where pasteboard.setData(flavor.data, forType: NSPasteboard.PasteboardType(flavor.type)) {
                hasTIFF = hasTIFF || flavor.type == NSPasteboard.PasteboardType.tiff.rawValue
            }
            if !hasTIFF, let tiff = NSBitmapImageRep(data: data)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
            return .success(())
        case .file:
            guard let fileURL = resolvedFileURL(for: clip) else { return .failure(.fileUnavailable) }
            pasteboard.clearContents()
            return pasteboard.writeObjects([fileURL as NSURL]) ? .success(()) : .failure(.pasteboardWriteFailed)
        case .text:
            let items = textItems(for: clip, asPlainText: asPlainText)
            guard !items.isEmpty else { return .failure(.pasteboardWriteFailed) }
            pasteboard.clearContents()
            return pasteboard.writeObjects(items) ? .success(()) : .failure(.pasteboardWriteFailed)
        }
    }

    /// Pasteboard items for a text clip: the plain string, plus (unless plain
    /// text was asked for) RTF, HTML and every preserved flavor, and one item per
    /// original item for a multi-item copy.
    private func textItems(for clip: Clip, asPlainText: Bool) -> [NSPasteboardItem] {
        let snapshot = asPlainText ? nil : flavorStore.restore(key: clip.contentKey)
        let sources = snapshot?.items ?? [PasteboardSnapshot.Item(string: nil, flavors: [])]
        var items: [NSPasteboardItem] = []
        for (index, source) in sources.enumerated() {
            let item = NSPasteboardItem()
            // Plain text comes from the stored raw String, never round-tripped
            // through attributed strings, so it comes back byte for byte. The
            // clip's text is the whole (joined) copy, so it is used for a single
            // item; a multi-item copy restores each item's own string.
            let string = sources.count > 1 ? (source.string ?? (index == 0 ? clip.contentText : nil)) : clip.contentText
            if let string { item.setString(string, forType: .string) }
            if index == 0, !asPlainText {
                if let rtf = clip.contentRTF { item.setData(rtf, forType: .rtf) }
                if let html = clip.contentHTML { item.setData(html, forType: .html) }
            }
            for flavor in source.flavors {
                item.setData(flavor.data, forType: NSPasteboard.PasteboardType(flavor.type))
            }
            items.append(item)
        }
        return items
    }

    /// Resolves the best available URL for a file clip.
    /// Prefers the original path when the file still exists; falls back to writing
    /// the stored bytes to a temp file named after the original display name.
    private func resolvedFileURL(for clip: Clip) -> URL? {
        // Prefer the live original.
        if let path = clip.filePath {
            let original = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: original.path) {
                return original
            }
        }

        // Fall back to the stored copy: write bytes to a per-session temp file.
        guard let mediaFilename = clip.mediaFilename else { return nil }
        let storedURL = ClipDatabase.shared.media.url(for: mediaFilename)
        guard FileManager.default.fileExists(atPath: storedURL.path),
              let data = try? Data(contentsOf: storedURL, options: .mappedIfSafe)
        else { return nil }

        // Use the clip's display name (original filename) as the temp filename
        // so the receiving app sees a meaningful name rather than the hash.
        let displayName = clip.filePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                       ?? clip.contentText
        let safeName = displayName.isEmpty ? mediaFilename : displayName
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Clippy", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempURL = tempDir.appendingPathComponent(safeName)
        do {
            try data.write(to: tempURL, options: .atomic)
            return tempURL
        } catch {
            return nil
        }
    }

    /// Posts Cmd+V, or Cmd+Option+V when `move` is set. False without
    /// Accessibility permission.
    nonisolated static func postKeystroke(move: Bool) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return false }
        let flags: CGEventFlags = move ? [.maskCommand, .maskAlternate] : .maskCommand
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
