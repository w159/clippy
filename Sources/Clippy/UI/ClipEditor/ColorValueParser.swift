import Foundation
import SwiftUI

/// Color literals found in clip text, for the editor's swatch strip (FEAT-14).
/// Recognizes `#RGB`, `#RRGGBB`, `#RRGGBBAA`, `rgb()/rgba()` and `hsl()/hsla()`.
struct ColorValue: Equatable {
    /// The literal as written.
    var literal: String
    var red: Double, green: Double, blue: Double, alpha: Double

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    /// Canonical `#RRGGBB` (`#RRGGBBAA` when translucent).
    var hex: String {
        func byte(_ value: Double) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
        let base = String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
        return alpha < 1 ? base + String(format: "%02X", byte(alpha)) : base
    }
}

enum ColorValueParser {
    private static let pattern = #"#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})\b|(?:rgba?|hsla?)\(\s*[^()\n]{3,60}\)"#
    private static let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])

    /// Parses one literal (surrounding whitespace ignored), nil when invalid.
    static func parse(_ text: String) -> ColorValue? {
        let literal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = literal.lowercased()
        if lower.hasPrefix("#") { return parseHex(literal) }
        if lower.hasPrefix("rgb") { return parseRGB(literal) }
        if lower.hasPrefix("hsl") { return parseHSL(literal) }
        return nil
    }

    /// Up to `limit` distinct color literals in document order. Text longer
    /// than `maxScan` UTF-16 units is not scanned.
    static func find(in text: String, limit: Int = 12, maxScan: Int = 100_000) -> [ColorValue] {
        let nsText = text as NSString
        guard nsText.length > 0, nsText.length <= maxScan, let regex else { return [] }
        var result: [ColorValue] = []
        var seen = Set<String>()
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { match, _, stop in
            guard let match, let value = parse(nsText.substring(with: match.range)) else { return }
            if seen.insert(value.hex).inserted { result.append(value) }
            if result.count >= limit { stop.pointee = true }
        }
        return result
    }

    private static func parseHex(_ literal: String) -> ColorValue? {
        let digits = String(literal.dropFirst())
        guard [3, 6, 8].contains(digits.count), let value = UInt64(digits, radix: 16) else { return nil }
        func part(_ shift: UInt64, _ mask: UInt64, _ max: Double) -> Double { Double((value >> shift) & mask) / max }
        switch digits.count {
        case 3: return ColorValue(literal: literal, red: part(8, 0xF, 15), green: part(4, 0xF, 15), blue: part(0, 0xF, 15), alpha: 1)
        case 6: return ColorValue(literal: literal, red: part(16, 0xFF, 255), green: part(8, 0xFF, 255), blue: part(0, 0xFF, 255), alpha: 1)
        default: return ColorValue(literal: literal, red: part(24, 0xFF, 255), green: part(16, 0xFF, 255), blue: part(8, 0xFF, 255), alpha: part(0, 0xFF, 255))
        }
    }

    /// Numbers inside the parentheses; `%` scales to 0...1 (or 0...`percentBase`).
    private static func arguments(_ literal: String) -> [(value: Double, isPercent: Bool)]? {
        guard let open = literal.firstIndex(of: "("), literal.hasSuffix(")") else { return nil }
        let inner = literal[literal.index(after: open)..<literal.index(before: literal.endIndex)]
        let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
        var out: [(Double, Bool)] = []
        for part in parts {
            let percent = part.hasSuffix("%")
            let numeric = part.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "deg", with: "")
            guard let value = Double(numeric) else { return nil }
            out.append((value, percent))
        }
        return (3...4).contains(out.count) ? out : nil
    }

    private static func alpha(_ args: [(value: Double, isPercent: Bool)]) -> Double {
        guard args.count == 4 else { return 1 }
        return min(1, max(0, args[3].isPercent ? args[3].value / 100 : args[3].value))
    }

    private static func parseRGB(_ literal: String) -> ColorValue? {
        guard let args = arguments(literal) else { return nil }
        func channel(_ arg: (value: Double, isPercent: Bool)) -> Double {
            min(1, max(0, arg.isPercent ? arg.value / 100 : arg.value / 255))
        }
        return ColorValue(literal: literal, red: channel(args[0]), green: channel(args[1]), blue: channel(args[2]),
                          alpha: alpha(args))
    }

    private static func parseHSL(_ literal: String) -> ColorValue? {
        guard let args = arguments(literal) else { return nil }
        let hue = (args[0].value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let sat = min(1, max(0, args[1].value / 100))
        let light = min(1, max(0, args[2].value / 100))
        let chroma = (1 - abs(2 * light - 1)) * sat
        let scaledHue = hue * 6
        let mid = chroma * (1 - abs(scaledHue.truncatingRemainder(dividingBy: 2) - 1))
        let (redBase, greenBase, blueBase): (Double, Double, Double)
        switch Int(scaledHue) {
        case 0: (redBase, greenBase, blueBase) = (chroma, mid, 0)
        case 1: (redBase, greenBase, blueBase) = (mid, chroma, 0)
        case 2: (redBase, greenBase, blueBase) = (0, chroma, mid)
        case 3: (redBase, greenBase, blueBase) = (0, mid, chroma)
        case 4: (redBase, greenBase, blueBase) = (mid, 0, chroma)
        default: (redBase, greenBase, blueBase) = (chroma, 0, mid)
        }
        let offset = light - chroma / 2
        return ColorValue(literal: literal, red: redBase + offset, green: greenBase + offset, blue: blueBase + offset, alpha: alpha(args))
    }
}
