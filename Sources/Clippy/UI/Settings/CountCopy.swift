import Foundation

/// Count-bearing sentences built on `CopyFormat`, kept pure so "1 entries" and
/// "image(s)" cannot creep back in.
enum CountCopy {
    static func tamperingNotFound(entries: Int, files: Int) -> String {
        "No tampering found in \(CopyFormat.counted(entries, "entry", plural: "entries")) across \(CopyFormat.counted(files, "file"))."
    }

    static func exportedEntries(_ count: Int) -> String {
        "Exported \(CopyFormat.counted(count, "entry", plural: "entries"))."
    }

    static func skippedImages(_ count: Int) -> String {
        "Skipped \(CopyFormat.counted(count, "image")) whose \(count == 1 ? "file was" : "files were") missing."
    }

    static func importedSettings(_ count: Int, from fileName: String) -> String {
        "Imported \(CopyFormat.counted(count, "setting")) from \(fileName)."
    }

    static func listSummary(_ count: Int) -> String {
        CopyFormat.counted(count, "item")
    }

    /// VoiceOver label for a sidebar section header; the count is optional.
    static func sectionLabel(title: String, count: Int?) -> String {
        count.map { "\(title), \(CopyFormat.counted($0, "item"))" } ?? title
    }
}
