# Changelog

## 2026-06-23 - UI-freeze fixes (capture/search off main thread), status-bar icon, AI Actions panel nav, duplicate-file cleanup

### Fixed
- Clipboard capture no longer blocks the UI: text/file/image DB writes moved off the
  main thread onto a serial `captureQueue` (DispatchQueue .userInitiated). Sources/Clippy/Capture/ClipboardMonitor.swift:29
  (queue declaration), :131/:218/:287 (async dispatch sites). Thread-safety holds:
  all four DB methods touch only the serial GRDB DatabaseQueue
  (Sources/Clippy/Storage/ClipDatabase.swift:122); @Published hops back to MainActor.
- FTS search no longer blocks the UI: `searchClips` now runs on a background queue with
  a monotonic `refilterToken` that discards stale results when the query changes mid-flight.
  Sources/Clippy/UI/ClipStore.swift:37 (token), :390-402 (background dispatch),
  :376 (MainActor.run hop). Closes the 2026-06-22 audit finding at
  docs/audits/2026-06-22-clippy-uiux-audit.md:56.
- Status bar icon no longer renders at half size: switched to a point-size symbol
  configuration so the paperclip fills the status-item cell. Sources/Clippy/Support/StatusBarIcon.swift:18.
  Addresses docs/audits/2026-06-22-clippy-uiux-audit.md:22 and :515.
- `swift test` no longer fails with duplicate `XCTestCase` redeclarations: removed three
  untracked iCloud-collision ` 2` files (Tests/ClippyTests/AppDefaultTests 2.swift,
  Tests/ClippyTests/ReorderIDsTests 2.swift, integrations/clippy-mcp/node_modules 2
  symlink). Tracked originals are unchanged.

### Added
- New `.aiActions` panel nav row, wired end-to-end: enum case
  (Sources/Clippy/UI/PanelSelection.swift:14), side-pane row
  (Sources/Clippy/UI/CategorySidePane.swift:258-270), main-pane render and empty-state
  (Sources/Clippy/UI/ClipListView.swift:119, :441, :1083).

### Note
- `swift test` under iCloud Drive fails codesign with "resource fork / Finder information
  detritus" until extended attributes are stripped. Run `xattr -cr .build` before invoking
  `swift test`. Recorded as a lesson; no docs/lessons/ folder exists yet.

### Verification
- `swift build` -> Build complete! (3.87s).
- `swift test` (after `xattr -cr .build`) -> Executed 301 tests, with 0 failures (exit 0),
  2026-06-23.

## 2026-06-16 - Overhaul wave (settings regression, themes, sounds, logging, drag/drop, AI, SwiftUI modernization)

### Fixed
- CRITICAL: settings and edits no longer silently do nothing. AppSettings
  declared its own `let objectWillChange = ObservableObjectPublisher()`, which
  suppressed Swift's auto-wiring of every `@Published` property to the publisher,
  so the 8 `@Published` settings (polling interval, MCP, font size, panel
  opacity, capture sound, keystroke threshold, 1Password clear delay, MCP port)
  mutated UserDefaults but never told any view to re-render. Removing the line
  restores live updates. Proven with a standalone Combine repro and a regression
  test (AppSettingsObservationTests) that exercises the real AppSettings.
- Drag-and-drop: category reorder no longer swallowed. Category rows stacked two
  `dropDestination(for: String.self)`; SwiftUI drops do not cascade, so
  `reorder:cat:` tokens were rejected. Collapsed to one routed drop destination
  (pure router with unit tests). Clip-card drags now use simultaneousGesture so
  the tap no longer claims the mouse-down before the drag can start.
- AI Assistant: the Azure `YOUR-RESOURCE` placeholder endpoint now yields a
  precise "not configured" message instead of an opaque DNS error. Audit found
  the network path was otherwise functional; the dominant "never worked" cause
  was the settings regression above (the enable toggle was a no-op). Anthropic
  default model refreshed to `claude-haiku-4-5`.

### Added
- Configurable log level (verbose/debug/info/warning/error) in Settings >
  General; ClippyLog gates both the os.Logger and file sinks on the threshold.
- Every Apple system sound is now selectable as the capture sound: the full
  CoreAudio SystemSounds tree (Finder, Dock, System UI, Siri, FaceTime,
  Telephony, Accessibility, Ink) enumerated from disk and grouped, plus the
  curated highlights (about 95 sounds, up from about 27).
- Theme per-token overrides: any color token can be tweaked on top of ANY preset
  (no longer gated behind the Custom preset), with per-row and global Reset.
  success/danger are now overridable. Nord polar-night values corrected to the
  canonical palette; Tokyo Night preset added (canonical hex).
- Theme-shaded, animated SF Symbols app-wide: hierarchical/palette rendering from
  ThemeTokens, with Reduce-Motion-gated effects on real state transitions
  (pin/copy/run completion, icon swaps, AI streaming, 1Password refresh).

### Changed
- SwiftUI SDK alignment (behavior-preserving): main-thread UI hops moved from
  DispatchQueue to structured concurrency (Task { @MainActor } / Task.sleep(for:));
  foregroundColor -> foregroundStyle; cornerRadius -> clipShape(.rect); user
  search -> localizedStandardContains; numeric Text via format API; AI actions
  empty state -> native ContentUnavailableView. Serial-queue locks, completion
  contracts, and real-time keystroke timing deliberately left as-is.

