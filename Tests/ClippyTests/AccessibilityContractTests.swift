import AppKit
import SwiftUI
import XCTest
@testable import Clippy

/// Pins the resolved contrast floors that Increase Contrast and standard contrast promise.
final class ResolvedContrastFloorTests: XCTestCase {
    private func resolved(_ preset: ThemePreset, dark: Bool, contrast: ColorSchemeContrast) -> ClippyTokens {
        var source = preset.fixedTokens ?? Theme.customSeed
        source.isDark = dark
        return ClippyTokens.resolve(from: source, contrast: contrast)
    }

    private func rgba(_ color: Color, _ tokens: ClippyTokens) -> RGBA {
        RGBA(color: color, isDark: tokens.scheme == .dark) ?? .black
    }

    private func surfaces(_ tokens: ClippyTokens) -> [(String, RGBA)] {
        let named: [(String, Color)] = [
            ("surface", tokens.surface), ("surfaceElevated", tokens.surfaceElevated),
            ("surfaceInset", tokens.surfaceInset), ("surfaceSidebar", tokens.surfaceSidebar),
            ("selection", tokens.selection),
        ]
        return named.map { ($0.0, rgba($0.1, tokens)) }
    }

    private func worst(_ foreground: Color, _ tokens: ClippyTokens, on names: Set<String>? = nil) -> Double {
        let fg = rgba(foreground, tokens)
        let backgrounds = surfaces(tokens).filter { names?.contains($0.0) ?? true }.map(\.1)
        return ContrastAudit.worstRatio(fg, on: backgrounds)
    }

    func testIncreasedContrastStrokesReach4_5AndTextReaches7() {
        for preset in ThemePreset.allCases {
            for dark in [false, true] {
                let tokens = resolved(preset, dark: dark, contrast: .increased)
                let label = "\(preset.rawValue) \(dark ? "dark" : "light")"
                let base = tokens.strokeOnlySurfaces
                XCTAssertGreaterThanOrEqual(worst(tokens.stroke, tokens, on: base), 4.5, "stroke \(label)")
                XCTAssertGreaterThanOrEqual(worst(tokens.strokeStrong, tokens, on: base), 4.5, "strokeStrong \(label)")
                XCTAssertGreaterThanOrEqual(worst(tokens.textPrimary, tokens), ContrastAudit.enhancedText, "textPrimary \(label)")
                XCTAssertGreaterThanOrEqual(worst(tokens.textSecondary, tokens), ContrastAudit.enhancedText, "textSecondary \(label)")
            }
        }
    }

    func testStandardContrastStrokesReach3AndTextReaches4_5() {
        for preset in ThemePreset.allCases {
            for dark in [false, true] {
                let tokens = resolved(preset, dark: dark, contrast: .standard)
                let label = "\(preset.rawValue) \(dark ? "dark" : "light")"
                let base = tokens.strokeOnlySurfaces
                XCTAssertGreaterThanOrEqual(worst(tokens.stroke, tokens, on: base), ContrastAudit.nonTextMinimum, "stroke \(label)")
                XCTAssertGreaterThanOrEqual(worst(tokens.strokeStrong, tokens, on: base), ContrastAudit.nonTextMinimum, "strokeStrong \(label)")
                XCTAssertGreaterThanOrEqual(worst(tokens.textPrimary, tokens), ContrastAudit.textMinimum, "textPrimary \(label)")
                XCTAssertGreaterThanOrEqual(worst(tokens.textSecondary, tokens), ContrastAudit.textMinimum, "textSecondary \(label)")
            }
        }
    }
}

/// Source scans that keep two accessibility gaps closed: legacy `cardBorder` strokes that bypass the
/// resolver's contrast floor, and icon-only buttons that VoiceOver would read as an unnamed control.
final class AccessibilitySourceScanTests: XCTestCase {
    /// Files allowed to stroke `cardBorder` directly, keyed by path under `Sources/Clippy/UI`.
    private static let cardBorderAllowlist: [String: String] = [
        "Settings/AppearanceSettingsTab.swift": "ThemeSwatchStrip previews the active theme's own border color",
    ]

