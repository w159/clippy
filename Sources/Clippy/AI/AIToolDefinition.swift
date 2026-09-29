import Foundation

// MARK: - Tool protocol

/// A tool the agent loop may call. The engine serializes `parameters` into the
/// provider's function-calling schema; `execute` runs on the app side and returns
/// a plain-text result (or an error description) for the model to read.
///
/// `execute` receives the raw JSON-decoded argument dictionary that the model
/// filled in. Return a string of at most `AIToolDefinition.maxResultBytes` bytes;
/// the engine truncates longer outputs before feeding them back.
protocol AITool {
    var name: String { get }
    var description: String { get }
    /// JSON Schema object describing the function's parameters.
    var parametersSchema: [String: Any] { get }
    func execute(args: [String: Any]) async throws -> String
}

extension AITool {
    /// Serialise this tool into the OpenAI / Ollama / Azure function-calling
    /// wire format: `{ type, function: { name, description, parameters } }`.
    var openAIFunctionSpec: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parametersSchema,
            ] as [String: Any],
        ]
    }

    /// Serialise into the Anthropic tools array format:
    /// `{ name, description, input_schema }`.
    var anthropicToolSpec: [String: Any] {
        [
            "name": name,
            "description": description,
            "input_schema": parametersSchema,
        ]
    }
}

// MARK: - Registry

/// Central registry for tools available to the agent loop.
/// Register tools once at startup; the loop queries via name at runtime.
final class AIToolRegistry {
    private var tools: [String: AITool] = [:]

    func register(_ tool: AITool) {
        tools[tool.name] = tool
    }

    func tool(named name: String) -> AITool? {
        tools[name]
    }

    var all: [AITool] { Array(tools.values) }
}

// MARK: - Safety constants

extension AITool {
    /// Truncate tool results to this many bytes before feeding back to the model.
    static var maxResultBytes: Int { AIToolHelpers.maxResultBytes }
}

/// Free-function helpers for tool implementations. Using a free enum instead of
/// a protocol extension avoids the "static member cannot be used on protocol
/// metatype" limitation in Swift.
enum AIToolHelpers {
    static let maxResultBytes = 4096

    /// Decode an integer tool argument. JSONSerialization surfaces numbers as
    /// Int, Int64, Double, or NSNumber depending on the payload, and some models
    /// send ids as strings; accept all of them.
    static func int64Value(_ any: Any?) -> Int64? {
        switch any {
        case let value as Int64:  return value
        case let value as Int:    return Int64(value)
        case let value as Double: return value.truncatingRemainder(dividingBy: 1) == 0 ? Int64(value) : nil
        case let value as String: return Int64(value)
        case let value as NSNumber: return value.int64Value
        default: return nil
        }
    }

    static func truncate(_ text: String) -> String {
        guard text.utf8.count > maxResultBytes else { return text }
        // Slice to maxResultBytes UTF-8 units. Using Data -> String avoids the
        // broken-trailing-byte problem: String(data:encoding:) returns nil when
        // the boundary falls inside a multi-byte sequence; drop 1 byte at a time
        // until it succeeds (at most 3 iterations for any valid UTF-8 codepoint).
        var count = maxResultBytes
        while count > 0 {
            let slice = Data(text.utf8.prefix(count))
            if let decoded = String(data: slice, encoding: .utf8) {
                return decoded + "\n[result truncated]"
            }
            count -= 1
        }
        return String(text.prefix(maxResultBytes)) + "\n[result truncated]"
    }
}

// MARK: - Built-in tools

// MARK: search_clips

/// Search the clip database by full-text query. Returns up to 10 matching clip
/// texts, separated by a numbered list.
struct SearchClipsTool: AITool {
    let name = "search_clips"
    let description = "Search the Clippy clipboard history by text. Returns up to 10 matching snippets with their clip ids; pass an id to get_clip for the full content."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": [
                "type": "string",
                "description": "Text to search for in the clipboard history.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["query"],
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let query = args["query"] as? String, !query.isEmpty else {
            return "Error: query parameter is required."
        }
        let clips = try ClipDatabase.shared.searchClips(matching: query, limit: 10)
        if clips.isEmpty { return "No clips found matching \"\(query)\"." }
        return clips.enumerated().map { (i, clip) -> String in
            // Surface the id so follow-up tools (get_clip, set_clip_category)
            // can address the exact clip instead of re-searching.
            let idTag = clip.id.map { "[id \($0)] " } ?? ""
            return "\(i + 1). \(idTag)\(AIService.clamp(clip.contentText, 200))"
        }.joined(separator: "\n")
    }
}

// MARK: create_clip

