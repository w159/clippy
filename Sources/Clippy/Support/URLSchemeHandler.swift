import AppKit
import Foundation

/// Executes validated `clippy://` URLs. Everything the app owns (panel, palette,
/// settings, paste) is reached through `Actions` closures the integrator sets
/// once at launch; `add` and `get` use the database directly.
///
/// Privacy: every invocation is audited as actor `url-scheme` with the action
/// name and a size, never the query or text. `get` has no return channel, so it
/// only reveals a clip in the panel, and never for sensitive clips.
@MainActor
enum URLSchemeHandler {

    /// App hooks. Unset hooks make the matching action a logged no-op.
    struct Actions {
        var showPanel: () -> Void = {}
        var showPanelSearching: (String) -> Void = { _ in }
        var revealClip: (Int64) -> Void = { _ in }
        var pasteLatest: () -> Void = {}
        var showSettings: () -> Void = {}
        var showPalette: () -> Void = {}
    }

    /// Set by the integrator from `applicationDidFinishLaunching`.
    static var actions = Actions()
    /// Test/host seam: asks the user; returns true when approved.
    static var confirm: @MainActor (ClippyURL.Action) -> Bool = defaultConfirm
    private static var approved: Set<ClippyURL.Action> = []

    /// Entry point for `application(_:open:)`.
    static func handle(_ url: URL) {
        switch ClippyURL.parse(url) {
        case .failure(let error):
            AuditLog.shared.record(actor: "url-scheme", action: "rejected", detail: "\(error)", clipIDs: [])
        case .success(let parsed):
            run(parsed)
        }
    }

    private static func run(_ parsed: ClippyURL) {
        let action = parsed.action
        let decision = ClippyURLPolicy.decision(for: action, allowWrites: AutomationSettings().allowURLSchemeWrites,
                                                approvedThisSession: approved.contains(action))
        if decision == .promptOnce {
            guard confirm(action) else {
                AuditLog.shared.record(actor: "url-scheme", action: action.rawValue, detail: "denied", clipIDs: [])
                return
            }
            approved.insert(action)
        }
        var ids: [Int64] = []
        var detail = "ok"
        switch parsed {
        case .search(let query):
            actions.showPanelSearching(query)
            detail = "queryLength=\(query.count)"
        case .get(let identifier):
            (ids, detail) = reveal(identifier)
        case .add(let text):
            (ids, detail) = add(text)
        case .open: actions.showPanel()
        case .pasteLatest: actions.pasteLatest()
        case .settings: actions.showSettings()
        case .palette: actions.showPalette()
        }
        AuditLog.shared.record(actor: "url-scheme", action: action.rawValue, detail: detail, clipIDs: ids)
    }

    private static func reveal(_ identifier: Int64) -> ([Int64], String) {
        guard let clip = try? ClipDatabase.shared.dbQueue.read({ try Clip.fetchOne($0, key: identifier) }) else {
            return ([], "not-found")
        }
        guard !SensitiveContent.isSensitive(clip: clip) else { return ([], "withheld") }
        actions.revealClip(identifier)
        return ([identifier], "ok")
    }

    private static func add(_ text: String) -> ([Int64], String) {
        do {
            let identifier = try ClipDatabase.shared.insertTextClip(text, sourceAppName: "URL Scheme")
            return ([identifier], "bytes=\(text.utf8.count)")
        } catch {
            return ([], "failed")
        }
    }

    private static func defaultConfirm(_ action: ClippyURL.Action) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow a link to \(action == .add ? "add a clip" : "paste into the frontmost app")?"
        alert.informativeText = "Another app or web page opened a clippy:// link that changes data. "
            + "You can permanently allow this in Settings > Automation."
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
