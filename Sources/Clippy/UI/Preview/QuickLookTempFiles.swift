import Foundation

/// Owns the temp copies handed to Quick Look: created 0600 inside a private 0700 directory, removed on close.
final class QuickLookTempFiles {
    private let directory: URL
    private let fileManager = FileManager.default
    private(set) var created: [URL] = []

    /// Creates a janitor; the default directory is a per-process folder under the system temp dir.
    init(directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClippyQuickLook-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)) {
        self.directory = directory
    }

    /// Copies `source` into the private directory with 0600 permissions and returns the copy.
    func materialize(copyOf source: URL) throws -> URL {
        try prepareDirectory()
        let target = directory.appendingPathComponent(UUID().uuidString + "-" + Self.safeName(source.lastPathComponent))
        try fileManager.copyItem(at: source, to: target)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        created.append(target)
        return target
    }

    /// Writes `data` as a new 0600 file named `name`.
    func materialize(data: Data, name: String) throws -> URL {
        try prepareDirectory()
        let target = directory.appendingPathComponent(UUID().uuidString + "-" + Self.safeName(name))
        guard fileManager.createFile(atPath: target.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        created.append(target)
        return target
    }

    /// Removes every file created so far and the directory when it is empty.
    func cleanUp() {
        for url in created { try? fileManager.removeItem(at: url) }
        created.removeAll()
        if (try? fileManager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? fileManager.removeItem(at: directory)
        }
    }

    /// Strips path separators so a name cannot escape the directory.
    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty || cleaned == ".." || cleaned == "." ? "clip" : cleaned
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
    }
}