/// Insert a new text clip into the database.
struct CreateClipTool: AITool {
    let name = "create_clip"
    let description = "Save a new text snippet to the Clippy clipboard history."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "text": [
                "type": "string",
                "description": "The text content of the new clip.",
            ] as [String: Any],
            "title": [
                "type": "string",
                "description": "Optional short title for the clip.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["text"],
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return "Error: text parameter is required."
        }
        let id = try ClipDatabase.shared.insertTextClip(text)
        return "Clip created with id \(id)."
    }
}

// MARK: get_clip

/// Fetch one clip by id and return its full content plus basic metadata.
/// Complements search_clips, whose results are clamped to 200-character snippets.
struct GetClipTool: AITool {
    let name = "get_clip"
    let description = "Fetch a single clip from the Clippy clipboard history by its id and return its full content. Use the ids returned by search_clips."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "clip_id": [
                "type": "integer",
                "description": "The id of the clip to fetch.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["clip_id"],
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let clipID = AIToolHelpers.int64Value(args["clip_id"]) else {
            return "Error: clip_id parameter is required and must be an integer."
        }
        guard let clip = try ClipDatabase.shared.clip(withID: clipID) else {
            return "Error: no clip with id \(clipID)."
        }
        let header = "Clip \(clipID): \"\(clip.displayTitle)\" (\(clip.contentKind.rawValue), created \(clip.createdAt.formatted()))"
        return AIToolHelpers.truncate("\(header)\n\(clip.contentText)")
    }
}

// MARK: set_clip_category

/// Assign an existing clip to a category by name. Creates the category only
/// when the model explicitly asks via create_if_missing (i.e. the user asked).
struct SetClipCategoryTool: AITool {
    let name = "set_clip_category"
    let description = "Assign a clip in the Clippy clipboard history to a category by name. The category must already exist unless create_if_missing is true."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "clip_id": [
                "type": "integer",
                "description": "The id of the clip to categorize.",
            ] as [String: Any],
            "category": [
                "type": "string",
                "description": "The name of the category to assign the clip to.",
            ] as [String: Any],
            "create_if_missing": [
                "type": "boolean",
                "description": "Create the category when it does not exist. Set true only when the user explicitly asked to create it.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["clip_id", "category"],
    ]

    func execute(args: [String: Any]) async throws -> String {
        guard let clipID = AIToolHelpers.int64Value(args["clip_id"]) else {
            return "Error: clip_id parameter is required and must be an integer."
        }
        guard let rawName = args["category"] as? String,
              !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: category parameter is required."
        }
        let categoryName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard try ClipDatabase.shared.clip(withID: clipID) != nil else {
            return "Error: no clip with id \(clipID)."
        }

        let existing = try ClipDatabase.shared.categories()
        let category: Category
        if let match = existing.first(where: { $0.name.caseInsensitiveCompare(categoryName) == .orderedSame }) {
            category = match
        } else if args["create_if_missing"] as? Bool == true {
            // Same defaults the editor uses when creating from a suggestion.
            category = try ClipDatabase.shared.createCategory(
                named: categoryName,
                colorHex: CategoryPalette.hexes[0],
                iconKind: .symbol,
                iconValue: "pin.fill"
            )
        } else {
            let names = existing.map(\.name).joined(separator: ", ")
            return "Error: no category named \"\(categoryName)\". Existing categories: \(names.isEmpty ? "none" : names)."
        }

        guard let categoryID = category.id else {
            return "Error: category \"\(category.name)\" has no id."
        }
        try ClipDatabase.shared.setClip(clipID, inCategory: categoryID, true)
        return "Clip \(clipID) assigned to category \"\(category.name)\"."
    }
}

// MARK: list_scripts

/// List the names of all stored scripts.
struct ListScriptsTool: AITool {
    let name = "list_scripts"
    let description = "List all scripts saved in Clippy's script library by name."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [:] as [String: Any],
        "required": [] as [String],
    ]

    let scriptStore: ScriptStore

    func execute(args: [String: Any]) async throws -> String {
        let names = await scriptStore.scripts.map(\.name)
        if names.isEmpty { return "No scripts are saved." }
        return names.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}

// MARK: run_script

/// Run a stored script by name. Always gated by the caller-supplied confirmation
/// hook; the tool returns a denial message if the hook returns false.
struct RunScriptTool: AITool {
    let name = "run_script"
    let description = "Run one of the user's saved Clippy scripts. The user must confirm before execution."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "script_name": [
                "type": "string",
                "description": "The exact name of the script to run.",
            ] as [String: Any],
            "input": [
                "type": "string",
                "description": "Optional text to pass to the script on stdin.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["script_name"],
    ]

