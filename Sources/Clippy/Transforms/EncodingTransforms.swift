import Foundation

/// JSON, base64, URL, HTML-entity and timestamp transforms.
enum EncodingTransforms {
    /// Every encoding transform.
    static let all: [any TextTransform] = [
        FunctionTransform(id: "json.pretty", title: "JSON pretty print", category: .json) { try jsonFormat($0, pretty: true) },
        FunctionTransform(id: "json.minify", title: "JSON minify", category: .json) { try jsonFormat($0, pretty: false) },
        FunctionTransform(id: "json.validate", title: "JSON validate", category: .json) { try jsonValidate($0) },
        FunctionTransform(id: "base64.encode", title: "Base64 encode", category: .encoding) {
            Data($0.utf8).base64EncodedString()
        },
        FunctionTransform(id: "base64.decode", title: "Base64 decode", category: .encoding) { try base64Decode($0) },
        FunctionTransform(id: "url.encode", title: "URL encode", category: .encoding, keywords: ["percent"]) { urlEncode($0) },
        FunctionTransform(id: "url.decode", title: "URL decode", category: .encoding, keywords: ["percent"]) { try urlDecode($0) },
        FunctionTransform(id: "html.encode", title: "HTML entity encode", category: .encoding) { htmlEncode($0) },
        FunctionTransform(id: "html.decode", title: "HTML entity decode", category: .encoding) { htmlDecode($0) },
        FunctionTransform(id: "date.toiso", title: "Unix timestamp to ISO date", category: .date, keywords: ["epoch"]) {
            try timestampToISO($0)
        },
        FunctionTransform(id: "date.fromiso", title: "ISO date to Unix timestamp", category: .date, keywords: ["epoch"]) {
            try isoToTimestamp($0)
        }
    ]

    // MARK: - JSON

    /// Parses `text` as JSON and re-serialises it; throws with a 1-based line/column on bad input.
    static func jsonFormat(_ text: String, pretty: Bool) throws -> String {
        let object = try parseJSON(text)
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.formUnion([.prettyPrinted, .sortedKeys]) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let out = String(data: data, encoding: .utf8) else { throw TransformError.invalid("Could not re-encode JSON.") }
        return out
    }

    /// Returns "Valid JSON" or throws with the error position.
    static func jsonValidate(_ text: String) throws -> String {
        _ = try parseJSON(text)
        return "Valid JSON"
    }

    private static func parseJSON(_ text: String) throws -> Any {
        let data = Data(text.utf8)
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch let error as NSError {
            let offset = (error.userInfo["NSJSONSerializationErrorIndex"] as? Int) ?? 0
            let (line, column) = position(of: offset, in: data)
            let detail = (error.userInfo[NSDebugDescriptionErrorKey] as? String) ?? "Invalid JSON"
            let reason = detail.components(separatedBy: " around ").first ?? detail
            throw TransformError.invalidInput(reason: reason, line: line, column: column)
        }
    }

    /// 1-based line and column (in characters) for a UTF-8 byte offset.
    static func position(of offset: Int, in data: Data) -> (Int, Int) {
        let clamped = max(0, min(offset, data.count))
        let prefix = String(decoding: data.prefix(clamped), as: UTF8.self)
        var line = 1
        var column = 1
        for char in prefix {
            if char == "\n" || char == "\r\n" { line += 1; column = 1 } else { column += 1 }
        }
        return (line, column)
    }

    // MARK: - Encodings

    /// Decodes standard or URL-safe base64 (padding optional) into UTF-8 text.
    static func base64Decode(_ text: String) throws -> String {
        var cleaned = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while cleaned.count % 4 != 0 { cleaned += "=" }
        guard let data = Data(base64Encoded: cleaned) else { throw TransformError.invalid("Not valid base64.") }
        guard let out = String(data: data, encoding: .utf8) else { throw TransformError.invalid("Decoded bytes are not UTF-8 text.") }
        return out
    }

    /// Percent-encodes everything except RFC 3986 unreserved characters.
    static func urlEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// Percent-decodes; `+` is kept as a plus sign.
    static func urlDecode(_ text: String) throws -> String {
        guard let out = text.removingPercentEncoding else { throw TransformError.invalid("Contains an invalid percent escape.") }
        return out
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "hellip": "\u{2026}", "mdash": "\u{2014}", "ndash": "\u{2013}"
    ]

    /// Escapes `& < > " '`.
    static func htmlEncode(_ text: String) -> String {
        var out = ""
        for char in text {
            switch char {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(char)
            }
        }
        return out
    }

    /// Decodes named (common set) and numeric (decimal/hex) entities; unknown entities are left as is.
    static func htmlDecode(_ text: String) -> String {
        guard text.contains("&"), let regex = try? NSRegularExpression(pattern: "&(#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z]+);") else {
            return text
        }
        let source = text as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            out += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let body = source.substring(with: match.range(at: 1))
            out += decodeEntity(body) ?? source.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        return out + source.substring(from: cursor)
    }

    private static func decodeEntity(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return namedEntities[body]
    }

    // MARK: - Timestamps

    /// Seconds (or milliseconds when 13+ digits) since 1970 to an ISO 8601 UTC string.
    static func timestampToISO(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite else { throw TransformError.invalid("Not a Unix timestamp.") }
        let seconds = abs(value) >= 1e12 ? value / 1000 : value
        guard abs(seconds) < 253_402_300_800 else { throw TransformError.invalid("Timestamp is out of range.") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// An ISO 8601 date/time (fractional seconds and date-only accepted) to whole Unix seconds.
    static func isoToTimestamp(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds],
                                                       [.withFullDate]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: trimmed) { return String(Int64(date.timeIntervalSince1970.rounded(.down))) }
        }
        throw TransformError.invalid("Not an ISO 8601 date.")
    }
}
