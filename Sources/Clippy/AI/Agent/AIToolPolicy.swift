import Foundation

/// What happens when the model calls a tool (AI-07).
enum AIToolPolicy: String, Codable, CaseIterable, Identifiable {
    /// Run without asking.
    case always
    /// Show the exact call and wait for the user.
    case ask
    /// Refuse without asking; the model is told the user has disabled the tool.
    case never

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .always: return "Always allow"
        case .ask:    return "Ask each time"
        case .never:  return "Never allow"
        }
    }

    /// Tools that write data or run code ask by default; read-only tools run.
    static func defaultPolicy(for toolName: String) -> AIToolPolicy {
        askByDefault.contains(toolName) ? .ask : .always
    }

    static let askByDefault: Set<String> = ["create_clip", "set_clip_category", "execute_code", "run_script"]
}

/// Persisted per-tool policy. Keys are `aiToolPolicy.<tool name>` in UserDefaults;
/// a missing key means the default for that tool.
struct AIToolPolicyStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func policy(for toolName: String) -> AIToolPolicy {
        defaults.string(forKey: Self.key(toolName)).flatMap(AIToolPolicy.init(rawValue:))
            ?? AIToolPolicy.defaultPolicy(for: toolName)
    }

    func set(_ policy: AIToolPolicy, for toolName: String) {
        defaults.set(policy.rawValue, forKey: Self.key(toolName))
    }

    private static func key(_ toolName: String) -> String { "aiToolPolicy.\(toolName)" }
}

/// Wraps a tool so its policy is applied before it runs. The confirmation text
/// shows the complete call, never a truncation (AI-07).
struct PolicyGatedTool: AITool {
    let base: AITool
    let policy: AIToolPolicy
    /// Shows the description and full argument text; resolves true to allow.
    let confirm: (_ toolName: String, _ detail: String) async -> Bool

    var name: String { base.name }
    var description: String { base.description }
    var parametersSchema: [String: Any] { base.parametersSchema }

    func execute(args: [String: Any]) async throws -> String {
        switch policy {
        case .always:
            return try await base.execute(args: args)
        case .never:
            return "The user has disabled the \(name) tool. Do not retry it; tell the user you cannot do this."
        case .ask:
            let allowed = await confirm(name, Self.describe(toolName: name, args: args))
            guard allowed else { return "The user declined the \(name) call." }
            return try await base.execute(args: args)
        }
    }

    /// Human-readable, complete rendering of a call. `code` and `text` bodies are
    /// shown verbatim on their own lines so long code is fully reviewable.
    static func describe(toolName: String, args: [String: Any]) -> String {
        var lines = ["Tool: \(toolName)"]
        for key in args.keys.sorted() {
            let value = args[key]
            if let text = value as? String, text.contains("\n") || text.count > 60 {
                lines.append("\(key):\n\(text)")
            } else {
                lines.append("\(key): \(value.map { "\($0)" } ?? "nil")")
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension AIToolPolicy {
    /// Wrap `tools` with their policies. `.never` tools are dropped entirely so the
    /// model never sees them; the rest are gated per policy. Sorted by name so the
    /// order shown in the drawer and sent to the model is stable.
    static func apply(to tools: [AITool], store: AIToolPolicyStore,
                      confirm: @escaping (_ toolName: String, _ detail: String) async -> Bool) -> [AITool] {
        tools.sorted { $0.name < $1.name }.compactMap { tool in
            let policy = store.policy(for: tool.name)
            guard policy != .never else { return nil }
            return PolicyGatedTool(base: tool, policy: policy, confirm: confirm)
        }
    }
}
