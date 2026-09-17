# Roadmap

Deferred / follow-up items, prioritized. Sourced from verifier reports and audit rows
not closed in the 2026-06-12 wave (details in .orchestrator/ evidence and findings).

## High value
- **Tool calling for the Apple Intelligence provider.** The provider shipped in v1.9.0
  with completion and streaming, but `completeWithTools` / `streamWithTools` ignore the
  tool list and return plain text. Foundation Models declares tools as compile-time
  `Tool` conformances over `@Generable` argument structs, while `AITool` carries a JSON
  schema decided at runtime; there is no honest mapping without reshaping the tool layer.
  Options, in increasing order of work: hand-write a `@Generable` struct per built-in
  tool and register only those (search_clips, create_clip, set_category are the ones that
  matter); or make `AITool` generic over a `Codable` argument type and derive the JSON
  schema from it, so both provider families read from one declaration. Until then the
  assistant panel cannot call Clippy's own tools on this provider, which the type
  documents and the log states per turn.
- MLX via `mlx-swift`: a second on-device provider with model selection / download /
  management; add `mlx-swift` to Package.swift after confirming its minimum platform.
  Lower priority now that Apple Intelligence covers the on-device case with no download.
- **Auto-filing suggestions into categories.** 93% of clips are uncategorized (600 of
  644 at the time of the 2026-09-16 audit), so the sidebar's organizing model is not
  being used. With a local model this can suggest a category per clip at capture and
  file it on accept. Reuses the on-device gate already in place for auto-titling.
- **Sensitive-content detection on capture.** A local classifier flagging API keys,
  account numbers, and similar, marking the clip so it is excluded from MCP reads and
  from iCloud sync. This is a compliance control rather than a convenience, and it is
  the most defensible AI feature in the app.
- **Semantic search.** FTS5 prefix matching cannot find "the postgres connection string"
  when the clip reads `DATABASE_URL=...`. Local embeddings over `contentText` stored in
  the same SQLite file, hybrid-ranked with the existing FTS results.
- AppSettings/stores migration from `ObservableObject`/`@Published` to
  `@Observable` + `@State`/`@Bindable` (deferred; internal). CRITICAL ordering:
  rewire the Combine `$` projections (`ClipboardMonitor.$pollingIntervalMs`,
  `McpServerController.$mcpEnabled`/`$mcpPort`) to onChange/streams BEFORE removing
  `@Published`, and mark the `@Observable` classes `@MainActor`.
- AI vision: send image clips to multimodal providers (native Vision OCR shipped; AI-based
  extraction/description is the complement).
- Real sandbox for execute_code (sandbox-exec / restricted environment); today the control
  is per-call confirmation + 30s timeout, described honestly in the UI.
- Assistant conversation persistence across app restarts (in-memory per session today).

## UI (from the 2026-09-16 audit; deferred because none of it can be verified headlessly)
- Split `ClipListView` (1506 lines) and `SettingsView` (1720) against the project's own
  300-line ceiling. `ClipListView` currently owns sectioning, card rendering, the AI
  action menu, AI proposal handling, OCR, the status banner, timeline reveal, batch
  delete, batch titling, keyboard selection, and paste. No behavior change; do it first,
  because every item below touches it.
- Rebuild the clip card: content as the headline, source app demoted to a small icon in
  the metadata row. Today the largest text on each card is the app name, so 93% of cards
  lead with "Microsoft Edge Dev" instead of what was copied.
- Compact row mode (~32px), default for the History pane. Seven clips currently fill a
  full-height window, which does not scale to a 644-clip history.
- Drop the per-card colored stroke; give the stroke to selection alone. Right now
  decoration and selection compete for the same signal.
- Adopt the standard macOS material for the panel background and system list selection.
- A preview pane, so selecting a clip shows it in full without opening the editor.
- Kind / source-app / date-range filter chips, replacing the `#kind` syntax currently
  hidden in the search field.

## Medium
- "Save as clip" for failed script runs with useful stdout (currently success-only).
- Semantic success/danger theme tokens, then migrate remaining systemGreen/systemRed
  usages in ScriptsPanelView and CategorySidePane.
- Deep-link "Manage Scripts..." to the exact Settings tab (opens Settings root today).
- 1Password: optional `op signin` / account switching; custom op binary path setting.
- Custom hotkey recording (binding currently fixed).
- Route MCP mutations through the app instead of writing SQLite directly. v1.9.0 closed
  the visibility gap with `ExternalChangeWatcher`, but there are still two writers, and
  the app's invariants (history cap, eviction, media sweeping) do not apply to MCP
  writes. Revisit when those start to matter.
- Raise the default log level or add a diagnostics toggle: 27 INFO and 22 WARN lines
  against 1313 ERROR over three months means the log cannot answer a capture question,
  which is why the June sound investigation needed external probe scripts.
- Keep the test suite out of the user's production log (`test-above-<UUID>` entries).

## Low
- error-path coverage for saveScriptOutput (bad-DB branch untested).
- MCP server lifecycle management in-app (start/stop/status of clippy-mcp).
- Retire the five deprecated MCP tool aliases (`clippy_search`, `clippy_get`,
  `clippy_add`, `clippy_delete`, `clippy_set_category`) once pinned client configs have
  moved to the new names.
