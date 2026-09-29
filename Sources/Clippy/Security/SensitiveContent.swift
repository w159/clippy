import Foundation

/// On-device detection of secrets and regulated identifiers in copied text
/// (SEC-02). Everything here is pure string work: nothing is logged, stored
/// with the matched value, or sent anywhere.
///
/// Detection is deliberately precision-first for the strong formats (vendor key
/// prefixes, PEM headers, Luhn-valid card numbers, structurally valid SSNs, IBAN
/// mod-97) and context-gated for generic high-entropy tokens, so that ordinary
/// prose, UUIDs, hashes, and timestamps do not light up the whole history.
enum SensitiveContent {

    // MARK: - Types

    /// What kind of secret or identifier was recognized.
    enum Kind: String, Codable, CaseIterable {
        case awsAccessKey
        case githubToken
        case slackToken
        case stripeKey
        case openAIKey
        case anthropicKey
        case jwt
        case genericSecret
        case privateKey
        case creditCard
        case ssn
        case iban

        /// Short human label for badges and tooltips.
        var label: String {
            switch self {
            case .awsAccessKey: return "AWS access key"
            case .githubToken: return "GitHub token"
            case .slackToken: return "Slack token"
            case .stripeKey: return "Stripe key"
            case .openAIKey: return "OpenAI key"
            case .anthropicKey: return "Anthropic key"
            case .jwt: return "JWT"
            case .genericSecret: return "Secret"
            case .privateKey: return "Private key"
            case .creditCard: return "Card number"
            case .ssn: return "SSN"
            case .iban: return "IBAN"
            }
        }
    }

    /// How sure the detector is. Only `.medium` and above mark a clip sensitive.
    enum Confidence: Int, Codable, Comparable {
        case low = 0
        case medium = 1
        case high = 2

        static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One kind found in a text, at its highest confidence.
    struct Finding: Equatable, Codable {
        let kind: Kind
        let confidence: Confidence
    }

    /// A located match, used for masking. `range` is UTF-16 based (NSRange).
    struct Match: Equatable {
        let kind: Kind
        let confidence: Confidence
        let range: NSRange
    }

    // MARK: - Limits

    /// Only this many characters are scanned; a secret past it is not found,
    /// which keeps a 100 MB paste from stalling the capture path.
    static let scanLimit = 65_536

    /// Minimum confidence at which a clip counts as sensitive.
    static let sensitiveThreshold: Confidence = .medium

    /// Bullet used for masking.
    static let maskGlyph = "\u{2022}"

    // MARK: - Public API

    /// Kinds found in `text`, one entry per kind at its highest confidence,
    /// strongest first.
    static func detect(_ text: String) -> [Finding] {
        var best: [Kind: Confidence] = [:]
        for match in scan(text) {
            if best[match.kind].map({ $0 < match.confidence }) ?? true {
                best[match.kind] = match.confidence
            }
        }
        return best.map { Finding(kind: $0.key, confidence: $0.value) }
            .sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.kind.rawValue < $1.kind.rawValue }
    }

    /// True when `text` contains a finding at or above `sensitiveThreshold`.
    static func isSensitive(text: String) -> Bool {
        scan(text).contains { $0.confidence >= sensitiveThreshold }
    }

    /// Whether `clip` should be treated as sensitive: an explicit user override
    /// wins, then the flag recorded at capture, then a fresh scan of the text.
    /// Image and file clips are sensitive only through a stored flag or override.
    /// `store` defaults to the store the running monitor registered.
    static func isSensitive(clip: Clip, store: SensitiveFlagStore? = nil) -> Bool {
        if let entry = (store ?? SensitiveFlagStore.current)?.entry(for: clip.contentKey) {
            if let override = entry.userOverride { return override }
            if entry.confidence >= sensitiveThreshold { return true }
        }
        guard clip.contentKind == .text else { return false }
        return isSensitive(text: clip.contentText)
    }

    /// `text` with every recognized secret masked, for card previews. Cards keep
    /// enough to recognize the item (a key prefix, the last four card digits) and
    /// nothing more. Text past `scanLimit` is dropped rather than shown unscanned.
    /// Returns the input unchanged when nothing is found.
    static func maskedPreview(_ text: String) -> String {
        let limited = limit(text)
        let matches = resolveOverlaps(scanLimited(limited.text).filter { $0.confidence >= sensitiveThreshold })
        guard !matches.isEmpty else { return limited.truncated ? limited.text + "\u{2026}" : text }
        let result = NSMutableString(string: limited.text)
        for match in matches.reversed() {
            let original = result.substring(with: match.range)
            result.replaceCharacters(in: match.range, with: mask(original, kind: match.kind))
        }
        return limited.truncated ? (result as String) + "\u{2026}" : result as String
    }