### Not yet done (tracked for a follow-up)
- Apple Intelligence (Foundation Models) and MLX on-device providers, plus the
  macOS 26 deployment-floor raise they require (coupled; the floor only pays off
  once those APIs are adopted, and there are no dead #available gates to remove).
- AppSettings/stores migration from ObservableObject to @Observable (internal;
  must rewire the Combine `$` projections first).

## 2026-06-16 - Deduplication wave + reliability fixes (PATHFINDER U1-U6 + F-trace)

### Fixed
- AI agent (Azure path): tool-result messages are now correctly shaped for the
  OpenAI-compatible API on the round-cap summary turn. Previously the non-agentic
  complete() sent the raw "__tool_result__:" sentinel string as a user message,
  which Azure would reject or misread. Regression test in WireMessagesTests.
- AI agent: tool-execution failures are now logged (ClippyLog) at both the
  streaming and non-streaming catch sites; the model-facing result is unchanged.
- MCP server restart no longer spuriously reports the port as in use; stop() now
  waits for the old process to exit (bounded 2s, off the main thread) before
  rebinding. Startup stderr is now captured even when /health answers quickly.
- MCP Node server no longer leaks HTTP sessions for dropped clients: an idle TTL
  reaper reclaims abandoned sessions while never reclaiming a session whose SSE
  stream is still open.
- Subprocess: fixed a latent data race on the stderr drain buffer in launch();
  the McpInstallService runCLI path no longer does sequential blocking pipe reads
  (removes a potential deadlock on chatty processes).

### Changed
- Internal deduplication pass (independently verified; test suite grew 192 -> 249):
  all process execution routes through one Subprocess runner (including ScriptRunner,
  which kept its timedOut/duration semantics); a generic JSONFileStore backs the
  Script and AI-action stores; a single pure reorderIDs drives category/clip drag
  ordering; an @AppDefault property wrapper replaces ~55 hand-written UserDefaults
  properties in AppSettings (keys and defaults unchanged); a StreamParser protocol
  shares the SSE framing across AI stream accumulators; hex-color parsing and the
  scripts pasteboard write are shared helpers. No user-facing behavior change.

## 2026-06-12 - Enterprise polish wave (branch feature/enterprise-polish)

### Fixed
- Status bar and Settings-header logo no longer renders with the top cut off. The lazy
  NSImage drawing handler ignored the destination rect, so on Retina backing stores the
  artwork filled only part of the buffer. Regression test renders the icon at 2x and
  asserts ink coverage in the top rows (StatusBarIconTests).
- Custom AI action set to "Copy to Clipboard" no longer silently overwrites the source
  clip; each output disposition now maps to its own proposal kind with regression tests.
- 1Password: copying a concealed field with no stored value is no longer a silent no-op
  (button disabled with an explanatory tooltip).
- Settings window is resizable (min 780x580); stale "Planned" MCP badge and leftover
  scaffolding captions removed.

### Added
- Scripts in the main panel: new "Scripts" sidebar section listing all saved scripts with
  run, live status, stdout/stderr/exit/duration output, copy output, and save-output-as-clip.
  Settings management screen unchanged.
- OCR for image clips: "Extract Text" context-menu action (Apple Vision, accurate mode,
  automatic language detection). Recognized text is copied to the clipboard and saved as a
  new clip labeled "Clippy OCR"; success/empty/failure surfaced via a status banner.
- 1Password deep field access: full item detail (sections in vault order, custom labels,
  multiple concealed fields, usernames, URLs), per-field reveal toggle and copy, TOTP
  fetched on demand, concealed-type pasteboard marker on every secret copy, optional
  clipboard auto-clear (default on, 90s, changeCount-guarded), op resolved via PATH.
- AI actions engine: user-definable actions (name, icon, prompt template with {clip} and
  {instruction}, temperature, max tokens, output disposition), seeded editable built-ins,
  managed in Settings > AI; AI submenu on text clips runs any action with diff-style
  approval where applicable.
- AI Assistant pane: chat surface in the sidebar driving an agentic tool-use loop
  (OpenAI, Anthropic, Ollama, Azure) with tools: search_clips, create_clip, list_scripts,
  run_script, execute_code. Script and code execution are default-OFF in Settings and
  always require per-call user confirmation showing exactly what will run. Code runs as
  the current user with a 30s timeout (no sandbox; the UI says so honestly).
- Settings > AI: Agent & Tools section (script/code execution toggles) and bundled MCP
  server setup block (integrations/clippy-mcp) for external agent access to clips.

### Changed
- Whole-app UI polish pass (40-finding audit executed and independently verified):
  theme tokens replace hardcoded colors in OnePassword/Scripts/AI surfaces, consistent
  typography, keyboard shortcut disclosure (Cmd+E, Cmd+Delete), accessibility labels,
  consistent empty states.

### Tests
- Suite grew from 0 to 190 tests (icon rendering, OCR, 1Password parsing incl.
  adversarial fixtures, AI engine: template substitution, tool gating, loop termination,
  disposition mapping, registry filtering).
