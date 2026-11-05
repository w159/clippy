import SwiftUI

/// Records the laid-out frame of tagged views for the UI harness, so a test can measure the real view hierarchy
/// instead of echoing constants. Only active when `CLIPPY_UI_HARNESS=1`; in a normal launch the modifier is a no-op.
@MainActor
final class LayoutProbe {
    static let shared = LayoutProbe()
    /// Set by CI for the UI harness only.
    nonisolated static let isEnabled = ProcessInfo.processInfo.environment["CLIPPY_UI_HARNESS"] == "1"

    private(set) var frames: [String: CGRect] = [:]

    func record(_ id: String, _ frame: CGRect) { frames[id] = frame }

    func reset() { frames = [:] }
}

private struct LayoutProbeModifier: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        if LayoutProbe.isEnabled {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                LayoutProbe.shared.record(id, frame)
            }
        } else {
            content
        }
    }
}

extension View {
    /// Tags this view so the UI harness can read its size back (`LayoutProbe.shared.frames[id]`).
    func layoutProbe(_ id: String) -> some View { modifier(LayoutProbeModifier(id: id)) }
}
