import Foundation
import Observation

/// What an external trigger (a `clippy://` link) asks the open panel to do.
/// The panel rebuilds its view on show and the link handler cannot reach the
/// view's state, so the request waits here until the panel takes it. Without
/// this the link's arguments (the search text, the clip id, "palette") were
/// dropped and the panel just opened.
enum PanelLaunchAction: Equatable {
    case search(String)
    case reveal(Int64)
    case palette
}

/// Pure queue behind `PanelLaunchRequest`: one pending action that goes stale.
struct PanelLaunchQueue {
    /// A request older than this belonged to a panel that never opened (locked).
    static let lifetime: TimeInterval = 10

    private var pending: (action: PanelLaunchAction, at: Date)?

    mutating func post(_ action: PanelLaunchAction, now: Date = Date()) {
        pending = (action, now)
    }

    /// Returns the pending action once, or nil when none is waiting or it expired.
    mutating func take(now: Date = Date()) -> PanelLaunchAction? {
        defer { pending = nil }
        guard let pending, now.timeIntervalSince(pending.at) <= Self.lifetime else { return nil }
        return pending.action
    }
}

@MainActor
@Observable
final class PanelLaunchRequest {
    static let shared = PanelLaunchRequest()

    /// Increments on every post so the panel's `onChange` fires.
    private(set) var token = 0
    @ObservationIgnored private var queue = PanelLaunchQueue()

    func post(_ action: PanelLaunchAction) {
        queue.post(action)
        token &+= 1
    }

    func take() -> PanelLaunchAction? { queue.take() }
}

/// What "Open Clippy" does given the panel's state.
enum PanelOpenPolicy {
    enum Step: Equatable { case show, focusSearch, makeKeyAndFocusSearch }

    static func step(isVisible: Bool, isKey: Bool) -> Step {
        guard isVisible else { return .show }
        return isKey ? .focusSearch : .makeKeyAndFocusSearch
    }
}
