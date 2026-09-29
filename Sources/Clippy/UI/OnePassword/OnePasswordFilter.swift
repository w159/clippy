import Foundation

/// Client-side item search (OPW-03): case- and diacritic-insensitive match on the
/// item title, its category and the vault name. Never touches field values.
enum OnePasswordFilter {
    static func filter(_ items: [OPItem], query: String, vault: String) -> [OPItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return items }
        return items.filter { item in
            let haystack = "\(item.title) \(vault)"
            return terms.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// "SECURE_NOTE" -> "Secure Note".
    static func displayCategory(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// SF Symbol for a 1Password category (`op` category names, upper snake case).
    static func symbol(forCategory raw: String) -> String {
        switch raw.uppercased() {
        case "LOGIN": return "person.crop.circle"
        case "PASSWORD": return "key.fill"
        case "SECURE_NOTE": return "note.text"
        case "CREDIT_CARD": return "creditcard"
        case "IDENTITY": return "person.text.rectangle"
        case "API_CREDENTIAL": return "curlybraces"
        case "SERVER", "DATABASE": return "server.rack"
        case "SSH_KEY": return "terminal"
        case "DOCUMENT": return "doc"
        case "BANK_ACCOUNT": return "building.columns"
        case "WIRELESS_ROUTER": return "wifi.router"
        case "SOFTWARE_LICENSE": return "checkmark.seal"
        case "PASSPORT", "DRIVER_LICENSE": return "person.badge.shield.checkmark"
        default: return "lock.doc"
        }
    }
}
