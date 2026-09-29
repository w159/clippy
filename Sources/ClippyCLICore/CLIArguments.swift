import Foundation

/// Output rendering for CLI results.
public enum CLIOutputMode: Equatable {
    case plain
    case json
}

/// A fully validated CLI invocation.
public enum CLICommand: Equatable {
    case help(topic: String?)
    case version
    case search(query: String, limit: Int)
    case get(id: Int64)
    case add(text: String)
    case list(limit: Int, kind: String?)
    case stats
}

/// Options shared by every subcommand.
public struct CLIInvocation: Equatable {
    public var command: CLICommand
    public var output: CLIOutputMode
    /// `--db` override; nil means the app's default database path.
    public var databasePath: String?
}

/// Argument errors; all map to exit code 2.
public enum CLIParseError: Error, Equatable {
    case missingCommand
    case unknownCommand(String)
    case unknownOption(String)
    case missingValue(String)
    case invalidValue(option: String, value: String)
    case missingArgument(String)
    case unexpectedArgument(String)
    case textTooLarge
}

/// Pure, library-free parser for `clippy <command> [options]`.
public enum CLIArguments {
    /// Default and maximum `--limit`.
    public static let defaultLimit = 20
    public static let maxLimit = 500
    /// Matches the URL scheme's payload cap, since `add` travels over `clippy://`.
    public static let maxAddBytes = 64 * 1024
    public static let maxQueryLength = 500
    static let kinds: Set<String> = ["text", "image", "file"]
    static let commands = ["search", "get", "add", "list", "stats", "help", "version"]

    /// Parses `arguments` (without argv[0]). `--` ends option parsing.
    public static func parse(_ arguments: [String]) -> Result<CLIInvocation, CLIParseError> {
        var output = CLIOutputMode.plain
        var database: String?
        var limit: Int?
        var kind: String?
        var positionals: [String] = []
        var wantsHelp = false
        var wantsVersion = false
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let arg = arguments[index]
            index += 1
            if optionsEnded || !arg.hasPrefix("-") || arg == "-" { positionals.append(arg); continue }
            switch arg {
            case "--": optionsEnded = true
            case "-h", "--help": wantsHelp = true
            case "--version": wantsVersion = true
            case "--json": output = .json
            case "--plain": output = .plain
            case "--db", "--limit", "-n", "--kind":
                guard index < arguments.count else { return .failure(.missingValue(arg)) }
                let value = arguments[index]
                index += 1
                switch arg {
                case "--db":
                    guard !value.isEmpty else { return .failure(.invalidValue(option: arg, value: value)) }
                    database = value
                case "--kind":
                    guard kinds.contains(value) else { return .failure(.invalidValue(option: arg, value: value)) }
                    kind = value
                default:
                    guard let parsed = Int(value), (1...maxLimit).contains(parsed) else {
                        return .failure(.invalidValue(option: arg, value: value))
                    }
                    limit = parsed
                }
            default: return .failure(.unknownOption(arg))
            }
        }
        func done(_ command: CLICommand) -> Result<CLIInvocation, CLIParseError> {
            .success(CLIInvocation(command: command, output: output, databasePath: database))
        }
        if wantsVersion { return done(.version) }
        guard let name = positionals.first else {
            return wantsHelp ? done(.help(topic: nil)) : .failure(.missingCommand)
        }
        if wantsHelp || name == "help" { return done(.help(topic: name == "help" ? positionals.dropFirst().first : name)) }
        if name == "version" { return done(.version) }
        return build(name, Array(positionals.dropFirst()), limit: limit, kind: kind, done)
    }

    private static func build(_ name: String, _ rest: [String], limit: Int?, kind: String?,
                              _ done: (CLICommand) -> Result<CLIInvocation, CLIParseError>)
        -> Result<CLIInvocation, CLIParseError> {
        switch name {
        case "search":
            guard !rest.isEmpty else { return .failure(.missingArgument("query")) }
            let query = rest.joined(separator: " ")
            guard query.count <= maxQueryLength else { return .failure(.invalidValue(option: "query", value: "too long")) }
            return done(.search(query: query, limit: limit ?? defaultLimit))
        case "get":
            guard let raw = rest.first else { return .failure(.missingArgument("id")) }
            guard rest.count == 1 else { return .failure(.unexpectedArgument(rest[1])) }
            guard raw.allSatisfy({ $0.isASCII && $0.isNumber }), raw.count <= 18, let identifier = Int64(raw),
                  identifier > 0 else { return .failure(.invalidValue(option: "id", value: raw)) }
            return done(.get(id: identifier))
        case "add":
            guard !rest.isEmpty else { return .failure(.missingArgument("text")) }
            let text = rest.joined(separator: " ")
            guard text.utf8.count <= maxAddBytes else { return .failure(.textTooLarge) }
            guard !text.unicodeScalars.contains("\u{0}") else { return .failure(.invalidValue(option: "text", value: "NUL")) }
            return done(.add(text: text))
        case "list":
            if let extra = rest.first { return .failure(.unexpectedArgument(extra)) }
            return done(.list(limit: limit ?? defaultLimit, kind: kind))
        case "stats":
            if let extra = rest.first { return .failure(.unexpectedArgument(extra)) }
            return done(.stats)
        default:
            return .failure(.unknownCommand(name))
        }
    }

    /// Usage text for `--help`.
    public static let usage = """
    clippy - command line access to the Clippy clipboard history

    USAGE: clippy <command> [options]

    COMMANDS:
      search <query>   Full-text search (words are ANDed; "quoted phrases" supported)
      get <id>         Print one clip's text (metadata only for images/files)
      add <text>       Add a text clip via the app (clippy://add; the app may ask to allow it)
      list             Newest clips first
      stats            Counts by kind (sensitive clips are counted, never shown)

    OPTIONS:
      --json           JSON output (default: plain text)
      --limit, -n <N>  Max results for search/list (1-500, default 20)
      --kind <k>       list filter: text | image | file
      --db <path>      Database file (default: ~/Library/Application Support/Clippy/clippy.sqlite)
      -h, --help       Show this help
      --version        Show version

    Reads open the database read-only and never return sensitive clips.
    Writes go through the running app so its rules apply.

    EXIT CODES: 0 ok, 1 runtime error, 2 usage error, 3 not found, 4 withheld (sensitive)
    """
}

// MARK: - Error text and URL building

public extension CLIArguments {
    /// Human-readable text for a parse error (never echoes long values).
    static func describe(_ error: CLIParseError) -> String {
        switch error {
        case .missingCommand: return "missing command"
        case .unknownCommand(let name): return "unknown command '\(name.prefix(40))'"
        case .unknownOption(let name): return "unknown option '\(name.prefix(40))'"
        case .missingValue(let name): return "option \(name) needs a value"
        case .invalidValue(let option, let value): return "invalid value for \(option): '\(value.prefix(40))'"
        case .missingArgument(let name): return "missing <\(name)>"
        case .unexpectedArgument(let name): return "unexpected argument '\(name.prefix(40))'"
        case .textTooLarge: return "text exceeds \(maxAddBytes) bytes"
        }
    }
}

/// Builds `clippy://` URLs for writes (same encoding as the app's `ClippyURL.url`).
public enum ClippyURLBuilder {
    /// `clippy://add?text=<percent-encoded>`.
    public static func addURL(text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#%")
        return "clippy://add?text=" + (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }
}