    // MARK: - Scanning

    /// All matches in the scan window, unsorted, possibly overlapping.
    static func scan(_ text: String) -> [Match] {
        scanLimited(limit(text).text)
    }

    private static func limit(_ text: String) -> (text: String, truncated: Bool) {
        let head = text.prefix(scanLimit)
        return head.count < scanLimit ? (String(head), false) : (String(head), text.count > scanLimit)
    }

    private static func scanLimited(_ text: String) -> [Match] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        var matches: [Match] = []

        for rule in fixedRules {
            rule.regex.enumerateMatches(in: text, options: [], range: full) { result, _, _ in
                guard let result else { return }
                matches.append(Match(kind: rule.kind, confidence: rule.confidence(nsText.substring(with: result.range)), range: result.range))
            }
        }
        genericSecretRegex.enumerateMatches(in: text, options: [], range: full) { result, _, _ in
            guard let result, result.numberOfRanges >= 3 else { return }
            let keyName = nsText.substring(with: result.range(at: 1)).lowercased()
            let value = nsText.substring(with: result.range(at: 2))
            if let confidence = genericConfidence(keyName: keyName, value: value) {
                matches.append(Match(kind: .genericSecret, confidence: confidence, range: result.range(at: 2)))
            }
        }
        bearerRegex.enumerateMatches(in: text, options: [], range: full) { result, _, _ in
            guard let result, result.numberOfRanges >= 2 else { return }
            let value = nsText.substring(with: result.range(at: 1))
            if genericConfidence(keyName: "bearer", value: value) != nil {
                matches.append(Match(kind: .genericSecret, confidence: .medium, range: result.range(at: 1)))
            }
        }
        cardRegex.enumerateMatches(in: text, options: [], range: full) { result, _, _ in
            guard let result else { return }
            if isPlausibleCard(nsText.substring(with: result.range)) {
                matches.append(Match(kind: .creditCard, confidence: .high, range: result.range))
            }
        }
        ssnRegex.enumerateMatches(in: text, options: [], range: full) { result, _, _ in
            guard let result, result.numberOfRanges >= 4 else { return }
            let area = nsText.substring(with: result.range(at: 1))
            let group = nsText.substring(with: result.range(at: 2))
            let serial = nsText.substring(with: result.range(at: 3))
            guard isValidSSN(area: area, group: group, serial: serial) else { return }
            let contextStart = max(0, result.range.location - 24)
            let context = nsText.substring(with: NSRange(location: contextStart, length: result.range.location - contextStart)).lowercased()
            let hasContext = context.contains("ssn") || context.contains("social security") || context.contains("soc sec")
            matches.append(Match(kind: .ssn, confidence: hasContext ? .high : .medium, range: result.range))
        }
        bareSSNRegex.enumerateMatches(in: text, options: [], range: full) { result, _, _ in
            guard let result, result.numberOfRanges >= 2 else { return }
            let digits = nsText.substring(with: result.range(at: 1))
            let area = String(digits.prefix(3)), group = String(digits.dropFirst(3).prefix(2)), serial = String(digits.suffix(4))
            if isValidSSN(area: area, group: group, serial: serial) {
                matches.append(Match(kind: .ssn, confidence: .high, range: result.range(at: 1)))
            }
        }
        ibanRegex.enumerateMatches(in: text, options: [], range: full) { result, _, _ in
            guard let result else { return }
            if let confidence = ibanConfidence(nsText.substring(with: result.range)) {
                matches.append(Match(kind: .iban, confidence: confidence, range: result.range))
            }
        }
        return matches
    }

    /// Sorted by location; an overlapping later match is dropped.
    private static func resolveOverlaps(_ matches: [Match]) -> [Match] {
        var kept: [Match] = []
        for match in matches.sorted(by: { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }) {
            if let last = kept.last, match.range.location < last.range.location + last.range.length { continue }
            kept.append(match)
        }
        return kept
    }

    // MARK: - Masking

    private static func mask(_ original: String, kind: Kind) -> String {
        let bullets = String(repeating: maskGlyph, count: 8)
        switch kind {
        case .creditCard:
            let digits = original.filter(\.isNumber)
            return "\(maskGlyph)\(maskGlyph)\(maskGlyph)\(maskGlyph) \(digits.suffix(4))"
        case .ssn:
            return "\(maskGlyph)\(maskGlyph)\(maskGlyph)-\(maskGlyph)\(maskGlyph)-\(original.filter(\.isNumber).suffix(4))"
        case .iban:
            let compact = original.replacingOccurrences(of: " ", with: "")
            return "\(compact.prefix(4)) \(bullets) \(compact.suffix(4))"
        case .privateKey:
            let header = original.components(separatedBy: "-----").filter { $0.contains("PRIVATE KEY") }.first ?? "PRIVATE KEY"
            return "-----\(header)----- \(bullets)"
        default:
            let keep = original.count >= 16 ? 4 : 0
            return "\(original.prefix(keep))\(bullets)"
        }
    }

    // MARK: - Rules

    private struct FixedRule {
        let kind: Kind
        let regex: NSRegularExpression
        let confidence: @Sendable (String) -> Confidence
    }

    private static func compile(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are compile-time constants; a failure here is a programming error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let fixedRules: [FixedRule] = [
        FixedRule(kind: .awsAccessKey,
                  regex: compile(#"(?<![A-Za-z0-9])(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA)[A-Z0-9]{16}(?![A-Za-z0-9])"#),
                  confidence: { _ in .high }),
        FixedRule(kind: .githubToken,
                  regex: compile(#"(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{22,255})(?![A-Za-z0-9_])"#),
                  confidence: { _ in .high }),
        FixedRule(kind: .slackToken,
                  regex: compile(#"(?<![A-Za-z0-9])xox[abposr]-[A-Za-z0-9-]{10,}(?![A-Za-z0-9-])"#),
                  confidence: { _ in .high }),
        FixedRule(kind: .stripeKey,
                  regex: compile(#"(?<![A-Za-z0-9_])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}(?![A-Za-z0-9_])"#),
                  confidence: { $0.contains("_live_") ? .high : .medium }),
        FixedRule(kind: .anthropicKey,
                  regex: compile(#"(?<![A-Za-z0-9_-])sk-ant-[A-Za-z0-9_-]{20,}(?![A-Za-z0-9_-])"#),
                  confidence: { _ in .high }),
        FixedRule(kind: .openAIKey,
                  regex: compile(#"(?<![A-Za-z0-9_-])sk-(?!ant-)(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])"#),
                  confidence: { _ in .high }),
        FixedRule(kind: .jwt,
                  regex: compile(#"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?![A-Za-z0-9_-])"#),
                  confidence: { _ in .high }),
        FixedRule(kind: .privateKey,
                  regex: compile(#"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----(?:.*?-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----|.*$)"#, [.dotMatchesLineSeparators]),
                  confidence: { _ in .high }),
    ]

    /// `key = value` style assignments; group 1 the key name, group 2 the value.
    private static let genericSecretRegex = compile(
        #"(?i)\b("#
            + #"api[_-]?key|apikey|secret[_-]?key|client[_-]?secret|access[_-]?key|access[_-]?token"#
            + #"|auth[_-]?token|secret|token|passwd|password|pwd"#
            + #")["']?\s*[:=]\s*["']?([A-Za-z0-9_\-+/=.!@#$%^&*]{8,})"#)

    private static let bearerRegex = compile(#"(?i)\bbearer\s+([A-Za-z0-9_\-.=+/]{20,})"#)

    /// 13-19 digits with optional single space or hyphen separators.
    private static let cardRegex = compile(#"(?<![\d-])(?:\d[ -]?){12,18}\d(?![\d-])"#)

    private static let ssnRegex = compile(#"(?<![\d-])(\d{3})[- ](\d{2})[- ](\d{4})(?![\d-])"#)

    /// Nine bare digits, only when an SSN keyword sits right before them.
    private static let bareSSNRegex = compile(#"(?i)(?:\bssn|social security(?: number)?|soc\.? sec\.?)\s*(?:#|no\.?|number)?\s*[:=]?\s*(\d{9})(?!\d)"#)

    private static let ibanRegex = compile(#"(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?(?![A-Za-z0-9])"#)

    // MARK: - Validators

    /// Shannon entropy in bits per character.
    static func entropy(_ value: String) -> Double {
        guard !value.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in value { counts[character, default: 0] += 1 }
        let total = Double(value.count)
        return counts.values.reduce(0) { $0 - (Double($1) / total) * log2(Double($1) / total) }
    }

    private static func genericConfidence(keyName: String, value: String) -> Confidence? {
        let hasLetter = value.contains(where: \.isLetter)
        let hasDigit = value.contains(where: \.isNumber)
        guard hasLetter || hasDigit else { return nil }
        let classes = [value.contains(where: \.isLowercase), value.contains(where: \.isUppercase), hasDigit,
                       value.contains(where: { !$0.isLetter && !$0.isNumber })].filter { $0 }.count
        let passwordLike = keyName.contains("pass") || keyName == "pwd"
        if value.count >= 16, hasLetter, hasDigit, entropy(value) >= 3.5 { return .medium }
        if passwordLike, value.count >= 8, classes >= 2, entropy(value) >= 2.5 { return .medium }
        return nil
    }

    /// Luhn checksum over a digit string.
    static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        var double = false
        for character in digits.reversed() {
            guard let value = character.wholeNumberValue else { return false }
            var digit = value
            if double { digit *= 2; if digit > 9 { digit -= 9 } }
            sum += digit
            double.toggle()
        }
        return !digits.isEmpty && sum % 10 == 0
    }

    private static func isPlausibleCard(_ raw: String) -> Bool {
        let digits = raw.filter(\.isNumber)
        guard (13...19).contains(digits.count), Set(digits).count > 1, passesLuhn(digits) else { return false }
        // Mixed separators ("1234-5678 9012...") are not how cards are written.
        if raw.contains(" ") && raw.contains("-") { return false }
        guard let prefix2 = Int(digits.prefix(2)), let prefix3 = Int(digits.prefix(3)),
              let prefix4 = Int(digits.prefix(4)) else { return false }
        let count = digits.count
        switch digits.first {
        case "4": return [13, 16, 19].contains(count)
        case "5": return count == 16 && (51...55).contains(prefix2)
        case "2": return count == 16 && (2221...2720).contains(prefix4)
        case "3":
            if prefix2 == 34 || prefix2 == 37 { return count == 15 }
            if (300...305).contains(prefix3) || prefix2 == 36 || prefix2 == 38 { return count == 14 }
            if (3528...3589).contains(prefix4) { return (16...19).contains(count) }
            return false
        case "6":
            if prefix4 == 6011 || prefix2 == 65 || (644...649).contains(prefix3) { return (16...19).contains(count) }
            if prefix2 == 62 { return (16...19).contains(count) }
            return false
        default: return false
        }
    }

    /// Structural SSN validity per SSA issuance rules.
    static func isValidSSN(area: String, group: String, serial: String) -> Bool {
        guard area.count == 3, group.count == 2, serial.count == 4,
              let areaValue = Int(area), let groupValue = Int(group), let serialValue = Int(serial) else { return false }
        if areaValue == 0 || areaValue == 666 || areaValue >= 900 { return false }
        if groupValue == 0 || serialValue == 0 { return false }
        // Numbers that were printed in advertising and are not real.
        if area == "078" && group == "05" && serial == "1120" { return false }
        if area == "219" && group == "09" && serial == "9999" { return false }
        return true
    }

    private static let ibanLengths: [String: Int] = [
        "DE": 22, "GB": 22, "FR": 27, "ES": 24, "IT": 27, "NL": 18, "BE": 16, "CH": 21, "AT": 20,
        "IE": 22, "PT": 25, "SE": 24, "NO": 15, "DK": 18, "FI": 18, "PL": 28, "LU": 20, "GR": 27,
        "CZ": 24, "HU": 28, "RO": 24, "BG": 22, "HR": 21, "SK": 24, "SI": 19, "LT": 20, "LV": 21,
        "EE": 20, "CY": 28, "MT": 31, "IS": 26, "LI": 21, "MC": 27, "SA": 24, "AE": 23, "IL": 23,
        "TR": 26,
    ]

    private static func ibanConfidence(_ raw: String) -> Confidence? {
        let compact = raw.replacingOccurrences(of: " ", with: "")
        guard (15...34).contains(compact.count), ibanMod97(compact) == 1 else { return nil }
        let country = String(compact.prefix(2))
        if let expected = ibanLengths[country] { return compact.count == expected ? .high : nil }
        return .medium
    }

    /// ISO 7064 mod 97-10 over the rearranged IBAN, without big integers.
    static func ibanMod97(_ compact: String) -> Int {
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for character in rearranged {
            guard let scalar = character.unicodeScalars.first else { return -1 }
            let chunk: Int
            if let digit = character.wholeNumberValue, character.isASCII { chunk = digit }
            else if character.isASCII, character.isUppercase { chunk = Int(scalar.value) - 55 }
            else { return -1 }
            remainder = (chunk >= 10 ? remainder * 100 + chunk : remainder * 10 + chunk) % 97
        }
        return remainder
    }
}
