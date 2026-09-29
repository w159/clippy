import Foundation

/// How a script body is executed. Each case maps to a launch executable and the
/// arguments used to run a body written to a temp file.
enum ScriptInterpreter: String, Codable, CaseIterable, Identifiable {
    case zsh
    case bash
    case sh
    case python3
    case node
    case ruby
    case applescript
    case swift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zsh: return "Zsh"
        case .bash: return "Bash"
        case .sh: return "Shell (sh)"
        case .python3: return "Python 3"
        case .node: return "Node.js"
        case .ruby: return "Ruby"
        case .applescript: return "AppleScript"
        case .swift: return "Swift"
        }
    }

    /// File extension for the temp script file (helps interpreters and editors).
    var fileExtension: String {
        switch self {
        case .zsh, .bash, .sh: return "sh"
        case .python3: return "py"
        case .node: return "js"
        case .ruby: return "rb"
        case .applescript: return "scpt"
        case .swift: return "swift"
        }
    }

    /// The launch executable and the leading arguments before the script path.
    /// Shells use absolute paths; the rest resolve via /usr/bin/env so they
    /// follow the user's PATH. The script file path is appended by the runner.
    var launch: (executable: String, leadingArgs: [String]) {
        switch self {
        case .zsh: return ("/bin/zsh", [])
        case .bash: return ("/bin/bash", [])
        case .sh: return ("/bin/sh", [])
        case .python3: return ("/usr/bin/env", ["python3"])
        case .node: return ("/usr/bin/env", ["node"])
        case .ruby: return ("/usr/bin/env", ["ruby"])
        case .applescript: return ("/usr/bin/osascript", [])
        case .swift: return ("/usr/bin/env", ["swift"])
        }
    }
}

