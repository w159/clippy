import Combine
import Foundation

/// PNL-04: "focus the panel's search field" request. AppDelegate posts
/// `Notification.Name.clippyFocusPanelSearch` when the panel is already visible;
/// this observable turns each post into an incremented `token` that the
/// ClipListView owner can observe (`.onReceive(PanelFocusRequest.shared.$token)`
/// or `.onChange(of:)`) to move focus to the search field without rebuilding
/// the view.
@MainActor
final class PanelFocusRequest: ObservableObject {
    static let shared = PanelFocusRequest()

    /// Increments on every request. The initial value (0) is not a request.
    @Published private(set) var token = 0

    private var observer: NSObjectProtocol?

    init(center: NotificationCenter = .default) {
        observer = center.addObserver(forName: .clippyFocusPanelSearch, object: nil, queue: .main) { [weak self] _ in
            // Delivered on the main queue, so the main actor is already current.
            MainActor.assumeIsolated { self?.request() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Ask the search field to take focus.
    func request() {
        token &+= 1
    }
}
