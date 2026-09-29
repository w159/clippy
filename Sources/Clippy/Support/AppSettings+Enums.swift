import Foundation

// Panel/keystroke option enums that AppSettings stores. Split from AppSettings.swift; unchanged.

enum PanelPositionMode: String, CaseIterable, Identifiable {
    case caret
    case mouse
    case lastPosition
    case screenCenter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .caret: return "At text cursor"
        case .mouse: return "At mouse pointer"
        case .lastPosition: return "Last position"
        case .screenCenter: return "Screen center"
        }
    }
}

/// Where the panel sits in the macOS window stack.
/// alwaysOnTop: .statusBar level + isFloatingPanel (current default, floats above every app window).
/// aboveNormalWindows: .floating level + isFloatingPanel (floats above normal windows, below status bar).
/// normalOrder: .normal level, not floating (respects app z-order, stays behind full-screen chrome).
enum PanelFloatLevel: String, CaseIterable, Identifiable {
    case alwaysOnTop
    case aboveNormalWindows
    case normalOrder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .alwaysOnTop: return "Always on top"
        case .aboveNormalWindows: return "Above normal windows"
        case .normalOrder: return "Normal window order"
        }
    }
}

/// Per-character pacing for the "send keystrokes" action. Faster feels instant
/// but can drop characters in slow or remote targets; deliberate is the safest.
enum KeystrokeSpeed: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case deliberate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .deliberate: return "Deliberate"
        }
    }

    var detail: String {
        switch self {
        case .fast: return "Near-instant (~2ms/char). May drop characters in remote or sluggish apps."
        case .balanced: return "Reliable for everyday use (~6ms/char)."
        case .deliberate: return "Visibly typed (~20ms/char). Maximum compatibility."
        }
    }

    /// Delay between characters in microseconds, for usleep between key events.
    var perCharDelayMicros: useconds_t {
        switch self {
        case .fast: return 2_000
        case .balanced: return 6_000
        case .deliberate: return 20_000
        }
    }
}
