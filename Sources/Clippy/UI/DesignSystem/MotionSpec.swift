import SwiftUI

/// A named duration and curve contract from the redesign motion scale.
enum MotionToken: String, CaseIterable, Identifiable {
    case instant, quick, standard, toastIn, toastOut, masked, panelShow
    var id: String { rawValue }
}

/// Whether an animation is full motion or reduced to opacity-only feedback.
enum MotionBehavior: Equatable {
    case fullMotion
    case opacityOnly
}

/// Motion durations, curves and Reduce Motion fallbacks in one value.
struct MotionSpec {
    /// Duration in seconds for the token; Reduce Motion selects the documented fade.
    func duration(for token: MotionToken, reduceMotion: Bool) -> Double {
        if reduceMotion {
            switch token {
            case .instant, .quick: return 0.08
            case .standard, .masked: return 0.08
            case .toastIn, .toastOut, .panelShow: return 0.15
            }
        }
        switch token {
        case .instant: return 0.08
        case .quick: return 0.15
        case .standard: return 0.22
        case .toastIn: return 0.15
        case .toastOut: return 0.18
        case .masked: return 0.12
        case .panelShow: return 0.10
        }
    }

    /// Selects opacity-only behavior under Reduce Motion, without layout/scale movement.
    func behavior(reduceMotion: Bool) -> MotionBehavior { reduceMotion ? .opacityOnly : .fullMotion }

    /// Animation curve selected by token; reduced motion always uses a short fade.
    func animation(for token: MotionToken, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .easeInOut(duration: duration(for: token, reduceMotion: true)) }
        switch token {
        case .instant, .quick, .panelShow: return .easeOut(duration: duration(for: token, reduceMotion: false))
        case .standard: return .spring(response: 0.28, dampingFraction: 0.86)
        case .toastIn: return .easeOut(duration: 0.15)
        case .toastOut: return .easeInOut(duration: 0.18)
        case .masked: return .linear(duration: 0.12)
        }
    }
}

/// Motion helper that consistently switches to opacity-only under Reduce Motion.
enum ClippyMotion {
    /// Returns the selected animation for a token.
    static func animation(_ token: MotionToken, reduce: Bool) -> Animation {
        MotionSpec().animation(for: token, reduceMotion: reduce)
    }

    /// Returns the selected behavior for testable motion fallback decisions.
    static func behavior(reduce: Bool) -> MotionBehavior { MotionSpec().behavior(reduceMotion: reduce) }
}