    private var uiRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Clippy/UI")
    }

    private func swiftFiles() -> [(relative: String, source: String)] {
        let root = uiRoot
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            files.append((relative, Self.blankingLineComments(text)))
        }
        return files.sorted { $0.0 < $1.0 }
    }

    func testScanFindsSourceFiles() {
        XCTAssertGreaterThan(swiftFiles().count, 50, "UI source tree not found from #filePath")
    }

    func testNoLegacyCardBorderStrokesOutsideDesignSystem() {
        var violations: [String] = []
        for (relative, source) in swiftFiles() where !relative.hasPrefix("DesignSystem/") {
            if Self.cardBorderAllowlist[relative] != nil { continue }
            let lines = source.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("cardBorder") {
                let window = line + (index > 0 ? lines[index - 1] : "")
                if window.contains("stroke(") || window.contains("strokeBorder(") { violations.append("\(relative):\(index + 1)") }
            }
        }
        XCTAssertTrue(violations.isEmpty, "Stroke with clippyTokens.stroke/strokeStrong, not ThemeTokens.cardBorder: \(violations)")
    }

    func testIconOnlyButtonsAndMenusCarryAccessibilityLabel() {
        var violations: [String] = []
        for (relative, source) in swiftFiles() {
            for line in Self.unlabeledIconOnlyControls(in: source) { violations.append("\(relative):\(line)") }
        }
        XCTAssertTrue(violations.isEmpty, "Icon-only Button/Menu without .accessibilityLabel: \(violations)")
    }

    func testScannerFlagsAnUnlabeledIconButtonAndAcceptsALabeledOne() {
        let bad = "Button { go() } label: { Image(systemName: \"xmark\") }\n    .help(\"Close\")"
        let good = "Button { go() } label: { Image(systemName: \"xmark\") }\n    .help(\"Close\")\n    .accessibilityLabel(\"Close\")"
        let titled = "Button { go() } label: { Label(\"Close\", systemImage: \"xmark\") }"
        XCTAssertEqual(Self.unlabeledIconOnlyControls(in: bad), [1])
        XCTAssertTrue(Self.unlabeledIconOnlyControls(in: good).isEmpty)
        XCTAssertTrue(Self.unlabeledIconOnlyControls(in: titled).isEmpty)
    }

    // MARK: - Scanner

    /// Replaces `//` comments with spaces (string literals untouched) so offsets and line numbers hold.
    static func blankingLineComments(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var index = 0
        var inString = false
        while index < chars.count {
            let char = chars[index]
            if inString {
                out.append(char)
                if char == "\\", index + 1 < chars.count { out.append(chars[index + 1]); index += 2; continue }
                if char == "\"" || char == "\n" { inString = false }
                index += 1
                continue
            }
            if char == "\"" { inString = true; out.append(char); index += 1; continue }
            if char == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" { out.append(" "); index += 1 }
                continue
            }
            out.append(char)
            index += 1
        }
        return String(out)
    }

    private static func isWord(_ char: Character) -> Bool { char.isLetter || char.isNumber || char == "_" }

    private static func skipWhitespace(_ chars: [Character], _ start: Int) -> Int {
        var index = start
        while index < chars.count, chars[index].isWhitespace { index += 1 }
        return index
    }

    /// Index just past the bracket that closes the one at `start`, skipping string literals.
    private static func balancedEnd(_ chars: [Character], _ start: Int, open: Character, close: Character) -> Int? {
        var depth = 0
        var index = start
        var inString = false
        while index < chars.count {
            let char = chars[index]
            if inString {
                if char == "\\" { index += 2; continue }
                if char == "\"" { inString = false }
            } else if char == "\"" {
                inString = true
            } else if char == open {
                depth += 1
            } else if char == close {
                depth -= 1
                if depth == 0 { return index + 1 }
            }
            index += 1
        }
        return nil
    }

    /// End of the `.modifier(...)` / `.modifier { ... }` chain that starts at `start`.
    private static func chainEnd(_ chars: [Character], _ start: Int) -> Int {
        var end = start
        while true {
            var index = skipWhitespace(chars, end)
            guard index < chars.count, chars[index] == "." else { return end }
            index += 1
            let nameStart = index
            while index < chars.count, isWord(chars[index]) { index += 1 }
            guard index > nameStart else { return end }
            index = skipWhitespace(chars, index)
            guard index < chars.count, chars[index] == "(" || chars[index] == "{" else { return end }
            let close: Character = chars[index] == "(" ? ")" : "}"
            guard let next = balancedEnd(chars, index, open: chars[index], close: close) else { return end }
            end = next
        }
    }

    /// True when `text` calls a view initializer named `name` (not a longer name such as `accessibilityLabel(`).
    private static func calls(_ text: String, _ name: String) -> Bool {
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: name + "(", range: search) {
            if range.lowerBound == text.startIndex || !text[text.index(before: range.lowerBound)].isLetter { return true }
            search = range.upperBound..<text.endIndex
        }
        return false
    }

    /// 1-based lines of Button/Menu whose label is an `Image` with no Text/Label and no `.accessibilityLabel`.
    static func unlabeledIconOnlyControls(in source: String) -> [Int] {
        let chars = Array(source)
        var lines: [Int] = []
        for keyword in ["Button", "Menu"] {
            var from = source.startIndex
            while let range = source.range(of: keyword, range: from..<source.endIndex) {
                from = range.upperBound
                let start = source.distance(from: source.startIndex, to: range.lowerBound)
                let end = start + keyword.count
                if start > 0, chars[start - 1] == "." || isWord(chars[start - 1]) { continue }
                if end < chars.count, isWord(chars[end]) { continue }
                if let line = unlabeledIconLine(chars, start: start, afterKeyword: end) { lines.append(line) }
            }
        }
        return lines.sorted()
    }

    private static func unlabeledIconLine(_ chars: [Character], start: Int, afterKeyword: Int) -> Int? {
        var pos = afterKeyword
        var blocks: [String] = []
        var trailing: String?
        var label: String?
        var index = skipWhitespace(chars, pos)
        if index < chars.count, chars[index] == "(" {
            guard let next = balancedEnd(chars, index, open: "(", close: ")") else { return nil }
            blocks.append(String(chars[index..<next]))
            pos = next
            index = skipWhitespace(chars, pos)
        }
        if index < chars.count, chars[index] == "{" {
            guard let next = balancedEnd(chars, index, open: "{", close: "}") else { return nil }
            trailing = String(chars[index..<next])
            blocks.append(trailing ?? "")
            pos = next
            index = skipWhitespace(chars, pos)
        }
        let labelPrefix = Array("label:")
        if index + labelPrefix.count <= chars.count, Array(chars[index..<(index + labelPrefix.count)]) == labelPrefix {
            let brace = skipWhitespace(chars, index + labelPrefix.count)
            if brace < chars.count, chars[brace] == "{" {
                guard let next = balancedEnd(chars, brace, open: "{", close: "}") else { return nil }
                label = String(chars[brace..<next])
                blocks.append(label ?? "")
                pos = next
            }
        }
        guard let content = label ?? trailing else { return nil }
        guard content.contains("Image("), !calls(content, "Text"), !calls(content, "Label") else { return nil }
        let chain = String(chars[pos..<chainEnd(chars, pos)])
        let marker = ".accessibilityLabel("
        if chain.contains(marker) || blocks.contains(where: { $0.contains(marker) }) { return nil }
        return chars[0..<start].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}
