# Changelog

## v2.0.0 - 2026-09-29 - Clippy 2: redesigned panel, smarter, and much more capable

Major release. A ground-up UI/UX redesign (new design tokens, glass panel, grid and cards, sidebar,
settings shell), a wave of new features (paste stack, transforms and snippets, Quick Look and smart
collections, App Intents / `clippy://` URL scheme / CLI, semantic search, auto-file, translate), OCR and editor
upgrades, compliance and retention controls, MCP hardening, and the app target now builds in Swift 6 language mode.

Upgrade notes: existing installs update in-app through Sparkle and keep their history. Web search for the AI agent
is now off by default (opt in under Settings > AI). The old `clipColumns` setting migrates to the new grid
column mode. The redesigned UI, Accessibility capture, hotkeys, and Shortcuts registration have been verified
by automated tests and a launch smoke only; report anything that looks off.


### Added

- **Smart Suggestions: Clippy ranks your history by what you are doing right now.**
  When you open the panel, Clippy reads the app you were just using (name, window
  title, and the text around your cursor) through Accessibility and shows the most
  relevant clips in a new Suggestions pane, each with a plain-English reason
  ("Similar to what you're writing", "Shares words: lisbon, flight", "Copied from
  Mail"). Everything runs on this Mac: Apple's on-device NaturalLanguage sentence
  embeddings plus keyword overlap, recency, source-app affinity, and clip-kind fit
  (links and images are favored when you are writing a message). Nothing is sent
  anywhere, screen text is held in memory only and dropped when the panel closes,
  password fields and Ignored Apps are never read, and the feature is off by
  default. Press 1-9 in the pane to paste the Nth suggestion. Right-click any
  clip and choose **Find Similar Clips** to rank the history against that clip.
  Settings has a new **Intelligence** tab: master toggle, use of focused-field text
  (off = app name and window title only), how many suggestions to show, open the
  pane automatically, Accessibility status with a Grant Access button, and Clear
  suggestion cache. `Intelligence/*.swift`, `UI/SuggestionsPaneView.swift`,
  `UI/ClipStore.swift`, `UI/ClipListView.swift`, `UI/CategorySidePane.swift`,
  `Panel/PanelController.swift`, `Support/AppSettings.swift`, `UI/SettingsView.swift`.
  Ranking is covered by `Tests/ClippyTests/SuggestionEngineTests.swift`, including a
  real-embedder regression test: an earlier min-max scaling of the cosine let an
  unrelated shell command outrank a relevant link, so the score now uses absolute
  thresholds calibrated on sample data (a heuristic; see ROADMAP INT-03).
  The in-app behavior (Accessibility capture in a real app, the pane's visuals) has not
  been exercised end to end yet (ROADMAP INT-01).

### Changed

- **MCP hardened its interim SQLite guardrails while the app is still not the sole
  writer (ROADMAP ARCH-04).** This does not make the app the single writer; XPC or
  Unix-socket routing is still the open item. `openDatabase` no longer changes
  `journal_mode` (the app owns WAL setup) and now refuses to run against a database
  file that is missing or has an incompatible schema (`requireAppSchema` checks
  required tables/columns) instead of creating or migrating one, so a stale or
  pre-launch database fails closed rather than silently diverging from the app's
  migrator. Every `writesDatabase: true` tool (7 of the 22: `clippy_create_clip`,
  `clippy_update_clip`, `clippy_delete_clips`, `clippy_create_category`,
  `clippy_update_category`, `clippy_delete_category`, `clippy_assign_clips`) now runs
  inside `BEGIN IMMEDIATE` / `COMMIT`, with `ROLLBACK` on any thrown error, dispatched
  centrally by tool name rather than per-handler. `PRAGMA busy_timeout = 5000` (added
  previously) still applies so a short app write can finish before MCP's
  `BEGIN IMMEDIATE` proceeds instead of failing immediately with `SQLITE_BUSY`.
  `integrations/clippy-mcp/src/db.ts` (`openDatabase`, `requireAppSchema`,
  `inWriteTransaction`), `integrations/clippy-mcp/src/index.ts` (dispatch). Verified:
  `npm test` (WAL-contention wait, no-create/no-migration, and rollback checks),
  `npm run typecheck`, and the 22-tool vendored-bundle parity check all pass.

### Added

- **UI/UX redesign.** Updated the shared design tokens and glass components, panel shell, grid/cards, sidebar, settings shell, and Assistant, Scripts, and 1Password views, following the proposals in `docs/design/`. GUI visuals were not exercised in a running GUI.
- **Wave 4 features.** Added the paste stack, transforms and snippets, preview column/Quick Look and smart collections; App Intents, URL scheme and CLI; and semantic search, auto-file and translation.
- **Editors, search, keyboard, compliance and data layer.** Includes editor improvements, search and keyboard interaction updates, compliance/retention work, and data-layer fixes.

### Changed

- **OCR first-use and activity feedback.** Vision warm-up addresses the cold first request; extraction now exposes in-flight activity and avoids duplicate OCR results. (See v1.10.1 below for implementation detail.)
- **MCP writes remain guarded.** In addition to the interim protections above, MCP uses `BEGIN IMMEDIATE` and a 5-second busy timeout, and does not run database migrations. The app is still not the single writer (ARCH-04).
- **Swift concurrency mode.** The `Clippy` target is in Swift 6 language mode; `ClippyCLICore`, `clippy-cli`, and `ClippyTests` remain in Swift 5 mode (ARCH-02).

### Verification and limitations

- `swift test`: 1111 tests, 1 skipped (opt-in Vision test), 0 failures.
- **Not exercised in a running GUI:** GUI visuals, Accessibility capture, hotkeys, Shortcuts/App Intents registration, and Spotlight donation. Mobbin MCP was unavailable (401 OAuth); the redesign is based on web research. `docs/design/05-reference-gaps.md` lists what to pull from Mobbin later.

## v1.10.1 - 2026-09-29 - Extract Text no longer looks hung

### Docs

- **ROADMAP rebuilt from a full 2026-09-29 audit.** It combines a live build walkthrough
  (72 screenshots in `.atlas/evidence/2026-09-29-ui-audit/`), per-area code audits, and
  201 claims checked against the code (31 refuted and listed so they are not
  re-reported). The result is 188 gap items across 17 areas, each with evidence and a
  fix direction, plus a phased delivery plan starting with data-loss and compliance
  items.

### Fixed

- **Extract Text no longer looks hung on the first use after the models go
  cold.** The first Vision text-recognition request after the OS has evicted
  its loaded models (observed once at ~14 minutes) pays a one-time
  system-level model load (measured ~24s on current macOS; not paid on every
  launch) while every later request takes
  ~0.03s, and nothing on screen indicated work was happening - so the first
  Extract Text appeared dead and users clicked twice. Two fixes:
  `OCRService.warmUp()` now runs one throwaway recognition on a tiny
  in-memory image on a utility queue at launch and on every panel show (the
  user's "about to interact" signal; concurrent calls collapse into the
  in-flight one) and logs its duration; and the in-flight clip now shows a
  real activity indicator - Extract Text state moved to
  `ClipStore.ocrInFlightClipIDs` (survives the panel being rebuilt, doubles
  as a double-run guard so a second click can't insert a duplicate "Clippy
  OCR" row) driving an "Extracting Text…" spinner scrim over the card's
  image preview, with a matching VoiceOver accessibility value. The OCR
  pasteboard write is now suppressed from re-capture (`ignoreNextChange`,
  same as paste) so it no longer adds a duplicate "Clippy" text row.
  OCR start/finish (elapsed seconds, result kind) and the Extract Text request
  are logged at info level in the storage category.
  `Support/OCRService.swift`, `AppDelegate.swift`, `Panel/PanelController.swift`,
  `UI/ClipCardView.swift`, `UI/ClipListView.swift`, `UI/ClipStore.swift`.

## v1.10.0 - 2026-09-28 - Real previews and OCR for image file clips

### Added

- **File clips that are actually images now get a real preview and Extract
  Text.** Some capture flows (Finder, Preview, screenshot tools) put a file
  URL on the pasteboard alongside the image bytes, so Clippy captured them as
  a plain file clip with no preview and no OCR. `ClipboardMonitor` now checks
  whether a captured file's extension is a decodable image
  (`ClipboardMonitor.isImageFile`) and, if so, has `MediaStore` generate a
  thumbnail and pixel dimensions for it via ImageIO
  (`imageThumbnail(forFileAt:hash:)`), without changing `contentKind` away
  from `.file` so paste/move/reveal-in-Finder behavior is unaffected. A new
  `Clip.isImageLike` (real image clips, or file clips carrying a
  `thumbFilename`) drives both `ClipCardView`'s preview and the Extract Text
  menu item in `ClipListView`. `Sources/Clippy/Capture/ClipboardMonitor.swift`,
  `Sources/Clippy/Storage/MediaStore.swift`, `Sources/Clippy/Storage/ClipKind.swift`,
  `Sources/Clippy/UI/ClipStore.swift`, `Sources/Clippy/UI/ClipCardView.swift`,
  `Sources/Clippy/UI/ClipListView.swift`.

## v1.9.0 - 2026-09-16 - Apple Intelligence, and an MCP server that actually works

Full analysis, with evidence: docs/audits/2026-09-16-clippy-ai-mcp-uiux-analysis.md

### Fixed

- **Five of the eight MCP tools never reached the model.** `clippy_search`,
  `clippy_list_recent`, `clippy_get`, `clippy_delete`, and `clippy_set_category` had
  their schemas serialized with `zodToJsonSchema(..., { target: "openApi3" })`, which
  emits the draft-04 boolean form `"exclusiveMinimum": true` for
  `z.number().int().positive()`. MCP clients validate against draft-07+, where the
  keyword must be numeric, and drop a failing tool from the tool list **with no error**
  - so the server looked healthy while search, read, and delete simply did not exist.
  Only the three tools with no numeric parameter survived. Target is now `jsonSchema7`,
  and `test/smoke.mjs` walks every advertised schema and fails the build on a
  non-numeric `exclusiveMinimum`/`exclusiveMaximum`. `integrations/clippy-mcp/src/index.ts`.

- **Writes made over MCP were invisible to the running app.** GRDB's `ValueObservation`
  does not detect commits from another connection, and `scripts.json` / `ai-actions.json`
  are held in memory by the app, so an external write was not merely unseen - the next
  in-app save overwrote it. `Storage/ExternalChangeWatcher.swift` polls SQLite's
  `data_version` (unchanged for the reading connection's own commits, so Clippy's own
  captures never trip it) and the two files' modification dates, then calls
  `Database.notifyChanges(in: .fullDatabase)`. Changes now appear within about two
  seconds. `Storage/ClipDatabase.swift`, `Support/JSONFileStore.swift`.

- **Copying a folder in Finder failed every time, silently.**
  `ClipboardMonitor.captureFileIfPresent` filtered candidates on
  `attributesOfItem[.size] > 0`, which is non-zero for a directory, then handed them to
  `MediaStore.storeFile`, where `Data(contentsOf:)` throws EISDIR. No clip, no capture
  sound, nothing surfaced: **1273 of the 1313 lines in the user's log were this one
  error**, from 2026-07-12 to 2026-09-02. `ClipboardMonitor.classify` now checks
  `isDirectoryKey` and keeps folders as a path reference, and skips iCloud items whose
  bytes are not downloaded instead of failing on them. A copy where every item fails now
  logs one summary line. `Capture/ClipboardMonitor.swift`,
  `Tests/ClippyTests/FileCaptureClassificationTests.swift`.

- **One unreadable iCloud archive disabled sync permanently.** `sync()` ran
  `pullIfPresent` and the export inside a single `do`, so a parse failure on the remote
  file skipped the export - which meant the bad file was never replaced and every later
  sync hit the same error. Seen in the field 2026-06-17 to 06-23, from a build predating
  the TOML escaping fix. An unparseable archive is now quarantined (moved aside, not
  deleted) and the export proceeds. `Integrations/ICloudSyncService.swift`.

- **Fresh clips showed "in 0s"**, future tense, because
  `Date.RelativeFormatStyle(presentation: .numeric)` rounds a sub-second interval to zero
  and keeps the sign. Anything under a minute now reads "now", via a shared
  `Support/RelativeTime.swift` used by both the clip card and the scripts panel.

- `PRAGMA busy_timeout = 5000` on the MCP connection. Two writers share the file; without
  it a write landing while the app holds the lock fails immediately with `SQLITE_BUSY`.

### Added

- **Apple Intelligence as an AI provider**, on device, via Foundation Models
  (`AI/AppleIntelligenceProvider.swift`). No API key, no endpoint, and nothing copied
  leaves the Mac - which is what makes capture-time AI defensible where the clipboard
  carries client data. Gated on `SystemLanguageModel.default.availability`, with the
  reason surfaced in Settings when it is not ready. It is now the default provider.
  Tool calling is deliberately not implemented and the type says so: Foundation Models
  wants compile-time `@Generable` argument types while `AITool` carries a runtime JSON
  schema. Chat, AI actions, and auto-titling all work; the assistant cannot call Clippy's
  own tools while this provider is selected.

- **22 MCP tools** across clips, categories, scripts, and AI actions, replacing eight
  read-mostly ones. New: `clippy_update_clip`, `clippy_update_category`,
  `clippy_delete_category`, `clippy_assign_clips` and `clippy_delete_clips` (batched, up
  to 500 per call), `clippy_stats`, and full CRUD over scripts and AI actions - the two
  JSON stores the server previously could not see at all. Descriptions were rewritten to
  say when to reach for a tool and how tools compose, rather than describing table rows.
  The five old names remain as deprecated aliases on their original schemas.

- **`clip-automation` skill** in the Claude Code plugin, covering when to write a script
  versus an AI action and the rules for each.

- **CI workflow** (`.github/workflows/ci.yml`) running `swift build`, `swift test`, and
  the MCP typecheck and smoke test on every push, plus a check that the plugin's vendored
  server bundle is in sync with `src/`. Clippy cannot be built on a machine with only the
  Command Line Tools - SwiftUI's `@State` is an external macro whose plugin ships with
  Xcode - and until now the release workflow was the only thing that ran the tests.

### Security

- **Scripts created or edited over MCP land disabled.** Clippy executes scripts as the
  signed-in user, so a tool that could both write and enable one would be a path from any
  connected MCP client to arbitrary shell. `Script.isEnabled` defaults to true (existing
  scripts are unaffected) but is forced false for anything the MCP server writes, and
  `ScriptRunner.run` refuses a disabled script at the single chokepoint every caller
  funnels through. There is deliberately no MCP parameter to enable one; editing
  re-disables, because the approval was for the previous body. Settings gained an
  "Enabled" toggle and the panel greys out the run button.

- **Capture-time auto-titling now requires a local provider.** It fires on every copy, so
  with a hosted provider it would post every password and client record passing through
  the clipboard to a third party. `AppSettings.canAutoSuggestTitles` gates it on Apple
  Intelligence or Ollama, and Settings says so rather than leaving a toggle that is on
  and quietly does nothing.

- MCP search and list results return 300-character previews; full clip text requires
  `clippy_get_clip` on a named id.

- Every MCP call writes an audit line to stderr - timestamp, outcome, tool name, and
  argument key names, never values - which the app captures.

### Notes

- The MCP fix reaches the running server only after this build installs: the live server
  is the copy inside `Clippy.app/Contents/Resources/clippy-mcp/`, written by
  `scripts/make-app.sh`. MCP clients also negotiate their tool list at startup, so
  restart the client after updating.

## 2026-08-14 - Dropped copies from slow multi-flavor pasteboard writers

### Fixed
- Copies from apps that fill the pasteboard in stages are no longer dropped. An app
  bumps `changeCount` on `clearContents()` and writes the data up to a few hundred ms
  later; the poll retired the change on that first empty look, so the copy was lost for
  good - no clip, no mascot bounce, no capture sound. `tick()` now retires a change only
  once the pasteboard actually resolved, with a 2s grace so an unsupported flavor cannot
  spin the poll. Sources/Clippy/Capture/ClipboardMonitor.swift:90 (`tick`), :121 (`retire`),
  :135 (`captureCurrentPasteboard` now returns resolved/not-yet).
  - Deliberate skips (`org.nspasteboard.ConcealedType`, ignored source bundle IDs, images
    over the size cap) still retire immediately and are never re-read. Retrying one would
    re-examine it after the frontmost app changed, which is how a password copy would end
    up in history.
  - `ClipboardMonitor` takes an injectable `NSPasteboard` (defaults to `.general`) and
    `tick()` is internal, so the capture path is drivable headlessly.
    Tests/ClippyTests/ClipboardMonitorRaceTests.swift.
- Evidence, measured against a 300ms fill gap with the 600ms poll interval:
  before 5 of 6 copies dropped, after 0 of 6. A 1.2s gap is captured; a concealed-type
  write is still never captured. docs/evidence/capture-race-2026-08-14.md.

### Known, not fixed here
- `captureFileIfPresent` retires the change even when every file save throws, so a failed
  file copy is silent (no clip, no sound). Pre-existing.
- `skipNextChange` is consumed by whichever change the next tick observes. A user copy
  landing in the same poll window as Clippy's own paste-write is swallowed. Pre-existing.

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
