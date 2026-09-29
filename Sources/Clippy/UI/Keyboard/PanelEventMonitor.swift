import AppKit

/// Local NSEvent monitors for the panel: right-clicks (so a right-clicked card
/// can be selected before its context menu builds, KEY-07) and modifier changes
/// (so quick-paste badges show only while the chord is held, FEAT-03).
final class PanelEventMonitor {
    private var tokens: [Any] = []

    /// Installs the monitors, replacing any previous ones. Handlers run on the main thread.
    func start(onRightMouseDown: @escaping () -> Void, onFlagsChanged: @escaping (NSEvent.ModifierFlags) -> Void) {
        stop()
        if let token = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: { event in
            onRightMouseDown()
            return event
        }) { tokens.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            onFlagsChanged(event.modifierFlags)
            return event
        }) { tokens.append(token) }
    }

    func stop() {
        tokens.forEach(NSEvent.removeMonitor)
        tokens.removeAll()
    }

    deinit { stop() }
}
