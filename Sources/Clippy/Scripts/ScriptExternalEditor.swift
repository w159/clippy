import AppKit
import Darwin
import Foundation

/// Opens a script body in an external text editor and feeds saves back. The body
/// is written to a private temp file, opened in the first installed editor from
/// a fixed list (never the system default for `.sh`, which may execute it), and
/// watched: every save on disk is delivered to `onChange`. Survives editors that
/// save by replacing the file.
@MainActor
final class ScriptExternalEditor {
    static let shared = ScriptExternalEditor()

    private struct Session {
        var url: URL
        var lastText: String
        var source: DispatchSourceFileSystemObject?
        var onChange: (String) -> Void
    }

    private var sessions: [UUID: Session] = [:]

    /// Preferred editors, first installed wins. TextEdit is always present.
    private static let editorBundleIDs = [
        "com.sublimetext.4", "com.sublimetext.3", "com.microsoft.VSCode",
        "com.barebones.bbedit", "com.panic.Nova", "com.apple.TextEdit",
    ]

    private init() {}

    /// Display name of the editor that will open, for the menu item.
    var editorName: String {
        guard let url = Self.editorURL else { return "External Editor" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static var editorURL: URL? {
        for id in editorBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    /// Writes `script.body` to a temp file and opens it. Re-invoking for a script
    /// that is already open just re-opens the same file. Returns false when the
    /// file could not be written or no editor could be launched.
    @discardableResult
    func open(_ script: Script, onChange: @escaping (String) -> Void) -> Bool {
        if var existing = sessions[script.id] {
            existing.onChange = onChange
            sessions[script.id] = existing
            return launch(existing.url)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clippy-script-edits", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return false }
        let safeName = script.name.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        let url = directory.appendingPathComponent("\(safeName.isEmpty ? "script" : safeName)-\(script.id.uuidString.prefix(8)).\(script.interpreter.fileExtension)")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(script.body.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return false }
        var session = Session(url: url, lastText: script.body, source: nil, onChange: onChange)
        session.source = watch(url, scriptID: script.id)
        sessions[script.id] = session
        return launch(url)
    }

    /// Stops watching and deletes the temp file.
    func stop(scriptID: UUID) {
        guard let session = sessions.removeValue(forKey: scriptID) else { return }
        session.source?.cancel()
        try? FileManager.default.removeItem(at: session.url)
    }

    func stopAll() {
        for id in Array(sessions.keys) { stop(scriptID: id) }
    }

    private func launch(_ url: URL) -> Bool {
        guard let editor = Self.editorURL else { return NSWorkspace.shared.open(url) }
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    private func watch(_ url: URL, scriptID: UUID) -> DispatchSourceFileSystemObject? {
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, var session = self.sessions[scriptID] else { return }
            let replaced = !source.data.intersection(DispatchSource.FileSystemEvent([.rename, .delete])).isEmpty
            if let text = try? String(contentsOf: session.url, encoding: .utf8), text != session.lastText {
                session.lastText = text
                self.sessions[scriptID] = session
                session.onChange(text)
            }
            if replaced {
                // Atomic save: the inode changed. Re-watch the new file.
                source.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, var current = self.sessions[scriptID] else { return }
                    current.source = self.watch(current.url, scriptID: scriptID)
                    self.sessions[scriptID] = current
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}
