# Changelog

## Unreleased

- Settings keyboard: the sidebar search field takes focus when Settings opens; Up/Down move between panes (or search hits while searching), Return opens the highlighted hit, Esc clears the search then closes the window, Cmd-1..9 jump to panes; focus returns to the search field after a pane opens.
- The New pill on a Settings pane now clears as soon as that pane is shown, including from search, and stays cleared after relaunch.
- The default theme is Clean Light again, as before 2.3.0. Automatic (Clean Light in light mode, GitHub Dark in dark mode) is still available in Settings.
- Clippy now backs up the clip database before applying a database upgrade, and logs how long the upgrade took. The backup appears in Settings under Backups.
- Pasting a clip logs a message when its formatting cannot be read and the clip is pasted as plain text.

## v2.3.0 - 2026-11-03 - UI and UX overhaul

Built and tested on macOS in CI ([run 41638763966](https://github.com/w159/clippy/actions/runs/41638763966), commit `1fc24b6`): `swift build`, 1388 XCTests (9 skipped, 0 failures; the suite ran 1233 tests before this branch), a UI harness that drives the real panel with synthetic key and mouse events and reads the rendered window with Vision OCR, an app-bundle build with a launch smoke test, and screenshots of every Settings pane, every panel pane, the clip editor, every sheet, the palette, onboarding and the real first launch in light and dark (`clippy-screenshots` and `clippy-contact-sheet.png` artifacts of that run).

### Search

Search was broken in six ways. The first CI run on the old code with the new tests ([run 41150351429](https://github.com/w159/clippy/actions/runs/41150351429)) failed 11 tests, and the harness reproduced the symptoms in the real panel.

- History hid every clip filed in a category, also while searching, so a filed clip could not be found from History. While a query is active History now lists every match, filed or not.
- Full-text search matched word prefixes only: "hub" missed github and "UserName" missed getUserName, while the category pane and the highlight used substring matching, so results differed by pane. Fragments inside words now match everywhere (text, title and OCR text). Results are word-start matches first, then fragments, newest first within each tier, grouped by day so the keyboard order equals the visual order.
- A query of only punctuation ("@", "$", "!!!") built no full-text pattern and returned every clip; "c++" became every word starting with c. Words with punctuation are now matched as literal text.
- When new results arrived the cursor stayed on the previously selected clip while the list scrolled to the top, so Return pasted a clip off screen. New results select the top match until the user moves the cursor.
- Return pressed within the 180 ms search debounce pasted the previous query's top clip. Return now runs the search at once and pastes the top match of what was typed.
- Typing while the list had focus moved focus to the search field, which selected its text, so the next key replaced the first ("deck" became "eck"). Characters typed from the list now go through the search field's own editor and every character is kept.
- Also: clearing the query left semantic match badges from the old search; a failed search empties the list instead of keeping stale results; the History and category badges count what their panes show while searching (a category no longer reads "1" beside an empty result).

### Found on the macOS screenshots

- The default theme follows macOS: Clean Light in light mode, GitHub Dark in dark mode (new `Automatic` preset). Before, dark mode kept the light palette and the filter chip labels and the search prompt were unreadable. Explicit theme choices are kept.
- Filter chips, toast text and the search prompt use explicit token colors.
- On the real first launch the onboarding glass card sat below an empty titlebar strip with the window buttons floating over the desktop. The card now fills the window, as the panel does; Skip for now (also Escape) closes it.
- Menus drawn with the borderless menu styles were tinted with the accent by AppKit, which also dropped their custom backgrounds: the Date, App and Category filters showed as gold text beside capsule chips, and the "More" glyphs turned gold beside neutral icons. Menus now draw their labels as written (`chromeMenuStyle()`), so every filter is a chip and every overflow glyph matches the icons beside it.
- Row and card actions are neutral until hovered (`RowActionButton`); the trash can turns red only while it is hovered, not on every selected row. The colored kind bar at the left edge of each row is gone; the kind icon already says it, and the selection outline is a 1 pt accent stroke.
- White text on the gold accent measured about 2.2:1. Accent buttons (Clear Search, Continue, Back Up Now, Run, Select and the AI and 1Password actions) now use `AccentButtonStyle`, which picks a black or white label by WCAG contrast for every theme and custom accent (at least 4.5:1, tested for every preset and accent theme) and stays filled when the window is inactive, so Continue no longer reads as disabled on first launch.
- Onboarding: the welcome step introduces the app (what it finds, keeps and pastes) under a hero icon. The footer has one filled action: Skip for now is a text button and the welcome step drops Skip this step, which meant the same as Continue. Step names no longer wrap.
- Settings: the New pill on a pane clears once that pane has been opened. The search field's App chip uses a window symbol, and the sidebar divider uses the system separator color.

### Every screen, reviewed on macOS

The CI harness now renders every Settings pane, every panel pane (Assistant, AI Actions, 1Password, Paste Stack, Scripts, Snippets), the clip editor, the category, smart collection, snippet and AI action sheets, the command palette and the AI actions manager, in light and dark. Two reviews of those screenshots ([run 41561854977](https://github.com/w159/clippy/actions/runs/41561854977) and [run 41565269109](https://github.com/w159/clippy/actions/runs/41565269109)) found the defects fixed here. The clip editor shot uses an injected in-memory store; the harness no longer touches the on-disk history.

- Settings tinted the whole window with the gold accent, so text buttons and links (About links, Copy diagnostics, Test connection, Export, Import, Reveal in Finder, Clear cache, Refresh) read at about 2:1 on the light surface. The window now uses `accentInk`, a darker accent that meets 4.5:1 on every surface for every preset and accent theme (tested). Toggles and sliders keep the bright accent so they match the panel and sheets.
- Segmented pickers drew white on gold. They are now drawn from tokens (`ClippySegmentedPicker`) with a contrast-picked label, and no segment truncates ("Accurate" in OCR read "Acc...").
- Sheets and editors used system blue for primary buttons, toggles, segmented controls and sliders. Save, Create and the other default actions use the accent button style; the controls use the accent.
- The Settings sidebar showed the selected pane in system blue. Selection is a token fill, with the selected state exposed to VoiceOver and arrow keys still moving between panes.
- Smart collection sheet: the title and labels were clipped and the kind checkboxes truncated ("T...", "Im..."). The kinds wrap in a flow layout.
- Clip editor: the line-number gutter rule ran the full window height, through the title field and footer.
- Snippets panel: footer buttons truncated and the search field sat on the window edge. Import and export are one menu.
- Assistant with AI off showed the header, a provider banner, the AI-off message and an active composer at once. It now shows one empty state with Open Settings. The Scripts panel empty state had near-white text on white.
- AI Actions: every built-in offered Restore, including unmodified ones. Restore appears only on a changed action (`AIAction.isModifiedFromDefault`, tested). A new action no longer shows "The prompt template is empty" in red before any input.
- Settings no longer opens a pane with its first text field focused and selected.
- Capture: "Store file contents up to" showed no value when the stored size was not a menu option; 50 MB is an option and the picker always shows the value. Preview cache reads "0 bytes", not "Zero KB". Snippets: "Granted" no longer truncates. Scripts settings showed its empty state twice.
- Paste stack export and clear look disabled while the stack is empty, and 1Password's add button is disabled while the CLI is missing or signed out, so no control looks usable when it does nothing. Icon buttons dim whenever they are disabled.
- AI provider "Open provider docs" used the system link blue; it uses the accent text color.
- Settings rows forced the plain switch style, so their toggles kept the dark `accentInk` tint and looked brown in light mode while every other toggle was gold. Rows now apply the accent toggle style before the switch style.

### Design system

- One corner-radius system: `ClippyRadius` roles `panel` 16, `card` 12, `control` 8, `inset` 6 (`UI/DesignSystem/ClippyTokens.swift`). The panel glass was drawn at 24 and clipped at 12; both now use `panel`. No `cornerRadius:` literal is left outside the design gallery.
- Motion goes through `ClippyMotion` tokens and respects Reduce Motion in the search bar, settings rows, sidebar split, panes and reorder.
- Hard-coded `Color.orange`, `.red` and `Color.accentColor` replaced with semantic tokens (warning, danger, accent) in the search notice, category editor, audit log, smart collection editor and Scripts list.
- Onboarding and the paste-stack HUD now get the design-system environment, so they follow the user's theme instead of the default palette.
- The command palette scrim uses the elevation shadow color, so it dims in dark themes instead of lightening them. The collapsed category rail uses the same panel transparency as the expanded sidebar.
- New `CopyFormat.counted` helper; counts read "1 clip" and "2 clips" across Scripts, snippets, paste stack, OCR, preview, retention, archive import and export, and the audit log.

### Behavior

- Deleting a clip that fits the undo buffer happens at once with an Undo toast (Cmd+Z); only clips too large to keep for Undo still ask first, and the alert says why.
- The palette's Delete command acts on the whole multi-selection, as Cmd+Delete does, and is titled "Delete N Clips".
- Saving an assistant reply, a translation or a new 1Password secret reports failure instead of claiming success. 1Password create failures show a banner with Try Again.
- Settings: Rotate token in Security now goes through the MCP server controller, so the server restarts and installed clients get the new token (it used to change only the Keychain value). Both rotate buttons report the real outcome.
- Settings: About's Check for Updates button calls the Sparkle updater directly; the old main-menu lookup never found the item, so the button never appeared.
- Settings: deleting a backup asks first.
- Paste warnings about Accessibility access carry an "Open Privacy Settings" button; "AI isn't set up yet" carries "Open Settings", and the AI submenu offers the same instead of a dead-end text row. "Generate Titles" is hidden while AI is off.
- A search or history error with an empty list shows one error state, not a banner and an error state for the same error.
- The copy-only setting is renamed "Double-click and Return copy without pasting", which is what it governs; a single click only selects. Typing in Suggestions searches History. The VoiceOver default action on a row pastes it. A history update that leaves the visible window unchanged no longer re-runs the search.
- A clip whose image text recognition failed keeps that marker until the user clears it, instead of being retried on every launch.

### Performance

Measured on macOS CI (GitHub Actions macOS runner, best of 5) before this round (run 41598348619, commit c912b19) and after it (run 41609295874, commit 0e6dc8d); 1373 tests pass.

| Path | Before | After |
|---|---|---|
| Word search, 50k rich-text clips ('invoice') | 244.2 ms | 10.4 ms |
| No-match search, 50k rich-text clips (full scan) | 67.6 ms | 32.4 ms |
| Word search, 10k rich-text clips | 43.5 ms | 6.2 ms |
| Two-word search, 10k rich-text clips | 46.9 ms | 9.2 ms |
| Fragment search 'nvoic', 10k clips | 7.2 ms | 3.9 ms |
| Filter app:xcode / kind #image | 5.9 / 6.6 ms | 2.6 / 2.8 ms |
| Panel list fetch | 33.7 ms | 4.6 ms |
| Panel window cold load, 50k clips | 35.4 ms | 13.7 ms |
| Panel update after one edit (3000 filed rich clips) | 19.3 ms | 9.1 ms |
| Memory held by the panel window (3000 filed rich clips) | 34.4 MB | 0.0 MB |
| Launch (open and migrate, 50k clips) | 5.1 ms | 5.2 ms |
| Capture a new clip at 50k | 2.5 ms | 2.0 ms |

- Lists, search and the panel load rows without the RTF and HTML data; it loads when a clip is copied, pasted, edited or undone.
- Word search walks the date index and stops at the page size instead of fetching and sorting every match.
- Light rows decode by column position instead of Codable (300 rows: 5.9 ms to 2.0 ms in the same run).
- The panel's change stamps use the date index directly.
- The panel's reload after a restore (a fresh window load of 3,300 clips) takes 63 ms on CI (run 41613764477); the 104 to 107 ms figure printed by the window pulse test is the old SELECT * query kept there as the before side.
- Every write to `clips` (each capture, OCR result or rename) re-ran the panel's observation, which decoded every categorized clip, RTF and HTML blobs included. `ClipWindowLoader` now reads the window's (id, version) stamps and decodes only new or changed rows. With 3,000 filed rich-text clips, one edit costs 1 decoded row instead of 3,000: 33.13 ms instead of 161.18 ms per pulse on the CI Mac (best of 5, `ClipWindowLoaderTests.testOneEditCostsOneRowNotTheWholeWindow`).
- Versions live in a `clip_version` table bumped by a trigger on every update from any writer, the MCP server included. The first version of this kept the counter on `clips` itself; a trigger that updates `clips` from inside an update on `clips` re-ran the FTS5 sync triggers in an undefined order and corrupted the search index (SQLite error 11 on every edit, caught by CI). `testEditsKeepTheSearchIndexIntact` runs SQLite's integrity checks after title, OCR and raw SQL edits. A backup restore drops the loader's cache.
- Migration `v14-blobs-last` rebuilds `clips` once so `contentRTF` and `contentHTML` are the last two columns. SQLite keeps a row's large values in overflow pages after the columns in front of them, so with the blobs early every read of `createdAt`, `userTitle` or `ocrText` walked the rich-text pages. In a Python repro of the schema with 50k rich rows a no-match search scan read 145 MB before and 27.5 MB after (54-60 ms to 27 ms), and the window loader's fresh-row fetch 53 MB before and 12 MB after. Rows, ids, categories, versions, indexes, triggers, foreign keys and the search index are kept (`BlobsLastMigrationTests`). The rebuild took 3.9 s for 50k rich-text clips on CI.

### Copy and accessibility

- Batch bar: "Paste in Order", "Paste as One", "Generate Titles", "Delete"; the multi-select context menu uses the same words.
- Editor conflict actions name their outcome: "Use Stored" / "Keep Mine" (was "Reload", which silently discarded edits).
- Script Run confirmations are no longer styled as destructive.
- Title Case for buttons, menus and palette commands; "Try Again" everywhere instead of a mix with "Retry"; real ellipsis characters instead of three dots.
- Row hover buttons, row and card overflow menus, and Scripts icon buttons have accessibility labels. The category section "+" button has a 20 pt hit target, and category counts keep their contrast-adjusted color.
- README shortcut table and requirements corrected (macOS 26, Swift 6.2; Cmd+2...9 select categories).

### Errors, empty states and keyboard (final round)

- Errors are no longer silent. A failed store write (pin, delete, rename, category change) shows "Couldn't save that change. Try again." Smart search read failures show "Search failed" with a retry button instead of "No clips match". A failed Translate replace shows an error and keeps the sheet open. Smart collection load failures appear in the sidebar and in Settings instead of an empty list. Undo reports the categories it could not restore.
- Empty states say what to do next: Add Snippet, New Script, Refresh model catalog, and Try Again in Suggestions. Each route has its own copy. Link previews show loading and unavailable rows. Describe Image and CLI install failures name the specific cause.
- Keyboard: Shift-F10 or the Menu key opens the clip actions palette; Cmd-R renames; Shift-Cmd-C copies as plain text; Shift-Cmd-R reveals a sensitive clip; Cmd-Return toggles a row in a multi-selection; Tab and Shift-Tab move between sidebar, search and list; list focus returns after the preview closes; Return in the sidebar moves focus to the list; keys no longer leak into the list while a title is being renamed.
- Accessibility: the Clear search button is labeled; panel, script and 1Password borders use contrast-checked strokes (3:1, and 4.5:1 under Increase Contrast); decorative icons are hidden from VoiceOver; sidebar rows have a VoiceOver activate action; Reduce Motion uses fades consistently.
- Tests: AccessibilityContractTests, StoreErrorSurfacingTests, a panel keyboard journey, and empty and error state screenshots in the UI harness.
- Settings keyboard shortcuts (pane shortcuts, search by keyboard, Esc to close) were held back: the harness test failed on the macOS runner, so they are not in this release.

## v2.2.0 - 2026-09-30 - AI providers rebuilt

### Fixed

AI provider diagnosis (`docs/ai/diagnosis.md`), 17 causes:

1. Model and base URL were shared by all providers; each provider instance now has its own configuration.
2. Ollama's default model (`llama3.1`) was not installed and nothing listed installed models; models are now discovered from the server.
3. Thinking models returned empty output; reasoning is parsed, and hitting the token cap while thinking gives a clear error.
4. OpenAI `max_tokens` and non-default `temperature` were rejected by newer models; `max_completion_tokens` and temperature rules now follow the model, with a self-correcting retry.
5. `/v1` and other path segments were duplicated in base URLs; URLs are normalized per provider family.
6. Azure had one hardcoded route; classic deployments and v1 routes are both supported (Entra sign-in is not; use an API key).
7. Ollama Cloud, API keys and custom headers were unsupported; Ollama Cloud with a key works.
8. The privacy gate trusted the provider kind; it now checks the resolved host.
9. App Transport Security: plain-HTTP qualified hostnames (LAN IPs, `.local` names) were blocked in the packaged app. `scripts/make-app.sh` now sets `NSAllowsLocalNetworking` (narrow; internet hosts still need https; `NSAllowsArbitraryLoads` is not set). Checked: the built `Info.plist` contains the key. Not checked: a request to a non-loopback host from the built app.
10. Timeouts killed slow local models; first-token, idle and overall timeouts are now separate and configurable.
11. Errors were weak or misleading; failures are structured with remediation, and an interrupted reply is marked in the transcript.
12. Headers and generation parameters could not be customized; they can now, per provider.
13. Providers were a hardcoded five-case enum; they now come from a data-driven catalog.
14. There was no model discovery or picker; there is now a model browser.
15. The tool/agent path repeated the same problems; it now uses the same resolved provider and transport.
16. A denied Keychain read looked like a missing key (ad-hoc signed builds); it now has its own state and message.
17. Two divergent copies of the provider code; the legacy adapter and provider kind were removed.

Also fixed: Settings Reset and Import left the provider list stale until restart; the store now reloads from preferences.

- **Thinking models no longer return reasoning or empty titles.** Verified live on `glm-5.3-flash:cloud` through the local Ollama daemon: it ignores `think:false` and writes its reasoning into the reply, and with no `think` flag and a small budget it returns an empty reply. Quick Ollama actions now check the model's `/api/show` capabilities; thinking-capable models get `think:"low"` and a budget of at least 1024 tokens (retry ladder `low`, `false`, `true` with a larger budget, remembered per model). Only `message.content` is ever used as the answer. A title longer than 12 words or with several sentences is rejected and logged instead of saved, in both the single and bulk title paths. Live result after the fix: title "Pangram sentences about foxes and jugs", streamed reply "pong", connection test OK in about 1.3 s.
- **Model latency column measures real streaming.** The latency probe uses the normal chat stream; quick Ollama replies are held back while a leaked reasoning reply may still be discarded.

### Added

- Data-driven provider catalog of 25 providers.
- Multiple configured instances per provider.
- Per-provider custom headers, extra body JSON, generation parameters and timeouts.
- Model browser window with a sortable, filterable table and measured latency.
- Connection test with remediation hints.

### Verification

Covered by unit tests, mock servers and the local Ollama daemon. Authenticated hosted providers (OpenAI, Anthropic, Azure, OpenRouter and
the others) were NOT exercised with real credentials. Native Gemini supports text and streaming only (no tools). Bedrock and Vertex are deferred
(`docs/ai/providers-local-complex.md`). GitHub Models is retired upstream and hidden.

## v2.1.0 - 2026-09-30 - Design pass from Mobbin references

### Changed

- **Settings window resizes and no longer clips** (720x480 minimum, 1000x700 default, frame autosave bumped to `ClippySettingsWindow.v2`). Sidebar rows are compact so every pane is reachable; the pane title moved into the title bar; Reset/Export/Import are small neutral buttons; the Scripts pane fills the whole detail area; the script toolbar collapses in three tiers (labelled, icon-only, name on its own row) instead of clipping; the text-editor toolbar collapses into a More menu; AI actions open in a resizable sheet instead of a fixed 320pt disclosure; the shortcut Reset button only appears once a chord differs from its default. `CLIPPY_SETTINGS_SIZE=WxH` with `--screenshot-settings` captures any pane at a given size (`CLIPPY_SETTINGS_SECTION` picks the pane).
  Verified: swift test 1131 passing; all 17 panes screenshotted at 720x480, first screen only (content below the fold, other window sizes and light themes not yet inspected).

- **Design pass from Mobbin references** (`docs/design/06-mobbin-references.md`). Command palette: Recent first, muted section headers, trailing context labels, keycaps, a live footer of key hints, Tab/Shift-Tab to jump sections. Settings: grouped sidebar with NEW badges, 600pt centered column. Onboarding: dimmed upcoming steps, live-status permission rows, "What you get" checklist, quiet "Continue without granting". Assistant: collapsible tool step cards, step checklist, inline numbered approval card instead of a modal. Secrets (AI key, MCP token, 1Password values): reveal eye inside the field plus a separate Copy button. Sidebar group headers show counts and an add button. Deleting clips shows an Undo action on the toast.
  Verified by 1131 passing tests; not yet seen in a running GUI.

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
