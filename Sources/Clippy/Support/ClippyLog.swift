import Foundation
import os

// MARK: - ClippyLog
// Persistent rotating logger. Every event goes to both os.Logger (Console.app
// visible, no file-system cost) and a plain-text file so post-mortem diagnosis
// is possible even after crashes that clear the os_log ring buffer.
//
// File layout:
//   ~/Library/Application Support/Clippy/Logs/clippy.log       (active)
//   ~/Library/Application Support/Clippy/Logs/clippy.log.1     (one prior rotation)
//
// Rotation: when clippy.log exceeds 2 MB, it is renamed to clippy.log.1 (any
// existing .1 is overwritten) and a fresh clippy.log is started. Total on-disk
// budget is therefore ~4 MB.
//
// All file I/O runs on a dedicated serial queue so logging never blocks the
// caller (capture, UI, sync).

enum ClippyLog {

    // MARK: - Log level

    /// Severity threshold for both sinks, ordered ascending. Comparable is
    /// derived from rawValue so `level >= threshold` gates emission.
    enum LogLevel: Int, Comparable, CaseIterable, Identifiable {
        case verbose
        case debug
        case info
        case warning
        case error

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .verbose: return "Verbose"
            case .debug:   return "Debug"
            case .info:    return "Info"
            case .warning: return "Warning"
            case .error:   return "Error"
            }
        }

        static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // Current minimum level both sinks honor. AppSettings sets this from the
    // stored logLevel at init and on every change, so logging is configurable
    // without ClippyLog importing AppSettings (avoids a Support->UI cycle and
    // keeps this enum usable from crash-handler code that runs before settings).
    // Read on each emit so a live change takes effect immediately.
    nonisolated(unsafe) static var threshold: LogLevel = .info

    // MARK: - os.Logger accessors (one per functional area)

    static let lifecycle = Logger(subsystem: "com.bytesavvy.clippy", category: "lifecycle")
    static let capture   = Logger(subsystem: "com.bytesavvy.clippy", category: "capture")
    static let storage   = Logger(subsystem: "com.bytesavvy.clippy", category: "storage")
    static let sync      = Logger(subsystem: "com.bytesavvy.clippy", category: "sync")
    static let mcp       = Logger(subsystem: "com.bytesavvy.clippy", category: "mcp")
    static let ai        = Logger(subsystem: "com.bytesavvy.clippy", category: "ai")
    static let scripts   = Logger(subsystem: "com.bytesavvy.clippy", category: "scripts")

    // MARK: - File sink internals

    // Serial queue: all appends and rotations serialize here, never blocking callers.
    private static let fileQueue = DispatchQueue(label: "com.bytesavvy.clippy.log-file",
                                                 qos: .utility)

    // 2 MB rotation threshold; ~4 MB total with one backup.
    private static let maxLogBytes: UInt64 = 2 * 1024 * 1024

    private static let logDir: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippy", isDirectory: true)
        return support.appendingPathComponent("Logs", isDirectory: true)
    }()

    private static let logURL:   URL = logDir.appendingPathComponent("clippy.log")
    private static let backupURL: URL = logDir.appendingPathComponent("clippy.log.1")

    // FileHandle kept open for the lifetime of the process (append-only).
    // Created lazily on the fileQueue the first time a line is written.
    private static var _handle: FileHandle?

    // MARK: - Public API (leveled)

    static func verbose(_ message: String, category: Logger) {
        emit(.verbose, message, category: category)
    }

    static func debug(_ message: String, category: Logger) {
        emit(.debug, message, category: category)
    }

    /// Write an info-level message to both os.Logger and the file sink.
    static func info(_ message: String, category: Logger) {
        emit(.info, message, category: category)
    }

    static func warning(_ message: String, category: Logger) {
        emit(.warning, message, category: category)
    }

    /// Write an error-level message to both os.Logger and the file sink.
    static func error(_ message: String, category: Logger) {
        emit(.error, message, category: category)
    }

    // MARK: - Gated emit

    /// Single choke point for both sinks. Drops the message entirely when its
    /// level is below the current threshold, so neither os.Logger nor the file
    /// is touched. os.Logger level mapping: verbose+debug -> .debug, info ->
    /// .info, warning -> .warning, error -> .error.
    static func emit(_ level: LogLevel, _ message: String, category: Logger) {
        guard level >= threshold else { return }

        switch level {
        case .verbose, .debug:
            category.debug("\(message, privacy: .public)")
        case .info:
            category.info("\(message, privacy: .public)")
        case .warning:
            category.warning("\(message, privacy: .public)")
        case .error:
            category.error("\(message, privacy: .public)")
        }

        fileSink(level: fileTag(level), message: message)
    }

    private static func fileTag(_ level: LogLevel) -> String {
        switch level {
        case .verbose: return "VERBOSE"
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }

    // MARK: - Synchronous flush (for crash handler)

    /// Write directly on the calling thread without queuing. Used by the
    /// uncaught-exception handler so the line is guaranteed to land before
    /// the process exits.
    static func syncWrite(_ message: String, level: String = "FATAL") {
        let line = formatLine(level: level, message: message)
        // Best-effort: open, append, close inline.
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            if let data = (line + "\n").data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path) {
                    let fh = try FileHandle(forWritingTo: logURL)
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try fh.close()
                } else {
                    try data.write(to: logURL, options: .atomic)
                }
            }
        } catch {
            // Last resort: os_log only — cannot recurse into ClippyLog.error here.
            os_log(.fault, "ClippyLog syncWrite failed: %{public}@", error.localizedDescription)
        }
    }

    // MARK: - Test support

    // The active log file. Exposed so tests can read it back and assert which
    // levels reached the file sink. Not for production callers.
    static var logFileURL: URL { logURL }

    // Block until every queued append has run. The file sink is async on a
    // serial queue, so a test must flush before reading the file or it races
    // the writer. A sync barrier-style hop is enough: it cannot return until
    // all previously enqueued async blocks have completed.
    static func flushForTesting() {
        fileQueue.sync { }
    }

    // MARK: - File sink implementation

    private static func fileSink(level: String, message: String) {
        let line = formatLine(level: level, message: message)
        fileQueue.async {
            appendToFile(line + "\n")
        }
    }

    private static func formatLine(level: String, message: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Extract category name from the message context is not straightforward;
        // callers supply it via the public API's `category` label instead.
        return "\(iso.string(from: Date())) | \(level) | \(message)"
    }

    /// Must only be called on fileQueue.
    private static func appendToFile(_ text: String) {
        // Ensure log directory exists.
        if _handle == nil {
            do {
                try FileManager.default.createDirectory(
                    at: logDir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: logURL.path) {
                    FileManager.default.createFile(atPath: logURL.path, contents: nil)
                }
                _handle = try FileHandle(forWritingTo: logURL)
                _handle?.seekToEndOfFile()
            } catch {
                os_log(.error, "ClippyLog: could not open log file: %{public}@",
                       error.localizedDescription)
                return
            }
        }

        guard let data = text.data(using: .utf8) else { return }
        _handle?.write(data)

        // Rotate when the file exceeds the threshold.
        rotateIfNeeded()
    }

    /// Must only be called on fileQueue.
    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64,
              size >= maxLogBytes else { return }

        // Close the active handle before renaming.
        try? _handle?.close()
        _handle = nil

        // Overwrite any existing backup and rotate.
        let fm = FileManager.default
        try? fm.removeItem(at: backupURL)
        try? fm.moveItem(at: logURL, to: backupURL)

        // Open a fresh file.
        fm.createFile(atPath: logURL.path, contents: nil)
        if let fh = try? FileHandle(forWritingTo: logURL) {
            _handle = fh
        }
    }
}

// MARK: - Convenience wrappers with category string

extension ClippyLog {
    /// Convenience: log with a string category name. Dispatches to the matching
    /// Logger accessor; unknown categories fall through to `lifecycle`.
    static func info(_ message: String, categoryName: String) {
        info("[\(categoryName)] \(message)", category: logger(for: categoryName))
    }

    static func error(_ message: String, categoryName: String) {
        error("[\(categoryName)] \(message)", category: logger(for: categoryName))
    }

    private static func logger(for name: String) -> Logger {
        switch name {
        case "capture":   return capture
        case "storage":   return storage
        case "sync":      return sync
        case "mcp":       return mcp
        case "ai":        return ai
        default:          return lifecycle
        }
    }
}
