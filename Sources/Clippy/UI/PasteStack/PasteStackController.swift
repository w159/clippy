import AppKit
import Foundation

extension Notification.Name {
    /// Posted (main thread, no payload) by the monitor after a NEW clip was stored
    /// (text, image or file; not for an append-merge). The paste stack listens.
    static let clippyPasteStackCaptured = Notification.Name("ClippyPasteStackCaptured")
    /// Post to paste the next stack item into the frontmost app (bind a chord to it).
    static let clippyPasteStackPasteNext = Notification.Name("ClippyPasteStackPasteNext")
}

/// Wires the paste stack to hotkey notifications, capture, and paste delivery (FEAT-06).
@MainActor
final class PasteStackController {
    /// The app-wide controller.
    static let shared = PasteStackController()

    let stack: PasteStack
    private let hud = PasteStackHUD()
    private var observers: [NSObjectProtocol] = []
    private var isPasting = false
    private var paste: ((Clip, @escaping (PasteResult) -> Void) -> Void)?
    private var newestClip: (() -> Clip?)?

    init(stack: PasteStack = .shared) {
        self.stack = stack
    }

    /// Launch hook: call once after the database and paste service exist, e.g.
    /// `PasteStackController.launch(database: database, pasteService: pasteService)`.
    static func launch(database: ClipDatabase, pasteService: PasteService) {
        shared.start(
            newestClip: { try? database.recentClips(limit: 1).first },
            paste: { clip, done in
                pasteService.paste(clip, asPlainText: AppSettings.shared.pastePlainTextByDefault,
                                   route: .pasteStack, completion: done)
            })
    }

    /// Terminate hook: drops observers and empties the in-memory stack.
    static func terminate() {
        shared.stop()
    }

    /// Starts observing (idempotent). Injectable closures keep this testable.
    func start(newestClip: @escaping () -> Clip?, paste: @escaping (Clip, @escaping (PasteResult) -> Void) -> Void) {
        stop()
        self.newestClip = newestClip
        self.paste = paste
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .clippyPasteStackToggle, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.toggleCollecting() }
            },
            center.addObserver(forName: .clippyPasteStackCaptured, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.captured() }
            },
            center.addObserver(forName: .clippyPasteStackPasteNext, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pasteNext() }
            }
        ]
    }

    /// Removes observers and clears the stack.
    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        stack.isCollecting = false
        stack.clear()
    }

    /// Toggles collect mode and shows the "Stack: N" toast.
    func toggleCollecting() {
        stack.isCollecting.toggle()
        hud.show(stack.isCollecting ? "Stack: \(stack.count) (collecting)" : "Stack paused: \(stack.count)")
    }

    /// Adds `clip` to the stack; toast shows the new count or the refusal reason.
    @discardableResult
    func add(_ clip: Clip) -> Bool {
        switch stack.add(clip) {
        case .success(let count):
            hud.show("Stack: \(count)")
            return true
        case .failure(let refusal):
            hud.show(refusal.message, severity: .warning)
            return false
        }
    }

    /// Capture hook: while collecting, the newest stored clip joins the stack.
    private func captured() {
        guard stack.isCollecting, let clip = newestClip?() else { return }
        add(clip)
    }

    /// Pastes the next item into the frontmost app; the item is consumed unless
    /// the write failed. Ignored while a previous paste is still delivering.
    func pasteNext() {
        guard !isPasting, let item = stack.upcoming, let paste else {
            if stack.upcoming == nil { hud.show("Stack is empty", severity: .warning) }
            return
        }
        isPasting = true
        paste(item.clip) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPasting = false
                if case .failed = result { return }
                self.stack.remove(id: item.id)
                self.hud.show("Stack: \(self.stack.count)")
            }
        }
    }
}
