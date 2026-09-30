import Foundation

// Searchable rows for the settings window. `id` matches the `.settingsRow(_:)` anchor in the pane.

enum SettingsSearchCatalog {
    private static func row(_ id: String, _ pane: SettingsPaneID, _ title: String, _ words: [String] = []) -> SettingsSearchEntry {
        SettingsSearchEntry(id: id, pane: pane.rawValue, title: title, keywords: words)
    }

    /// All rows, in pane order.
    static let entries: [SettingsSearchEntry] = general + appearance + capture + ai + integrations + others + features

    private static let general: [SettingsSearchEntry] = [
        row("general.launchAtLogin", .general, "Launch Clippy at login", ["startup", "login item", "boot"]),
        row("general.hotkey", .general, "Shortcuts", ["hotkey", "keyboard", "paste plain", "paste stack", "open panel", "record"]),
        row("general.statusItem", .general, "Menu bar icon click", ["status item", "menu", "left click"]),
        row("general.plainText", .general, "Paste as plain text by default", ["formatting", "rich text"]),
        row("general.moveToTop", .general, "Move pasted item to top of history", ["reorder"]),
        row("general.clickCopyOnly", .general, "Clicking a clip copies it without pasting", ["click"]),
        row("general.keystrokeSpeed", .general, "Keystroke typing speed", ["type", "send as keystrokes"]),
        row("general.keystrokeWarn", .general, "Confirm before typing long clips", ["characters", "confirmation"]),
        row("general.maxHistory", .general, "History size", ["keep", "limit", "items"]),
        row("general.multiCategory", .general, "Allow a clip in multiple categories", ["categories"]),
        row("general.hideClickAway", .general, "Hide panel when clicking away", ["dismiss"]),
        row("general.hideAfterPaste", .general, "Hide panel after pasting", ["close"]),
        row("general.escape", .general, "Escape closes the panel", ["esc"]),
        row("general.windowLevel", .general, "Panel window level", ["always on top", "float"]),
        row("general.pin", .general, "Pin panel open", ["pinned"]),
        row("general.logLevel", .general, "Log level", ["logging", "console", "verbose", "debug"]),
        row("general.externalEditor", .general, "External editor", ["edit in", "sublime", "bbedit", "vscode"]),
        row("general.reset", .general, "Reset all settings to defaults", ["restore", "factory"]),
    ]

    private static let appearance: [SettingsSearchEntry] = [
        row("appearance.theme", .appearance, "Theme", ["dark", "light", "preset"]),
        row("appearance.system", .appearance, "System appearance", ["match system", "dark mode"]),
        row("appearance.accent", .appearance, "Accent color", ["tint"]),
        row("appearance.opacity", .appearance, "Panel opacity", ["transparency", "glass", "blur"]),
        row("appearance.colors", .appearance, "Customize colors", ["hex", "override", "color picker"]),
        row("appearance.cardStyle", .appearance, "Card style", ["filled", "bordered", "plain"]),
        row("appearance.density", .appearance, "Density", ["rows", "comfortable", "cards", "compact", "layout"]),
        row("appearance.columns", .appearance, "Columns", ["grid", "layout", "auto"]),
        row("appearance.cardColor", .appearance, "Card color", ["source app", "tint"]),
        row("appearance.contrast", .appearance, "High-contrast card text", ["accessibility"]),
        row("appearance.appIcons", .appearance, "Show app icons on cards"),
        row("appearance.sectionHeaders", .appearance, "Group clips under date headers", ["timeline", "today"]),
        row("appearance.font", .appearance, "Font", ["typography", "family"]),
        row("appearance.fontSize", .appearance, "Font size", ["text size", "typography"]),
        row("appearance.position", .appearance, "Open panel at", ["position", "caret", "cursor"]),
        row("appearance.size", .appearance, "Panel size", ["width", "height", "remember"]),
    ]

