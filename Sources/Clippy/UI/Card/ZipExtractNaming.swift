import AppKit

/// Pure naming and wording for the card's "Extract" action on zip clips.
enum ZipExtractNaming {
    /// First folder in `parent` named `baseName`, `baseName 2`, `baseName 3`, ...
    /// that `exists` reports as free. An empty base falls back to "Extracted".
    static func uniqueDirectory(baseName: String, in parent: URL, exists: (URL) -> Bool) -> URL {
        let base = baseName.isEmpty ? "Extracted" : baseName
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while exists(candidate) {
            candidate = parent.appendingPathComponent("\(base) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    /// Alert body for a failed extraction; includes ditto's own message when it gave one.
    static func failureDetail(reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "The archive could not be unpacked. It may be damaged or password protected."
        return trimmed.isEmpty ? base : base + " (" + trimmed + ")"
    }
}

/// Small modal notice for file actions that would otherwise fail silently.
@MainActor
enum FileActionAlert {
    static func missingFileDetail(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "The file is no longer available." }
        return "\((path as NSString).lastPathComponent) has been moved or deleted."
    }

    static func present(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