/// A user-stored script that can be run from Clippy. Bodies are arbitrary code.
///
/// Run-confirmation policy (must stay in sync between the two surfaces):
///   - Settings (ScriptsView): every Run goes through a confirmationDialog.
///     Editing happens here, so the user is already engaged and a per-run
///     prompt is acceptable.
///   - Panel (ScriptsPanelView): a quick-launch surface, so it only nags once
///     per script (an in-memory Set<UUID> of confirmed script ids). After the
///     first confirmation for a given script it runs directly until the panel
///     is rebuilt. This keeps the panel fast while still warning the first time
///     arbitrary code is executed from a passive surface.
struct Script: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var interpreter: ScriptInterpreter
    var body: String
    /// When true, the runner feeds the active clip's text on stdin and in the
    /// CLIPPY_CLIP environment variable.
    var feedsClipboard: Bool
    /// When true, the script's stdout is offered as a new clip after it runs.
    var outputToClipboard: Bool
    var createdAt: Date
    var updatedAt: Date
    /// User-defined display order. Lower values appear first. Defaults to 0 so
    /// JSON saved by older builds (which have no sortOrder key) migrates cleanly
    /// via `decodeIfPresent ?? 0`.
    var sortOrder: Int
    /// A disabled script cannot run: `ScriptRunner` refuses it and the panel
    /// greys it out. This exists because scripts can be created over MCP, and a
    /// clipboard manager that executes shell written by whatever is connected to
    /// it is a remote code execution path. Anything created outside the app lands
    /// disabled and stays that way until a human enables it in Settings.
    ///
    /// Defaults to true, and old JSON without the key decodes to true, so
    /// existing scripts keep working across the upgrade.
    var isEnabled: Bool
    /// Arguments passed to the script after its file path (`$1`, `sys.argv[1]`,
    /// `process.argv[2]`, AppleScript `argv`). Edited as one shell-quoted line.
    var arguments: [String]
    /// Directory the script runs in. Empty means the user's home directory.
    var workingDirectory: String
    /// Extra environment variables, layered over the inherited environment.
    /// `CLIPPY_*` names are reserved and always win.
    var environment: [String: String]
    /// Absolute path (or `~/...`) of the interpreter to use instead of the one
    /// resolved from PATH. Empty means resolve automatically.
    var customInterpreterPath: String
    /// Seconds before the run is stopped. 0 disables the timeout.
    var timeoutSeconds: Int
    /// When true, every launch surface asks before running, including the panel
    /// (which otherwise nags once per script per session).
    var confirmBeforeRun: Bool
    /// Text fed to stdin when no clipboard text is supplied to the run.
    var stdinText: String

    /// Default per-script timeout, matching the previous hard-coded value.
    static let defaultTimeoutSeconds = 30

    init(id: UUID = UUID(),
         name: String,
         interpreter: ScriptInterpreter = .zsh,
         body: String = "",
         feedsClipboard: Bool = false,
         outputToClipboard: Bool = false,
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         sortOrder: Int = 0,
         isEnabled: Bool = true,
         arguments: [String] = [],
         workingDirectory: String = "",
         environment: [String: String] = [:],
         customInterpreterPath: String = "",
         timeoutSeconds: Int = Script.defaultTimeoutSeconds,
         confirmBeforeRun: Bool = false,
         stdinText: String = "") {
        self.id = id
        self.name = name
        self.interpreter = interpreter
        self.body = body
        self.feedsClipboard = feedsClipboard
        self.outputToClipboard = outputToClipboard
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortOrder = sortOrder
        self.isEnabled = isEnabled
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.customInterpreterPath = customInterpreterPath
        self.timeoutSeconds = timeoutSeconds
        self.confirmBeforeRun = confirmBeforeRun
        self.stdinText = stdinText
    }

    // MARK: - Codable with migration

    enum CodingKeys: String, CodingKey {
        case id, name, interpreter, body, feedsClipboard, outputToClipboard
        case createdAt, updatedAt, sortOrder, isEnabled
        case arguments, workingDirectory, environment, customInterpreterPath
        case timeoutSeconds, confirmBeforeRun, stdinText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        interpreter = try container.decode(ScriptInterpreter.self, forKey: .interpreter)
        body = try container.decode(String.self, forKey: .body)
        feedsClipboard = try container.decode(Bool.self, forKey: .feedsClipboard)
        outputToClipboard = try container.decode(Bool.self, forKey: .outputToClipboard)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        // Old JSON has no sortOrder; default to 0 so migration backfill runs in load().
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        // Old JSON has no isEnabled. Scripts that predate the flag were created in
        // the app by the user, so they stay runnable.
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        // Fields added for SCR-03/05/10/12. Every one is optional on disk so
        // scripts.json written by older builds keeps loading.
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        customInterpreterPath = try container.decodeIfPresent(String.self, forKey: .customInterpreterPath) ?? ""
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? Script.defaultTimeoutSeconds
        confirmBeforeRun = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeRun) ?? false
        stdinText = try container.decodeIfPresent(String.self, forKey: .stdinText) ?? ""
    }

    // MARK: - Dirty check

    /// True when any user-editable field differs from `stored`. Identity and
    /// bookkeeping (`id`, `createdAt`, `updatedAt`, `sortOrder`) are excluded;
    /// everything else is compared so no edit can be silently discarded.
    func hasEditableChanges(comparedTo stored: Script) -> Bool {
        name != stored.name
            || interpreter != stored.interpreter
            || body != stored.body
            || feedsClipboard != stored.feedsClipboard
            || outputToClipboard != stored.outputToClipboard
            || isEnabled != stored.isEnabled
            || arguments != stored.arguments
            || workingDirectory != stored.workingDirectory
            || environment != stored.environment
            || customInterpreterPath != stored.customInterpreterPath
            || timeoutSeconds != stored.timeoutSeconds
            || confirmBeforeRun != stored.confirmBeforeRun
            || stdinText != stored.stdinText
    }

    /// A never-saved draft is dirty as soon as it differs from a blank script.
    var isDirtyDraft: Bool {
        hasEditableChanges(comparedTo: Script(id: id, name: ""))
    }

    // MARK: - Lossy array decode (SCR-07)

    /// The outcome of decoding a scripts array element by element.
    struct LossyDecode {
        var scripts: [Script]
        /// Raw JSON of every element that could not be decoded (or repeated an
        /// id already seen), suitable for writing to a quarantine file.
        var rejected: [Data]
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Decodes a JSON array of scripts one element at a time so a single bad
    /// entry cannot discard the rest. Throws only when the top level is not a
    /// JSON array at all.
    static func decodeLossy(_ data: Data, decoder: JSONDecoder = Script.makeDecoder()) throws -> LossyDecode {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "Expected a JSON array of scripts"))
        }
        var result = LossyDecode(scripts: [], rejected: [])
        var seen = Set<UUID>()
        for element in array {
            guard JSONSerialization.isValidJSONObject(element),
                  let raw = try? JSONSerialization.data(withJSONObject: element, options: [.sortedKeys]) else {
                if let raw = try? JSONSerialization.data(withJSONObject: [element], options: [.fragmentsAllowed]) {
                    result.rejected.append(raw)
                }
                continue
            }
            if let script = try? decoder.decode(Script.self, from: raw), seen.insert(script.id).inserted {
                result.scripts.append(script)
            } else {
                result.rejected.append(raw)
            }
        }
        return result
    }
}