    private static let capture: [SettingsSearchEntry] = [
        row("capture.polling", .capture, "Polling interval", ["monitor", "cpu"]),
        row("capture.images", .capture, "Capture copied images", ["screenshot"]),
        row("capture.imageSize", .capture, "Largest image to keep", ["megabytes"]),
        row("capture.files", .capture, "Capture copied files"),
        row("capture.fileSize", .capture, "Store file contents up to", ["megabytes"]),
        row("capture.sound", .capture, "Play sound on capture", ["audio", "volume"]),
        row("capture.ignoredApps", .capture, "Ignored apps", ["blocklist", "bundle id", "exclude"]),
        row("capture.onLaunch", .capture, "Capture clipboard on launch", ["startup"]),
        row("capture.typeBlocklist", .capture, "Ignored pasteboard types", ["uti", "blocklist"]),
        row("capture.sensitiveClear", .capture, "Auto-clear sensitive clips", ["password", "secret", "delete history"]),
        row("capture.pasteProfiles", .capture, "Paste behavior per app", ["plain text", "terminal", "override"]),
    ]

    private static let ai: [SettingsSearchEntry] = [
        row("ai.enabled", .ai, "Enable AI and agentic features", ["llm"]),
        row("ai.provider", .ai, "Providers: add, select, duplicate or remove", ["openai", "anthropic", "ollama", "azure", "apple intelligence", "local", "cloud", "aggregator"]),
        row("ai.advanced", .ai, "Advanced provider settings", ["headers", "temperature", "tokens", "reasoning", "timeouts"]),
        row("ai.body", .ai, "Extra body JSON"),
        row("ai.model", .ai, "Model"),
        row("ai.endpoint", .ai, "Endpoint URL", ["base url"]),
        row("ai.key", .ai, "API key", ["keychain", "secret"]),
        row("ai.test", .ai, "Test AI connection"),
        row("ai.autoTitle", .ai, "Auto-suggest a title for new clips"),
        row("ai.actions", .ai, "AI actions", ["prompts", "rewrite"]),
        row("ai.webSearch", .ai, "Allow AI to search the web", ["duckduckgo"]),
        row("ai.scripts", .ai, "Allow AI to run my scripts"),
        row("ai.code", .ai, "Allow AI to execute generated code", ["sandbox"]),
    ]

    private static let integrations: [SettingsSearchEntry] = [
        row("integrations.archive", .integrations, "Pinned archive", ["toml", "export", "import", "categories"]),
        row("integrations.history", .integrations, "Export history", ["json"]),
        row("integrations.onePassword", .integrations, "1Password", ["vault", "op cli"]),
        row("integrations.icloud", .integrations, "iCloud sync", ["icloud drive", "sync now"]),
        row("integrations.mcp", .integrations, "MCP server", ["model context protocol", "claude"]),
        row("integrations.mcpPort", .integrations, "MCP port", ["server"]),
        row("integrations.mcpToken", .integrations, "MCP token", ["rotate", "bearer", "authentication"]),
        row("integrations.mcpInstall", .integrations, "Install MCP for clients", ["cursor", "windsurf", "zed", "claude", "vscode"]),
    ]

    private static let features: [SettingsSearchEntry] = [
        row("preview", .preview, "Preview", ["quick look", "space bar", "link preview", "code preview", "preview column", "collections"]),
        row("pasteStack", .pasteStack, "Paste stack", ["queue", "collect", "paste next", "sequential", "multi paste"]),
        row("snippets", .snippets, "Snippets", ["text expansion", "abbreviation", "trigger", "expander", "placeholders", "templates"]),
        row("semantic", .semantic, "Semantic search", ["translate", "describe image", "auto file", "on-device", "meaning", "embeddings"]),
        row("automation", .automation, "Automation", ["url scheme", "clippy://", "command line", "cli", "shortcuts", "spotlight", "app intents"]),
    ]

    private static let others: [SettingsSearchEntry] = [
        row("security", .security, "Security", ["app lock", "audit log", "retention", "sensitive"]),
        row("data", .data, "Data", ["backup", "database", "retention"]),
        row("intelligence", .intelligence, "Smart suggestions", ["suggestions", "on-device"]),
        row("ocr", .ocr, "OCR languages", ["text recognition", "vision"]),
        row("editor", .editor, "Editor", ["rich text", "code"]),
        row("scripts", .scripts, "Scripts", ["shell", "automation", "sandbox"]),
        row("about", .about, "About Clippy", ["version", "build", "licenses", "updates", "diagnostics"]),
    ]
}
