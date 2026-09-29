import SwiftUI

/// Pure countdown math for a time-based one-time password (RFC 6238 style windows).
enum TOTPCountdown {
    /// The period 1Password uses for standard TOTP fields. `op` does not report
    /// the period, so the standard 30 s is assumed.
    static let defaultPeriod = 30

    /// Whole seconds left in the current window, in `1...period`.
    static func secondsRemaining(at date: Date, period: Int = defaultPeriod) -> Int {
        let length = max(1, period)
        let wholeSeconds = Int(floor(date.timeIntervalSince1970))
        let elapsed = (wholeSeconds % length + length) % length
        return length - elapsed
    }

    /// Fraction of the window still left, `0...1` (1 at the start of a window).
    static func fractionRemaining(at date: Date, period: Int = defaultPeriod) -> Double {
        let length = Double(max(1, period))
        let seconds = date.timeIntervalSince1970
        let elapsed = seconds - floor(seconds / length) * length
        return min(1, max(0, 1 - elapsed / length))
    }

    /// Index of the window `date` falls in; a change means the displayed code is stale.
    static func windowIndex(at date: Date, period: Int = defaultPeriod) -> Int {
        Int(floor(date.timeIntervalSince1970 / Double(max(1, period))))
    }

    /// True in the last `warning` seconds, when the ring switches to the warning colour.
    static func isExpiring(at date: Date, period: Int = defaultPeriod, warning: Int = 5) -> Bool {
        secondsRemaining(at: date, period: period) <= warning
    }

    /// Groups a 6 or 8 digit code for reading ("123 456"); other lengths are unchanged.
    static func grouped(_ code: String) -> String {
        guard code.count == 6 || code.count == 8, code.allSatisfy(\.isNumber) else { return code }
        let half = code.count / 2
        return String(code.prefix(half)) + " " + String(code.suffix(code.count - half))
    }
}

/// Circular countdown ring with the remaining seconds in the centre.
struct TOTPCountdownRing: View {
    @Environment(\.clippyTokens) private var tokens
    let date: Date
    var period = TOTPCountdown.defaultPeriod
    var size: CGFloat = 22

    var body: some View {
        let expiring = TOTPCountdown.isExpiring(at: date, period: period)
        let color = expiring ? tokens.warning : tokens.accentText
        ZStack {
            Circle().stroke(tokens.stroke, lineWidth: 2)
            Circle()
                .trim(from: 0, to: TOTPCountdown.fractionRemaining(at: date, period: period))
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(TOTPCountdown.secondsRemaining(at: date, period: period))")
                .font(.system(size: size * 0.42, weight: .medium).monospacedDigit())
                .foregroundStyle(tokens.textPrimary)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code expires in \(TOTPCountdown.secondsRemaining(at: date, period: period)) seconds")
    }
}