// MARK: - Argument line parsing

/// Splits and joins the single-line argument field the editor shows. Supports
/// single quotes, double quotes, and backslash escapes; no expansion of any kind.
enum ScriptArguments {
    static func split(_ line: String) -> [String] {
        var args: [String] = []
        var current = ""
        var hasToken = false
        var quote: Character?
        var escaping = false
        for character in line {
            if escaping { current.append(character); escaping = false; hasToken = true; continue }
            if character == "\\" && quote != "'" { escaping = true; continue }
            if let quoteChar = quote {
                if character == quoteChar { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" { quote = character; hasToken = true; continue }
            if character.isWhitespace {
                if hasToken { args.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(character)
            hasToken = true
        }
        if hasToken { args.append(current) }
        return args
    }

    static func join(_ args: [String]) -> String {
        args.map { arg -> String in
            if arg.isEmpty { return "''" }
            let plain = arg.allSatisfy { !$0.isWhitespace && !"\"'\\".contains($0) }
            return plain ? arg : "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    /// `KEY=value` lines <-> dictionary, for the environment editor. Blank
    /// lines, `#` comments, and lines without `=` or with an invalid name are
    /// ignored on parse.
    static func parseEnvironment(_ text: String) -> [String: String] {
        var env: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equalsIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            guard let first = key.first, first.isLetter || first == "_",
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            env[key] = String(line[line.index(after: equalsIndex)...])
        }
        return env
    }

    static func formatEnvironment(_ env: [String: String]) -> String {
        env.keys.sorted().map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n")
    }
}

/// The outcome of a run, surfaced to the UI.
struct ScriptResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let durationMs: Int
    let timedOut: Bool
    /// True when output was capped at the size ceiling and the child was killed
    /// to drain the pipe. The output is valid (just truncated), so this is not a
    /// failure. Defaults to false so existing construction sites stay compatible.
    var truncated: Bool = false
    /// True when the user (or a Task cancel) stopped the run.
    var cancelled: Bool = false
    /// True when the run never started: disabled script, interpreter missing,
    /// bad working directory, or the spawn itself failed. `stderr` says why.
    var launchFailed: Bool = false
    /// Signal that ended the child (SIGTERM/SIGKILL after a timeout or cancel),
    /// nil for a normal exit. `exitCode` is `128 + signal` in that case.
    var terminationSignal: Int32? = nil

    // A truncation-kill yields a SIGTERM exit status, so exitCode != 0; treat it
    // as success since the captured output is complete up to the ceiling.
    var succeeded: Bool { (exitCode == 0 || truncated) && !timedOut && !cancelled && !launchFailed }

    /// The four user-visible end states. Timeout and cancel win over the exit
    /// code, since a killed child always exits non-zero.
    enum Outcome: String, Codable, Equatable { case success, failed, cancelled, timedOut }

    var outcome: Outcome {
        if cancelled { return .cancelled }
        if timedOut { return .timedOut }
        return succeeded ? .success : .failed
    }

    /// Per-stream character cap used by the output views. The runner ceiling is
    /// 5 MB; the view shows the tail-safe first slice so layout stays cheap.
    static let viewCap = 200_000

    /// Display cap applied to each stream in the UI so very large output does
    /// not flood the view. Distinct from `truncated` (a runner-side stream
    /// ceiling kill): this is a pure display concern. Shared by ScriptsView and
    /// ScriptsPanelView so both surfaces cap at the same width.
    static let displayCap = 2000

    /// Returns `stream` capped to `displayCap` characters with a trailing note
    /// when truncation was applied, e.g. "(showing first 2000 of 4500 characters)".
    /// Use for rendering stdout/stderr; never use this to decide success.
    static func displayCapped(_ stream: String) -> String {
        let cap = displayCap
        guard stream.count > cap else { return stream }
        let prefix = String(stream.prefix(cap))
        return prefix + "\n(showing first \(cap) of \(stream.count) characters)"
    }
}