    let scriptStore: ScriptStore
    /// Async confirmation hook — UI layer sets this to show an alert.
    let confirmHook: (String) async -> Bool

    func execute(args: [String: Any]) async throws -> String {
        guard let scriptName = args["script_name"] as? String else {
            return "Error: script_name parameter is required."
        }
        guard let script = await scriptStore.scripts.first(where: { $0.name == scriptName }) else {
            return "Error: no script named \"\(scriptName)\"."
        }
        let input = args["input"] as? String
        let allowed = await confirmHook("Run script \"\(script.name)\"?")
        guard allowed else {
            return "User declined to run script \"\(script.name)\"."
        }
        // Honors the user's per-script `sandboxed` opt-in (default off).
        let sandbox: ScriptSandbox? = SandboxScriptFlags().isSandboxed(script.id) ? ScriptSandbox() : nil
        let result = await ScriptRunner.run(script, input: input, timeout: 30, sandbox: sandbox)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        return AIToolHelpers.truncate(result.succeeded
            ? output
            : "Script failed (exit \(result.exitCode)): \(output)")
    }
}

// MARK: execute_code

/// Materialize a transient script from the model-generated code and run it via
/// ScriptRunner inside a `sandbox-exec` sandbox (SEC-07): network denied unless the
/// call asks for it and the user approves, filesystem read-only except a per-run
/// scratch directory. ALWAYS gated by the confirmation hook. If the sandbox is
/// unavailable the run is refused unless the user explicitly confirms running
/// without it; it never silently degrades.
struct ExecuteCodeTool: AITool {
    let name = "execute_code"
    let description = "Execute code generated by the AI. The user must confirm before each execution. "
        + "The code runs in a sandbox with no network access and a read-only filesystem (only a temporary scratch directory is writable), with a 30-second timeout. "
        + "Set allow_network only if the code genuinely needs the network; the user must approve that separately."

    let parametersSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "language": [
                "type": "string",
                "enum": ["zsh", "bash", "python3", "node", "ruby", "swift"],
                "description": "The interpreter to use.",
            ] as [String: Any],
            "code": [
                "type": "string",
                "description": "The code to execute.",
            ] as [String: Any],
            "allow_network": [
                "type": "boolean",
                "description": "Allow the code to use the network. Defaults to false; needs separate user approval.",
            ] as [String: Any],
        ] as [String: Any],
        "required": ["language", "code"],
    ]

    /// Async confirmation hook supplied by the UI layer.
    let confirmHook: (String) async -> Bool
    /// Asked when a call sets `allow_network`. Denies by default so a tool built
    /// without a UI can never open the network.
    var networkConfirmHook: (String) async -> Bool = { _ in false }
    /// Asked when the sandbox is unavailable. Denies by default (the run is refused).
    var unsandboxedConfirmHook: (String) async -> Bool = { _ in false }

    func execute(args: [String: Any]) async throws -> String {
        guard let languageRaw = args["language"] as? String,
              let interpreter = ScriptInterpreter(rawValue: languageRaw),
              let code = args["code"] as? String, !code.isEmpty else {
            return "Error: language and code parameters are required."
        }

        // Safety: always gate behind confirmation. The full code is shown, never a
        // truncated preview: approving code you cannot read in full is not consent.
        let wantsNetwork = (args["allow_network"] as? Bool) ?? false
        let allowed = await confirmHook("Execute \(languageRaw) code?\n\n\(code)")
        guard allowed else {
            return "User declined to execute the generated code."
        }
        if wantsNetwork {
            let networkAllowed = await networkConfirmHook(
                "Allow this \(languageRaw) code to use the network? It could send data off this Mac.")
            guard networkAllowed else {
                return "User declined network access for the generated code. Run it again without allow_network."
            }
        }

        var sandbox = ScriptSandbox(allowNetwork: wantsNetwork)
        if case .unavailable(let reason) = SandboxRunner.preflight() {
            let proceed = await unsandboxedConfirmHook(
                "The sandbox is unavailable (\(reason)). Run this code WITHOUT a sandbox, with full access to your files and network?")
            guard proceed else { return SandboxRunner.refusalMessage(reason: reason) }
            sandbox.confirmedUnsandboxedFallback = true
        }

        let transient = Script(
            name: "AI-generated (\(languageRaw))",
            interpreter: interpreter,
            body: code,
            feedsClipboard: false,
            outputToClipboard: false
        )
        let result = await ScriptRunner.run(transient, input: nil, timeout: 30, sandbox: sandbox)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        return AIToolHelpers.truncate(result.succeeded
            ? output
            : "Execution failed (exit \(result.exitCode)): \(output)")
    }
}
