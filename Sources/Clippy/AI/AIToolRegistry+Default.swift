import Foundation

// MARK: - Default registry factory

extension AIToolRegistry {
    /// Build a registry with all built-in tools wired to the shared stores and
    /// the supplied confirmation hook. The UI layer passes a hook that shows an
    /// alert; tests pass a closure that returns a fixed bool.
    @MainActor
    static func makeDefault(confirmHook: @escaping (String) async -> Bool) -> AIToolRegistry {
        let registry = AIToolRegistry()
        registry.register(SearchClipsTool())
        registry.register(CreateClipTool())
        registry.register(GetClipTool())
        registry.register(SetClipCategoryTool())
        registry.register(WebSearchTool())
        registry.register(ListScriptsTool(scriptStore: .shared))
        registry.register(RunScriptTool(scriptStore: .shared, confirmHook: confirmHook))
        registry.register(ExecuteCodeTool(confirmHook: confirmHook))
        return registry
    }

    /// Build a registry filtered by the two agent safety toggles. When a toggle
    /// is off the corresponding tool is simply not registered, so the model never
    /// sees it in the schema and cannot attempt to call it.
    @MainActor
    static func makeFiltered(
        allowScripts: Bool,
        allowCodeExecution: Bool,
        allowWebSearch: Bool,
        confirmHook: @escaping (String) async -> Bool
    ) -> AIToolRegistry {
        let registry = AIToolRegistry()
        registry.register(SearchClipsTool())
        registry.register(CreateClipTool())
        registry.register(GetClipTool())
        registry.register(SetClipCategoryTool())
        if allowWebSearch {
            registry.register(WebSearchTool())
        }
        if allowScripts {
            registry.register(ListScriptsTool(scriptStore: .shared))
            registry.register(RunScriptTool(scriptStore: .shared, confirmHook: confirmHook))
        }
        if allowCodeExecution {
            registry.register(ExecuteCodeTool(confirmHook: confirmHook))
        }
        return registry
    }
}
