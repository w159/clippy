import Foundation

/// SEC-08: records every tool call the assistant executes to the audit log.
///
/// Only metadata is written: the tool name, the argument KEY names, any clip id
/// argument, and the outcome. Argument values, clip text and tool output never
/// reach the log.
struct AuditedTool: AITool {
    let base: AITool

    var name: String { base.name }
    var description: String { base.description }
    var parametersSchema: [String: Any] { base.parametersSchema }

    func execute(args: [String: Any]) async throws -> String {
        do {
            let result = try await base.execute(args: args)
            Self.record(tool: name, args: args, decision: "allowed", outcome: "ok")
            return result
        } catch {
            Self.record(tool: name, args: args, decision: "allowed", outcome: "error")
            throw error
        }
    }

    /// Detail string: names only, never values.
    static func detail(tool: String, args: [String: Any], decision: String, outcome: String) -> String {
        let keys = args.keys.sorted().joined(separator: ",")
        return "tool=\(tool) args=[\(keys)] decision=\(decision) outcome=\(outcome)"
    }

    /// Clip ids named by well-known integer arguments.
    static func clipIDs(in args: [String: Any]) -> [Int64] {
        AIToolHelpers.int64Value(args["clip_id"]).map { [$0] } ?? []
    }

    static func record(tool: String, args: [String: Any], decision: String, outcome: String) {
        AuditLog.shared.record(actor: "assistant", action: "tool.call",
                               detail: detail(tool: tool, args: args, decision: decision, outcome: outcome),
                               clipIDs: clipIDs(in: args))
    }

    /// The user (or policy) refused a call that never reached the tool.
    static func recordDenied(tool: String) {
        AuditLog.shared.record(actor: "assistant", action: "tool.call",
                               detail: "tool=\(tool) args=[] decision=denied outcome=none",
                               clipIDs: [])
    }
}

/// Binds the UI-backed confirmation prompts into `execute_code` so the network
/// grant and the unsandboxed fallback each need an explicit user answer.
enum AssistantSandboxHooks {
    static func bind(_ tools: [AITool],
                     confirm: @escaping (_ toolName: String, _ detail: String) async -> Bool) -> [AITool] {
        tools.map { tool in
            guard var code = tool as? ExecuteCodeTool else { return tool }
            code.networkConfirmHook = { detail in await confirm("execute_code (network)", detail) }
            code.unsandboxedConfirmHook = { detail in await confirm("execute_code (no sandbox)", detail) }
            return code
        }
    }

    /// Audit-wrap every tool.
    static func audited(_ tools: [AITool]) -> [AITool] { tools.map { AuditedTool(base: $0) } }
}
