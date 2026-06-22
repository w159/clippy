# Clippy UI/UX Audit

> Generated 2026-06-22 by a 14-agent review swarm (10 UI/UX dimension agents + user-story, feature-request, and bug-report agents, synthesized).
> 117 findings (18 high, 52 medium, 39 low, 8 polish), 12 user stories, 12 feature requests, 10 bugs. All cite file:line.

## Executive Summary

- The architecture is sound overall: a real theme/token system, lazy clip lists with downsampled thumbnails, a streaming AI chat that coalesces at 20fps and guards state reset, and a tag-based category model with a tested reorder primitive. The defects are in the seams, not the foundations.
- Main-thread hot paths are the leading cause of the reported "lag/freeze": undebounced synchronous FTS5 search on every keystroke, an `onChange(of: store.clips)` that deep-compares up to 300 full clips (text + RTF/HTML Data) per keystroke and per DB pulse, the MCP Install button blocking on a semaphore-waited subprocess, and `Theme.tokens` recomputed on every access across hundreds of cards.
- Focus-restore is the second major pain: deprecated `activate()` plus fixed 0.12/0.15s sleeps do not guarantee the target text field is first responder, so paste/keystroke-sending lands in the wrong app or nowhere. A stale `previousApp` captured only at show time makes this worse for long-lived panels.
- Accessibility coverage is uneven and incomplete: zero `accessibilityHint`/`accessibilityValue` usage anywhere, Dynamic Type ignored (fixed point sizes), AI chat has no role labels or live-region announcements, hover-revealed card actions are mouse-only, and several stateful controls (pin, reveal/hide, expand/collapse, swatches) never expose state.
- Error states consistently lack retry and several failures are silently swallowed: DB-open `fatalError`s the process, search errors render as a misleading "no matches" empty state, OCR success and failure look identical, AI error bubbles have no retry, and script save gives no feedback.
- Several silent data-loss paths: multi-file Finder copies keep only the first URL, clip deletes are permanent with no undo/trash, AI conversations are discarded when the panel closes, and switching script selection discards unsaved edits.
- Cross-surface inconsistency: Settings bypasses `PanelTypography` (user font choice does not apply), several surfaces hardcode `Color.white`/`Color.black`/`.regularMaterial` instead of tokens, MCP is filed under "AI" not "Integrations", and reorder/empty-state patterns differ per surface.
- Confirmation-default safety issue: the AI tool-confirmation card defaults to Allow on Return for code-executing tools, and the panel runs scripts with no confirmation while Settings requires one.

## Findings by Area

### Visual design & theming

[HIGH] Status-bar icon optically top-cropped despite code claiming it cannot clip
Evidence: `Support/StatusBarIcon.swift:9-14` configures the paperclip at pointSize 16 with no vertical alignment inside `squareLength` (`AppDelegate.swift:228`); the comment at `StatusBarIcon.swift:3-5` denies clipping. Confidence: suspected.
Recommendation: Render with a symbol configuration matched to the menu bar (e.g. `NSImage.SymbolConfiguration(textStyle: .body, scale: .small)`) and center it in an image sized to the button height, or switch to a tighter-bbox symbol. Verify in light and dark menu bar.

[HIGH] Settings window bypasses PanelTypography, so the user's font family/size choice does not apply there
Evidence: `SettingsView.swift` uses raw `.font(.system(size:))` throughout (lines 81, 86, 109, 122, 553, 615) while panel views route through `PanelTypography` (`Theme.swift:219-268`). Confidence: confirmed.
Recommendation: Replace raw font calls with `PanelTypography` role helpers (or a parallel `SettingsTypography` that still consults `fontFamily`/`fontSizeBase`).

[MEDIUM] Rename field fill uses hardcoded Color.white/Color.black instead of theme tokens
Evidence: `UI/ClipCardView.swift:292-294` `tokens.isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)`. Confidence: confirmed.
Recommendation: Add a `fieldFill` token driven from the preset and custom overrides.

[MEDIUM] AI assistant panel uses hardcoded Color.black scrim and Color.white/labelColor text instead of tokens
Evidence: `AI/AIAssistantPanelView.swift:228` `Color.black.opacity(0.25)` scrim; line 512 assistant bubble text bypasses `tokens.textPrimary`. Custom hex overrides do not propagate. Confidence: confirmed.
Recommendation: Use `tokens.textPrimary` for bubble text and a theme-derived scrim (e.g. `tokens.panel.opacity(0.4)`).

[MEDIUM] OCR status toast hardcodes `.regularMaterial`, ignoring the user's panel material choice
Evidence: `UI/ClipListView.swift:316` `.background(.regularMaterial, in: RoundedRectangle(...))`; other surfaces use `ThemedPanelBackground`/tokens (`ClipListView.swift:128`). Confidence: confirmed.
Recommendation: Route this background through `ThemedPanelBackground` or `tokens.cardSurface` with configured opacity.

[LOW] scrollbar token is defined in every preset but consumed by no view
Evidence: `ThemePreset.swift` defines scrollbar for all nine presets; `customScrollbarHex` exists (`Theme.swift:227`); grep finds no `tokens.scrollbar` usage. Confidence: confirmed.
Recommendation: Wire the token into a custom scrollbar tint, or remove it and its override UI row.

[LOW] No enforced brand color; Clippy Amber is one accent among many and not the default
Evidence: `Theme.swift:37-49` lists `.system` as the default; `.clippyAmber` (`Theme.swift:71`) is one option; `CategoryPalette` (`Theme.swift:274-278`) excludes amber. Confidence: confirmed.
Recommendation: Make Amber the default accent and/or derive a dedicated `brand` token; include it in `CategoryPalette`.

[POLISH] No spacing scale token; views use ad-hoc padding literals
Evidence: `PanelHeaderView.swift:75-77` uses 12/30; `SettingsView.swift:90-113` uses 6/8/10/12/16; `ClipListView.swift:852` uses 24. Confidence: confirmed.
Recommendation: Introduce `Theme.Spacing.xs/sm/md/lg` and replace literal paddings.

### Clip list & card UX

[HIGH] Search has no debounce; every keystroke runs a synchronous FTS5 query on the main thread
Evidence: `ClipStore.swift:12-14` `query.didSet { refilter() }`; `ClipStore.swift:307-314` `refilter()` calls `database.searchClips` synchronously via `dbQueue.read` (`ClipDatabase.swift:417-419`). Confidence: confirmed.
Recommendation: Debounce query changes (150-200ms) and/or move the search off the main actor.

[HIGH] Selection is reset to top and multi-selection cleared on every DB observation pulse
Evidence: `ClipListView.swift:135` `.onChange(of: store.clips) { _, _ in selectedIndex = 0; selectedClipIDs = [] }`. `store.clips` republishes on every capture and every category/membership write. Confidence: confirmed.
Recommendation: Reset only when the anchored clip id is gone; intersect `selectedClipIDs` with the new set instead of clearing. (See also the bug entry for the underlying deep-compare cause.)

[MEDIUM] Search bar silently has no effect inside category panes
Evidence: `ClipListView.swift:83-96` `visibleClips` for `.category` returns `store.clipsForCategory(categoryID)`, which `ClipStore.swift:193-206` sources from `recents`, not query-filtered `clips`. Confidence: confirmed.
Recommendation: Scope search to the active pane, or visually disable/relabel the field (e.g. "Search history only") when a category is selected.

[MEDIUM] Per-card store membership queries re-run on every redraw (O(n*m))
Evidence: `ClipListView.swift:532-570` calls `store.isPinned`, `store.categories.filter { ... }`, `store.firstCategory(for:)`, plus `CategoryReorderModifier` per card per body. Confidence: confirmed.
Recommendation: Precompute a per-clip category-color array and pinned/firstCategory lookup once per `store.clips`/`membership` change; pass it into each card.

[MEDIUM] Hover-revealed quick actions are unreachable for keyboard and screen-reader users
Evidence: `ClipCardView.swift:199-205` `hoverActions.opacity(isHovering ? 1 : 0).allowsHitTesting(isHovering)`; actions at `ClipCardView.swift:410-438` are only hit-testable while hovering, driven solely by `.onHover` (`ClipCardView.swift:163-168`). Confidence: confirmed.
Recommendation: Surface quick actions when the card is selected, or add an always-rendered focusable action region. Base hit-testing on `isSelected || isHovering`.

[MEDIUM] History is hard-capped at 300 with no load-more or indication that older clips exist
Evidence: `ClipStore.swift:29` `displayLimit = 300` used at lines 48 and 313; empty state (`ClipListView.swift:840-853`) only fires when `visibleClips.isEmpty`. Confidence: confirmed.
Recommendation: Add a "Showing 300 most recent" footer or "Load more" control; consider cursor pagination for large histories.

[LOW] Empty search state has no actionable CTA to clear the query
Evidence: `ClipListView.swift:866-868` returns a plain `Text` with no button; Esc-to-clear exists at `ClipListView.swift:373-377`. Confidence: confirmed.
Recommendation: Add a "Clear search" button to the empty state.

[LOW] Return pastes only the single anchored clip even when a multi-selection is active
Evidence: `ClipListView.swift:986-996` `pasteSelected` uses `selectedClip` (952-954) regardless of `selectedClipIDs`. Confidence: confirmed.
Recommendation: When `selectedClipIDs.count >= 2`, route Return to `onPasteMany`.

[LOW] Keyboard arrow keys cannot extend the multi-selection (only Shift+click can)
Evidence: `ClipListView.swift:956-959` `moveSelection(by:)` only moves `selectedIndex`; no Shift+Arrow handler in the search field's `onKeyPress` set (`ClipListView.swift:360-395`). Confidence: confirmed.
Recommendation: Add Shift+Up/Down to extend `selectedClipIDs` from `selectedIndex`.

[LOW] Hover swaps out category color dots and rich-text indicator, losing persistent context
Evidence: `ClipCardView.swift:199-205` fades `trailingMetadata` (including category dots 379-383, rich-formatting indicator 388-394) to opacity 0 on hover. Confidence: confirmed.
Recommendation: Keep category dots and rich-text/pin badges mounted during hover; move only the timestamp out of the way.

[POLISH] Pointing-hand cursor pushed/popped per card hover can stack on rapid moves
Evidence: `ClipCardView.swift:163-168` `NSCursor.pointingHand.push()` / `pop()` per card. Confidence: suspected.
Recommendation: Drive the cursor via a single container `.onHover` or use `.cursor(.pointingHand)`.

### Scripts panel

[HIGH] Panel runs scripts with no confirmation while Settings requires one
Evidence: `Script.swift:60` documents the gate; `ScriptsView.swift:26-32` implements `confirmationDialog`; `ScriptsPanelView.swift:316-327` run() calls `ScriptRunner.run` directly; `ScriptsPanelView.swift:175-201` fires immediately. Confidence: confirmed.
Recommendation: Pick one policy. Given scripts execute arbitrary code, add at least a first-run confirmation to the panel, or update the Script.swift doc to say only the Settings editor confirms.

[HIGH] Switching script selection silently discards unsaved edits
Evidence: `ScriptsView.swift:226-231` `select(_:)` replaces `@State editing` with no dirty check; `ScriptsView.swift:220-224` `newScript()` likewise; editor binds directly to `$editing` (lines 140-154). Confidence: confirmed.
Recommendation: Track a dirty flag and warn on replace, or auto-save on selection change.

[MEDIUM] No cancellation for running scripts
Evidence: `ScriptsView.swift:164-171` comment "No cancel yet (out of scope)"; `ScriptsPanelView.swift:316-327` launches a Task with no handle; only bound is the 30s timeout in `ScriptRunner.swift:9`. Confidence: confirmed.
Recommendation: Thread a Task handle and add a Cancel button; have `Subprocess.run` check for cancellation.

[MEDIUM] Running result can render under the wrong script in Settings editor
Evidence: `ScriptsView.swift:14-15` uses shared `@State running`/`result`; `run()` (248-259) writes to shared state; `select()` (227) clears it. Confidence: confirmed.
Recommendation: Key run state by script id (as `ScriptsPanelView.swift:17` does) or capture the launched script id and ignore stale results.

[MEDIUM] Delete has no confirmation and no undo
Evidence: `ScriptsView.swift:242-246` `deleteSelected()` calls `store.delete` immediately; `ScriptStore.swift:65-68` removes with no undo. Confidence: confirmed.
Recommendation: Add a `confirmationDialog` or keep a recently-deleted buffer for undo.

[MEDIUM] No search or filter for the scripts list
Evidence: `ScriptsPanelView.swift:56-78` and `ScriptsView.swift:53-129` render ForEach with no filter field. Confidence: confirmed.
Recommendation: Add a debounced search field above the list in both views.

[MEDIUM] Output truncation is never surfaced to the user
Evidence: `ScriptResult.truncated` exists (`Script.swift:130`) and is populated (`ScriptRunner.swift:45`) but never shown; `ScriptsPanelView.swift:270` hard-codes `.prefix(2000)` with no marker; `ScriptsView.swift:207-216` also ignores it. Confidence: confirmed.
Recommendation: Render a visible "Output truncated" banner when `result.truncated`; append "(showing first 2000 of N characters)" when applying the display cap.

[LOW] "Save as clip" silently ignores success/failure
Evidence: `ScriptsPanelView.swift:291-295` calls `store.saveScriptOutput(result.stdout)` and discards the Bool return. Confidence: confirmed.
Recommendation: Surface a brief confirmation on success and an inline error on failure.

[LOW] stderr cannot be copied from the panel
Evidence: `ScriptsPanelView.swift:281-305` outputActions only offer Copy/Save when `hasStdout`; failed runs that produced only stderr have no one-click copy. Confidence: confirmed.
Recommendation: Add a "Copy stderr" button when `result.stderr` is non-empty.

[LOW] Reorderable script rows are not keyboard-selectable
Evidence: `ScriptsView.swift:82-125` builds rows as `HStack` with `.onTapGesture` (line 114), not a `Button`, as a drag workaround. `onTapGesture` is not keyboard-focusable and VoiceOver does not announce it as actionable. Confidence: confirmed.
Recommendation: Wrap the row in `Button` with `buttonStyle(.plain)`; attach `.draggable` to an explicit drag handle.

[LOW] IconPickerView emoji tab lacks search while symbols tab has it
Evidence: `IconPickerView.swift:65-69` search only when `iconTab == .symbol`; emoji tab (105-114) is a fixed 32-emoji list with no filter. Confidence: confirmed.
Recommendation: Add a filter field to the emoji tab, or document why it is omitted.

[LOW] Double spinner while a script runs in the panel
Evidence: `ScriptsPanelView.swift:175-201` runButton shows a ProgressView; `ScriptsPanelView.swift:113-114` also renders `runningView` (205-214) with a second ProgressView. Confidence: confirmed.
Recommendation: Drop the button spinner while `runningView` is shown, or collapse `runningView` into the button area.

[LOW] Empty-state CTA label overpromises what onOpenSettings does
Evidence: `ScriptsPanelView.swift:44` label "Open Settings > Scripts", but `onOpenSettings` from `ClipListView.swift:335` opens the settings window generally with no tab guarantee. Confidence: suspected.
Recommendation: Have `onOpenSettings` accept a destination and route `SettingsView` to that tab, or relabel to "Open Settings".

### AI Assistant chat

[HIGH] Thread does not auto-scroll while the assistant reply streams in
Evidence: `AIAssistantPanelView.swift:373-382` ScrollViewReader only scrolls on `onChange(of: vm.messages.count)` and `onChange(of: vm.state)`; during streaming `messages.last.text` mutates (`AIAssistantPanelView.swift:116`) without changing count or state. Confidence: confirmed.
Recommendation: Add `onChange(of: vm.messages.last?.text)` that scrolls the live bubble to bottom while `state == .streaming`; throttle to the 50ms flush cadence.

[HIGH] User's typed prompt is discarded before provider config is validated
Evidence: `AIAssistantPanelView.swift:51-63` send() clears `inputText = ""` on line 54, then validates `AIService.fromSettings()` on 57-63 and returns leaving `state = .notConfigured`. Confidence: confirmed.
Recommendation: Move `inputText = ""` to after the config check succeeds, or restore `inputText = text` in the failure branch.

[MEDIUM] Comment claims streaming selection is off, but the NSTextView bubble is selectable
Evidence: `AIAssistantPanelView.swift:515-517` comment vs `StreamingSelectableText.makeNSView` (line 644) sets `tv.isSelectable = true`. Confidence: confirmed.
Recommendation: Rewrite the comment to match reality, or toggle `isSelectable` off during streaming and on when `isLive` ends.

[MEDIUM] Confirmation card defaults to Allow on the Return key for code-executing tools
Evidence: `AIAssistantPanelView.swift:601-603` Deny has `.escape`, Allow has `.return` and `.borderedProminent`; `AIAgent.swift:94-98` gates `run_script`/`execute_code` via `confirmHook`. Confidence: confirmed.
Recommendation: Make Deny the default-action button (Return) and require an explicit click or Cmd+Return for Allow on gated tools.

[MEDIUM] Round-cap summary turn is non-streaming with no progress indicator
Evidence: `AIAgent.swift:175-178` after maxRounds (8) calls non-streaming `provider.complete`; UI shows `state=.streaming` with no new tokens and, if the last bubble had text, no spinner (`AIAssistantPanelView.swift:388-389`). Confidence: confirmed.
Recommendation: Stream the summary turn, or emit an explicit toolActivity "Summarising..." before the non-streaming call.

[MEDIUM] No retry on transient network/HTTP errors during a turn
Evidence: `AIStreaming.swift:44-71` and `AIProviders.swift:16-35` issue a single URLRequest with no retry. Confidence: confirmed.
Recommendation: Add a 2-3 attempt retry wrapper for retryable statuses (408, 429, 500, 502, 503, 504) with jittered backoff; surface "Retrying (attempt 2/3)..." via toolActivity.

[MEDIUM] Empty assistant bubble renders alongside the thinking indicator
Evidence: `AIAssistantPanelView.swift:84-85` appends an empty placeholder; `showThinkingIndicator` (388-390) is true while text is empty, so both the blank bubble and the "Thinking..." pill render. Confidence: confirmed.
Recommendation: Suppress the empty assistant bubble while `showThinkingIndicator` is true, or fold the spinner into the live bubble.

[MEDIUM] AIActionRunner has no cancellation and AIActionSheet failed state has no retry
Evidence: `AIActionsView.swift:25-43` run() launches a Task with no stored handle; `AIActionSheet` running phase (71-77) has no Stop; failed phase (78-88) offers only Close. Confidence: confirmed.
Recommendation: Store the Task, add `cancel()` and a Stop button; add a Retry button in the failed phase.

[LOW] Tool-only assistant turns are dropped from history on subsequent sends
Evidence: `AIAssistantPanelView.swift:193-200` buildHistory skips assistant messages whose text is empty; tool activities are not serialized into `AIMessage.content`. Confidence: confirmed.
Recommendation: Serialize tool activities (or a stub) into `AIMessage.content`, or keep a persisted transcript.

[LOW] Idle-timeout error surfaces as "HTTP -1" which reads as a bug, not a timeout
Evidence: `AIStreaming.swift:48-49` throws `AIError.http(-1, "stream idle timeout")`; `AIProvider.swift:32-34` renders it as "Provider returned HTTP -1: stream idle timeout". Confidence: confirmed.
Recommendation: Add a dedicated `AIError.idleTimeout` case with a user-friendly message.

[LOW] Suggestion buttons fill the input but do not send, and no keyboard submit hint
Evidence: `AIAssistantPanelView.swift:322-348` tapping a suggestion sets `vm.inputText` and focuses the field; with `axis: .vertical` and `lineLimit(1...4)` Enter semantics is ambiguous; no hint. Confidence: suspected.
Recommendation: Add a Send affordance hint (e.g. a Cmd+Return glyph) and decide a single convention; optionally offer "fill and send" for suggestions.

[LOW] Message bubbles and tool-activity rows lack accessibility labels and traits
Evidence: `AIAssistantPanelView.swift:468-562` MessageBubble has no `.accessibilityLabel`/`.accessibilityAddTraits`; streaming "Thinking..." (392-406) and `StreamingSelectableText` (500-504) carry no announcements; grep found no `AccessibilityNotification.Announcement` or live-region usage. Confidence: confirmed.
Recommendation: Add `.accessibilityElement(children: .combine)` with "You: ..." / "Assistant: ..." labels; post `.announcement` when a turn starts and completes.

[POLISH] Action diff is two stacked boxes with no word-level highlighting; code blocks have no copy button
Evidence: `AIActionsView.swift:126-133` comment calls it "a weak diff"; `MarkdownTheme.swift:22-36` code blocks render in a horizontal ScrollView with no copy affordance or syntax highlighting. Confidence: confirmed.
Recommendation: Add word-level diff spans and a copy-button overlay on fenced code blocks.

### Settings

[HIGH] MCP Install button blocks the main thread on a semaphore-waited subprocess
Evidence: `SettingsView.swift:1056-1065` calls `McpInstallService.install` in a Button action; `McpInstallService.swift:151-167` `runCLI` uses `DispatchSemaphore` + `sem.wait()`. Confidence: confirmed.
Recommendation: Make `install` async (or wrap the call site in `Task.detached`), set a per-client "installing" state, apply the result on MainActor. Remove the semaphore-wait from `runCLI`.

[MEDIUM] iCloud sync export/import runs on @MainActor
Evidence: `ICloudSyncService.swift:14` `@MainActor final class`; `sync()` (line 60) calls `ClippyArchive.exportTOML`/`importTOML` (lines 74, 101) which read/write SQLite and serialize TOML on the main thread during "Sync now". Confidence: suspected.
Recommendation: Move the heavy DB/TOML work to a background executor; touch `@Published` status only on MainActor.

[MEDIUM] No global "Reset all settings to defaults" affordance
Evidence: `AppSettings.swift:556-570` only provides `clearColorOverrides()`; no master reset in the UI. Confidence: confirmed.
Recommendation: Add a "Reset all settings to defaults" action with a confirmation dialog in the General tab.

[MEDIUM] "Test AI connection" is disabled until AI features are enabled
Evidence: `SettingsView.swift:955` `Button("Test AI connection"){ test() }.disabled(testing || !settings.aiEnabled)`. Confidence: confirmed.
Recommendation: Allow "Test AI connection" regardless of `aiEnabled`; testing is read-only.

[MEDIUM] MCP install flow has no Uninstall / Remove path
Evidence: `SettingsView.swift:1036-1068` always renders Install; `McpInstallService.swift:30-47` only implements install/isInstalled. Confidence: confirmed.
Recommendation: Add `McpInstallService.remove(client)`; swap the button label to "Uninstall" when installed.

[MEDIUM] MCP configuration is filed under "AI" instead of "Integrations"
Evidence: `SettingsView.swift:139-147` routes `.ai` to `AISettingsTab()` containing MCP (997-1095); `.integrations` (1190-1290) holds 1Password/iCloud/export. Confidence: confirmed.
Recommendation: Move MCP into `IntegrationsSettingsTab`, or split MCP into its own sidebar section.

[MEDIUM] refreshInstalledClients shells out on every AI tab appearance
Evidence: `SettingsView.swift:1098-1101` `.onAppear` calls `refreshInstalledClients()`, which (1134-1145) spawns `Task.detached` calling `McpInstallService.isInstalled`, which runs `claude mcp list` via `runCLI` (129-137). Confidence: confirmed.
Recommendation: Cache the result with a TTL or refresh only on explicit user action.

[LOW] Mixed use of deprecated single-arg and current two-arg .onChange
Evidence: `SettingsView.swift:312, 325` use two-arg; `SettingsView.swift:1102, 1269` use single-arg (deprecated under Swift 6.2). Confidence: confirmed.
Recommendation: Standardize on the two-arg form across all tabs.

[LOW] Switching AI provider discards an in-progress API key entry
Evidence: `refreshKeyStatus()` begins `apiKey = ""` (`SettingsView.swift:1106`) and is called on `.onAppear` and `.onChange(of: settings.aiProvider)` (1102). Confidence: confirmed.
Recommendation: Only clear `apiKey` when the provider actually changed; preserve the draft per provider.

[LOW] @State snapshots in tabs are not kept in sync with AppSettings
Evidence: `CaptureSettingsTab` initializes `ignoredAppsText`/`soundVolumeSlider` once (`SettingsView.swift:703, 706`); `GeneralSettingsTab` initializes `launchAtLogin` once (210). iCloud import (`ICloudSyncService.swift:101`) will not reflect. Confidence: confirmed.
Recommendation: Drive these via `.onChange` or read the settings value directly; observe `SMAppService.mainApp.status` for launchAtLogin.

[LOW] No inline validation for AI endpoint URL, model, or 1Password vault name
Evidence: `SettingsView.swift:919, 924, 927, 1237` bare TextFields with no validation; errors only surface on "Test AI connection", which is itself gated on `aiEnabled`. Confidence: confirmed.
Recommendation: Validate `aiBaseURL` as a URL on commit and show an inline error (reuse the `CustomColorRow.commit` pattern at `SettingsView.swift:649-667`); reject empty vault name when 1Password is on.

[LOW] isPortFree called inline in the Port row on every body render
Evidence: `SettingsView.swift:1008` `let portFree = mcpController.isPortFree(settings.mcpPort)` inside the `LabeledContent` closure. Confidence: suspected.
Recommendation: Compute once and cache, invalidating only when `mcpPort` or MCP status changes.

[POLISH] Keychain items written without label/description attributes
Evidence: `KeychainStore.swift:23-30` builds the add query with no `kSecAttrLabel`/`kSecAttrDescription`. Confidence: confirmed.
Recommendation: Add `kSecAttrLabel` ("Clippy - <provider> API key") and `kSecAttrDescription`.

### Popup panel & window lifecycle

[HIGH] Stale previousApp routes paste/keystrokes to the wrong app
Evidence: `PanelController.swift:45-48` captures `previousApp` in show() only when frontmost is not Clippy; long-lived panels never refresh it; `restoreFocusToPreviousApp()` (105-109) reactivates the stale app. Confidence: confirmed.
Recommendation: Capture `previousApp` at paste/keystroke time from `NSWorkspace.shared.frontmostApplication` when it is not Clippy, or refresh on resign-key to a non-Clippy app.

[HIGH] Focus-restore race with fixed delays after deprecated activate()
Evidence: `AppDelegate.swift:104-105` onPaste calls `restoreFocusToPreviousApp()` then `pasteService.paste()` (0.12s, `PasteService.swift:27`); `onSendKeystrokes` uses 0.15s (`AppDelegate.swift:148`); `previousApp.activate()` (`PanelController.swift:108`) is the no-arg deprecated form. Confidence: suspected.
Recommendation: Use `activate(options: .activateAllWindows)`; poll/confirm first-responder via AXUIElement before posting the keystroke, with bounded retry. Drop the fixed sleeps.

[MEDIUM] Escape dismiss bypasses hide(), losing lastPanelOrigin and remembered size
Evidence: `PastePanel.swift:10-15` cancelOperation calls `orderOut(nil)` directly; `PanelController.hide()` (90-98) is the only path that saves `lastPanelOrigin` and size. Confidence: confirmed.
Recommendation: Route cancelOperation through `PanelController.hide()`.

[MEDIUM] EditorWindowController leaks the previous editor window when opening a second clip
Evidence: `EditorWindowController.swift:9-30` open() creates a new NSWindow with `isReleasedWhenClosed=false` and unconditionally reassigns `self.window`; the prior window is dropped without close/orderOut. Confidence: confirmed.
Recommendation: Track editor windows in a set or explicitly close the existing one before reassigning.

[MEDIUM] CaretLocator Y-flip uses only primary screen height, wrong on secondary displays
Evidence: `CaretLocator.swift:67-75` flips Y using `primary.frame.height` only; for carets on non-primary screens the conversion produces a Cocoa y in the wrong screen. Confidence: suspected.
Recommendation: Flip against the global max-Y (union of all NSScreen frames) or against the screen whose frame contains the AX rect.

[MEDIUM] HotKeyCenter ignores RegisterEventHotKey status, silently fails on conflict
Evidence: `HotKeyCenter.swift:49-56` calls RegisterEventHotKey without checking the OSStatus; on conflict the hotkey stops working with no log or UI feedback. Confidence: confirmed.
Recommendation: Check the return status; log via ClippyLog and surface a banner in Settings offering an alternate binding.

[MEDIUM] Opening Settings from the panel triggers hideOnClickAway, contradicting "panel stays visible" intent
Evidence: `PanelController.swift:69-73` comment says panel stays visible; `AppDelegate.swift:301-320` `openSettings()` calls `NSApp.activate()` + makeKeyAndOrderFront, causing `windowDidResignKey` (PanelController.swift:125-131) to hide the panel when `hideOnClickAway` is true. Confidence: confirmed.
Recommendation: Suppress `windowDidResignKey` while a Clippy-owned window (Settings/editor) is taking key.

[MEDIUM] normalOrder float level renders the nonactivating panel invisible behind the frontmost app
Evidence: `PanelController.swift:149-152` sets `panel.level = .normal` and `isFloatingPanel = false` while keeping the panel nonactivating; frontmost app windows cover it. Confidence: confirmed.
Recommendation: Document `.normalOrder` as requiring app activation, or keep `isFloatingPanel=true` for nonactivating panels; warn in Settings.

[LOW] Caret mode shows the panel at the mouse anchor then jumps to the caret (flicker)
Evidence: `PanelController.swift:81-87` shows with `fastFrame()` at mouse, then `repositionAtCaretAsync()` (207-227) moves it when the AX result returns; async hop plus >4pt threshold causes a visible reposition. Confidence: confirmed.
Recommendation: Defer `makeKeyAndOrderFront` until after the caret lookup (with a short timeout fallback to mouse anchor).

[LOW] Hotkey is not user-customizable
Evidence: `HotKeyCenter.swift:18-20` hardcodes Cmd+Shift+V; `AppDelegate.swift:96` is the only registration; no hotkey keys in `AppSettings`; `SettingsView` never calls `HotKeyCenter.register`. Confidence: confirmed.
Recommendation: Add a hotkey capture control in Settings backed by an AppDefault; re-register on change.

[LOW] Panel header icon-only buttons rely on tooltip, not accessibilityLabel
Evidence: `PanelHeaderView.swift:54-71` pin/gear/close use `.help()` only; no `.accessibilityLabel`. Confidence: suspected.
Recommendation: Add `.accessibilityLabel` and `.accessibilityValue` (for pin state) to each header button.

[LOW] screen(containing:) force-indexes NSScreen.screens when main is nil
Evidence: `PanelController.swift:263-267` `?? NSScreen.main ?? NSScreen.screens[0]`; if both are nil/empty, index-out-of-bounds crash. Confidence: confirmed.
Recommendation: Guard with `NSScreen.screens.first` and return a fallback.

### Categories & Information Architecture

[MEDIUM] System nav rows mixed with user categories, no section separators
Evidence: `CategorySidePane.swift:34-53` ScrollView LazyVStack lists `store.categories` then 1Password/Scripts/Assistant rows in one flat stack with no dividers. Confidence: confirmed.
Recommendation: Add section labels/headers (e.g. "Collections" above categories, "Tools" above system rows), or move system rows to a fixed footer.

[MEDIUM] Category reorder shows neutral highlight instead of insertion line
Evidence: `CategorySidePane.swift:18-22, 133-159` use a full-row `tint.opacity(0.22)` highlight for both clip-filing and category-reorder; clip reorder uses `ReorderableForEach.swift:153-160` insertion line. Confidence: confirmed.
Recommendation: When payload is `reorder:cat:<n>`, render an insertion line (top/bottom by cursor position) instead of the full-row highlight.

[MEDIUM] AI Actions have no side-pane nav row, breaking the four-collection symmetry
Evidence: `CategorySidePane.swift:177-203` defines rows for Scripts and Assistant but not AI Actions; AI Actions only reachable via clip context menu (`ClipListView.swift:692-723`) and Settings. Confidence: confirmed.
Recommendation: Give AI Actions a dedicated side-pane row, or document why Scripts merits one while AI Actions does not.

[MEDIUM] moveClip writes every sortOrder row unconditionally
Evidence: `ClipDatabase+Categories.swift:179-188` loops `UPDATE clip_category SET sortOrder = ?` for every pair with no guard; sibling `moveCategory` (76-80) correctly guards `sortOrder != index`. Confidence: confirmed.
Recommendation: Add the same skip guard so a one-clip reorder issues one UPDATE instead of N.

[LOW] Starter "Pinned" category loses custom name and position when recreated
Evidence: `ClipDatabase+Categories.swift:86-100` `ensureStarterCategoryID` recreates with hardcoded "Pinned"/#FF9500/pin.fill/maxOrder+1, discarding any rename. Confidence: confirmed.
Recommendation: Persist the starter's last attributes before deletion, or recreate at the original sortOrder.

[LOW] No duplicate category name validation
Evidence: `CategoryEditorView.swift:35-41, 64-74` only checks for empty; duplicates are allowed, which makes AI Suggest Category (`ClipListView.swift:777`) ambiguous. Confidence: confirmed.
Recommendation: Warn when the trimmed name matches an existing category.

[LOW] Category drag-to-reorder cannot drop at end of list
Evidence: `CategorySidePane.swift:141-156` drop closure always calls `moveCategory(id:beforeCategoryID:)`; no end-of-list drop target; `reorderIDs` (24-28) supports appending when target is nil but the UI never passes nil. Confidence: confirmed.
Recommendation: Add a trailing drop zone that calls `moveCategory` with end-of-list semantics.

[LOW] Category delete has no undo and no confirmation
Evidence: `CategorySidePane.swift:99-102` "Delete" immediately calls `store.deleteCategory`; clips are silently unfiled. Confidence: confirmed.
Recommendation: Show a confirmation or an undo toast that re-creates the category and re-files its clips.

[POLISH] Nav row counts are inconsistent across destinations
Evidence: `CategorySidePane.swift:88` categoryRow passes a count; `historyRow`/`onePasswordRow`/`scriptsRow`/`assistantRow` all pass `count: nil`. Confidence: confirmed.
Recommendation: Show counts where meaningful (Scripts count, History total) or drop the count column for consistency.

[POLISH] Category color limited to fixed 10-swatch palette
Evidence: `CategoryEditorView.swift:47-52` iterates `CategoryPalette.hexes` (10 hexes, `Theme.swift:274-279`); no custom picker. Confidence: confirmed.
Recommendation: Add a "Custom..." swatch that opens NSColorPicker or a hex field.

### Interaction Patterns & Motion

[MEDIUM] Drag-to-reorder cannot drop at the end of a list
Evidence: `ReorderableForEach.swift:152-176` drop destination draws a 2pt insertion line at `.top` only; no trailing drop target in `ClipListView.sectionedList` (489-516) or `CategorySidePane` (34-53); dropping last row on itself is rejected. Confidence: confirmed.
Recommendation: Add a full-width trailing drop destination after the last row, or switch insertion line between `.top`/`.bottom` based on cursor position.

[MEDIUM] Inline rename field has no visible focus ring
Evidence: `SelectAllTextField.swift:25-26` `field.focusRingType = .none`; the SwiftUI overlay ring (`ClipCardView.swift:286-289`) only appears once the field is mounted; tabbing in shows no system focus ring. Confidence: confirmed.
Recommendation: Use `.default` focusRingType or add an explicit focus-state ring driven by first-responder notification.

[MEDIUM] All list keyboard shortcuts are scoped to the search field; focus loss strands the keyboard user
Evidence: `ClipListView.swift:359-410` all `.onKeyPress` handlers attached via `.focused($searchFocused)`; `searchFocused` is set true only on `.onAppear` (415); clicking a card button can move first-responder away, after which shortcuts stop firing. Confidence: suspected.
Recommendation: Attach key handlers to a container view in the responder chain, or re-assert `searchFocused = true` after each card action; alternatively use NSEvent local monitoring in the panel controller.

[LOW] Single-tap gesture fires on both clicks of a double-click paste
Evidence: `ClipListView.swift:599-611` attaches `TapGesture(count: 2)` and `TapGesture(count: 1)` via separate `.simultaneousGesture` modifiers; the count:1 gesture fires on every mouse-down including both clicks of a double-click. Confidence: confirmed.
Recommendation: Use `.highPriorityGesture` for count:2 so SwiftUI waits for the double-tap timeout before committing the single-tap.

[LOW] Pinned panel silently ignores Escape with no feedback
Evidence: `PastePanel.swift:10-14` cancelOperation returns early when `panelPinned`/`hideOnEscape` true; footer hint (`ClipListView.swift:923`) still advertises Esc as "close". Confidence: confirmed.
Recommendation: Honor Esc by unpinning and closing, or flash the pin glyph; reflect pinned state in the footer hint.

[POLISH] OCR status banner and showStatusBanner use different auto-dismiss timings
Evidence: `ClipListView.swift:651-655` dismisses after 3s; `showStatusBanner` (801-809) after 2s. Confidence: confirmed.
Recommendation: Unify via a single `dismissBanner(after:)` helper; scale delay with message length or standardize on 3s.

### Accessibility

[HIGH] Dynamic Type / system text size is ignored app-wide
Evidence: `Support/Theme.swift:219-267` `PanelTypography.make` builds fonts via `.system(size:)`/`.custom(family, size)` with fixed `CGFloat(settings.fontSizeBase)`; grep finds 0 uses of `@ScaledMetric`, `dynamicTypeSize`, or text styles. Confidence: confirmed.
Recommendation: Adopt `@ScaledMetric` for the base size or switch to `Font.textStyle`-based fonts with `.dynamicTypeSize(...)`.

[HIGH] AI chat messages have no accessibility labels, role, or streaming announcements
Evidence: `AI/AIAssistantPanelView.swift:468-542` MessageBubble has no `.accessibilityElement`/`.accessibilityLabel`/`.accessibilityAddTraits`; streaming "Thinking..." (392-406) and `StreamingSelectableText` (500-504) are not announced; no `AccessibilityNotification.Announcement` usage. Confidence: confirmed.
Recommendation: Add `.accessibilityElement(children: .ignore)` + "You: ..."/"Assistant: ..." labels; post `.announcement` on turn start/complete.

[MEDIUM] No accessibilityHint or accessibilityValue used anywhere in the codebase
Evidence: Grep returns 0 matches for both. Stateful controls (panel pin `PanelHeaderView.swift:54-66`, 1Password reveal `OnePasswordView.swift:347-358`, expand/collapse `OnePasswordView.swift:120-153`, color swatches `CategoryEditorView.swift:81-93`, icon cells `IconPickerView.swift:142-156`) communicate state only visually. Confidence: confirmed.
Recommendation: Add `.accessibilityValue` ("pinned"/"not pinned", "expanded"/"collapsed", etc.) and `.accessibilityHint`; replicate `CategorySidePane`'s `.isSelected` pattern.

[MEDIUM] OnePasswordView bypasses theme tokens with AppKit .secondary/.tertiary colors that can fail WCAG AA
Evidence: `OnePasswordView.swift` uses `.foregroundStyle(.secondary)`/`.tertiary` in 9 places (lines 78, 163, 174, 192, 211, 314, 336, 369); `.tertiaryLabelColor` resolves to roughly 2.5:1 on light cards, below AA 4.5:1. Confidence: confirmed.
Recommendation: Replace with `tokens.textSecondary` / a dedicated tertiary token so the WCAG fix in `ThemePreset` applies here.

[MEDIUM] OnePasswordView expand/collapse item rows do not expose state
Evidence: `OnePasswordView.swift:120-153` itemRow is a plain Button with `.buttonStyle(.plain)`; chevron `.rotationEffect` is the only affordance; no `.accessibilityValue`/`.accessibilityAddTraits(.isButton)`/`.accessibilityHint`. Confidence: confirmed.
Recommendation: Add `.accessibilityAddTraits(.isButton)`, `.accessibilityValue(isExpanded ? "expanded" : "collapsed")`, and `.accessibilityHint`.

[MEDIUM] CategoryEditorView color swatches and IconPickerView cells do not expose selected state
Evidence: `CategoryEditorView.swift:81-93` colorSwatch has `.accessibilityLabel("Color N")` but no `isSelected` trait/value; `IconPickerView.swift:142-156` iconCell is a Button with label but no `isSelected` trait. Confidence: confirmed.
Recommendation: Add `.accessibilityAddTraits(isSelected ? .isSelected : [])` to both; give swatches a descriptive label including hex/name.

[LOW] Menu-bar status item has no initial toolTip; image description is the only name
Evidence: `AppDelegate.swift:228-230` sets `statusItem.button?.image` but not `toolTip`; toolTip is only assigned later in `togglePause` (`AppDelegate.swift:298`). Confidence: confirmed.
Recommendation: Set `statusItem.button?.toolTip = "Clippy"` immediately after assigning the image.

[LOW] SelectAllTextField disables the native focus ring
Evidence: `UI/SelectAllTextField.swift:26` `field.focusRingType = .none`; only a caller-provided overlay provides contrast, violating WCAG 2.4.7 (Focus Visible) if a caller forgets. Confidence: confirmed.
Recommendation: Keep the system focus ring or guarantee the accent overlay at the SelectAllTextField level.

[LOW] PlainTextEditor NSTextView has no accessibility label
Evidence: `UI/PlainTextEditor.swift:10-33` configures the NSTextView but never calls `setAccessibilityLabel`; in `ScriptsView.swift:147` VoiceOver announces only raw text. Confidence: confirmed.
Recommendation: Add an `accessibilityLabel` parameter and apply it via `textView.setAccessibilityLabel(...)`.

[LOW] No reduce-transparency handling for custom blur background
Evidence: `UI/ThemedBackground.swift:30-44` `ThemedPanelBackground` forces `VisualEffectBlur` when `panelOpacity < 1.0` with no check of `@Environment(\.accessibilityReduceTransparency)`. Confidence: suspected.
Recommendation: When `accessibilityReduceTransparency` is true, render `tokens.panel` at full opacity and skip the blur.

### Empty, Loading, Error & Success States

[HIGH] Database open failure crashes the app via fatalError with no recovery UI
Evidence: `Storage/ClipDatabase.swift:8-14` `static let shared` wraps `try ClipDatabase()` in a do/catch that calls `fatalError`. Confidence: confirmed.
Recommendation: Replace `fatalError` with a published error state surfaced by a launch window with Show in Finder, Retry, and Quit options.

[HIGH] Search failures are silently swallowed and render as a misleading "No clips match" empty state
Evidence: `UI/ClipStore.swift:312` `(try? database.searchClips(...)) ?? []`; `ClipListView.swift:866` renders "No clips match ...". Confidence: confirmed.
Recommendation: Catch the error explicitly, log via ClippyLog.storage, and surface an error banner with Retry; keep the empty message only for true zero-results.

[HIGH] OCR status banner renders success and failure identically with no severity, icon, or retry
Evidence: `UI/ClipListView.swift:309-323` renders `ocrStatusMessage` as plain `Text` with `tokens.textPrimary`; `ClipStore.swift:261-290` produces success and failure strings in the same neutral style. Confidence: confirmed.
Recommendation: Promote the banner to a typed status (success/warning/error) with matching token color and SF Symbol; for failures include a Retry button.

[HIGH] AIActionSheet failed state offers only Close, no retry
Evidence: `AI/AIActionsView.swift:78-88` failed branch renders a Label, message, and a single `Button("Close")`. Confidence: confirmed.
Recommendation: Add a Retry button next to Close; have `AIActionRunner` retain the last work closure.

[HIGH] AI Assistant error bubbles have no retry CTA
Evidence: `AIAssistantPanelView.swift:153-160` sets bubble text to `error.localizedDescription`; `MessageBubble.swift:481-489` renders with a danger glyph/border but no action. Confidence: confirmed.
Recommendation: Add a Retry button under error bubbles that re-sends the preceding user message.

[MEDIUM] Batch AI title failures are logged but not surfaced to the user
Evidence: `UI/ClipListView.swift:258-271` per-clip catch only logs; final banner shows "Titled N of M" with no failure reason or per-clip retry. Confidence: confirmed.
Recommendation: When done < targets, include the failure reason and offer a Retry-failed action.

[MEDIUM] ScriptsView Save gives no success or failure feedback
Evidence: `UI/ScriptsView.swift:233-240` save() calls store.add/update; `ScriptStore.swift:50-63` wraps JSONFileStore without error return. Confidence: confirmed.
Recommendation: Have `ScriptStore.add/update` return a Result/Bool; surface a themed success banner and an error banner with Retry.

[MEDIUM] ScriptsView running state has no cancel path despite 30s timeout
Evidence: `UI/ScriptsView.swift:164-171` comment "No cancel yet (out of scope)"; `Scripts/ScriptRunner.swift:8-46` has a 30s timeout but no cancellation token to the UI. Confidence: confirmed.
Recommendation: Thread a Task through `ScriptRunner.run` and add a Cancel button, mirroring `AIAssistantPanelView.stop()`.

[MEDIUM] ScriptsView suppresses its true empty state by auto-creating a blank script
Evidence: `UI/ScriptsView.swift:25` `.onAppear { if store.scripts.isEmpty { newScript() } ... }`. Confidence: confirmed.
Recommendation: Show a `ContentUnavailableView`-style empty state; preserve `newScript` for the explicit + button.

[MEDIUM] MCP install probe runs in background with no inline loading indicator
Evidence: `UI/SettingsView.swift:1134-1145` detached Task probes each McpClient; Install rows show empty circles (1046-1053) indistinguishable from "not installed". Confidence: confirmed.
Recommendation: Add an `installedClientsLoading` state and render a ProgressView in the Install rows while loading.

[MEDIUM] Settings test-connection results lack success/failure visual distinction
Evidence: `UI/SettingsView.swift:956-961` (AI test) and `1088-1093` (MCP test) render `testResult` as `Text(...).foregroundStyle(.secondary)` regardless of outcome; contrast key-save at 936-945 which uses checkmark/xmark + color. Confidence: confirmed.
Recommendation: Adopt the key-save pattern for all test/install results.

[MEDIUM] ClipStore DB observation onError only logs; UI shows stale or empty with no error state
Evidence: `UI/ClipStore.swift:57-59, 88-90` `onError` only calls `ClippyLog.error`; published arrays stay at last values. Confidence: confirmed.
Recommendation: Publish an `observationError: String?`; render an error banner in `ClipListView` with a Retry button that re-starts the ValueObservation.

[LOW] AIAssistantPanelView empty-response diagnostic has no retry
Evidence: `AI/AIAssistantPanelView.swift:142-150` injects an error bubble with no retry button. Confidence: confirmed.
Recommendation: Add a Retry button that re-sends the last user message.

[LOW] Empty states use inconsistent patterns across surfaces
Evidence: `AI/AIActionsManagerView.swift:65-68` uses `ContentUnavailableView`; `ClipListView.swift:840-853` hand-rolled; `AIAssistantPanelView.swift:298-320` hand-rolled; `ScriptsView` has none. Confidence: confirmed.
Recommendation: Standardize on `ContentUnavailableView` or a shared `ClippyEmptyState` wrapper.

[LOW] iCloud sync failure is shown inline in red but the only remediation is re-clicking Sync now
Evidence: `UI/SettingsView.swift:1281-1283` renders `cloud.status` in red when failed; no error reference code or cause hint. Confidence: suspected.
Recommendation: Include the underlying error string and a short remediation hint.

[POLISH] AI Assistant streaming state shows only a generic thinking indicator with no per-step progress
Evidence: `AIAssistantPanelView.swift:388-406` `showThinkingIndicator` only until first token; tool activity shown as small labels (544-562) with no aggregate progress. Confidence: suspected.
Recommendation: For agent turns, show a compact step list (tool name -> status) inside the assistant bubble while streaming.

## Top Issues

1. [HIGH] `onChange(of: store.clips)` deep-compares up to 300 full clips per keystroke and resets selection - `ClipListView.swift:135`
2. [HIGH] Search has no debounce; every keystroke runs a synchronous FTS5 query on the main thread - `ClipStore.swift:12-14`
3. [HIGH] MCP Install button blocks the main thread on a semaphore-waited subprocess - `SettingsView.swift:1056-1065`
4. [HIGH] Database open failure crashes the app via `fatalError` with no recovery UI - `ClipDatabase.swift:8-14`
5. [HIGH] Search failures are silently swallowed and render as a misleading "No clips match" empty state - `ClipStore.swift:312`
6. [HIGH] Stale `previousApp` routes paste/keystrokes to the wrong app - `PanelController.swift:45-48`
7. [HIGH] Focus-restore race with fixed delays after deprecated `activate()` - `PanelController.swift:105-109`
8. [HIGH] Settings window bypasses PanelTypography, so the user's font choice does not apply - `SettingsView.swift:81`
9. [HIGH] Thread does not auto-scroll while the assistant reply streams in - `AIAssistantPanelView.swift:373-382`
10. [HIGH] User's typed prompt is discarded before provider config is validated - `AIAssistantPanelView.swift:51-63`
11. [HIGH] Panel runs scripts with no confirmation while Settings requires one - `ScriptsPanelView.swift:316-327`
12. [HIGH] Switching script selection silently discards unsaved edits - `ScriptsView.swift:226-231`
13. [HIGH] Dynamic Type / system text size is ignored app-wide - `Theme.swift:219-267`
14. [HIGH] AI chat messages have no accessibility labels, role, or streaming announcements - `AIAssistantPanelView.swift:468-542`
15. [HIGH] OCR status banner renders success and failure identically with no retry - `ClipListView.swift:309-323`

## Bugs

| Title | Severity | File:Line | Repro / Impact |
|---|---|---|---|
| `onChange(of: store.clips)` deep-compares up to 300 Clips (full text + RTF/HTML Data) on every keystroke and DB pulse, then resets selection | high | `ClipListView.swift:135-136` | Type in search or copy anything in background while multi-selecting; selection vanishes and panel lags. |
| KeystrokeService iterates `unicodeScalars`, splitting grapheme clusters (combining marks, emoji skin tones) into separate key events that mangle on input | high | `Paste/KeystrokeService.swift:30-58` | Send "cafe\u{0301}" or a skin-tone emoji as keystrokes; the typed result is wrong. |
| `restoreFocusToPreviousApp` only calls `activate()`; the 0.15s fixed delay before typing does not guarantee the target text field is first responder | high | `PanelController.swift:105-109`; `AppDelegate.swift:136-151` | "Send as keystrokes" into some apps produces beeps or no text; matches reported broken-keystroke pain. |
| SelectAllTextField focus-and-select-all is a one-shot race: if `field.window` is nil when the deferred Task runs, focus is silently never granted | medium | `SelectAllTextField.swift:31-34` | Trigger Rename from card hover/context menu; cursor often not placed, title not selected. |
| AI Assistant does not auto-scroll during streaming: onChange only fires on `messages.count`, so streaming tokens scroll out of view | medium | `AIAssistantPanelView.swift:373-382` | Ask a long-answer question; new text renders below the visible area, view appears "frozen". |
| AIAssistantViewModel.runningTask retains self for the duration of the stream; if the provider stream never terminates and cancel does not propagate, the ViewModel leaks and state stays `.streaming` | medium | `AIAssistantPanelView.swift:106-161` | A hung provider stream causes a permanent UI freeze plus a leak; matches "AI chat freeze" report. |
| Menu-bar icon reported top-25% cutoff: code comment denies clipping but the SF Symbol configuration and bounce overshoot can clip | medium | `Support/StatusBarIcon.swift:9-31, 52-58`; `AppDelegate.swift:228-230` | Status-bar icon reads as top-cropped/offset; `wantsLayer` + `masksToBounds` clips the bounce overshoot. |
| `Theme.tokens` is a computed property recomputed on every access; views read it many times per render, multiplying work across 300 cards | low | `Support/AppSettings.swift:528`; `ThemePreset.swift:198-234` | Compounds panel/Settings lag; each access re-parses up to 13 custom hex strings. |
| Background clipboard capture wipes an in-progress multi-selection without notice | medium | `ClipListView.swift:135-136`; `ClipStore.swift:54-63` | Build a multi-selection, then copy anything; selection count badge and batch bar disappear. |
| ClipEditorView ImageClipEditor uses deprecated single-argument `onChange(of:)` for geometry size | low | `ClipEditorView.swift:364`; `SettingsView.swift:1102` | Deprecation warnings under Swift 6.2; first-layout pass may leave `canvasSize` at `.zero`. |

## Feature Requests

| Title | Priority | Gap File:Line |
|---|---|---|
| Capture multi-file Finder selections (not just the first URL) | high | `Sources/Clippy/Capture/ClipboardMonitor.swift:157-167` |
| Persist AI Assistant conversations across panel sessions | high | `Sources/Clippy/AI/AIAssistantPanelView.swift:28-29`; `Sources/Clippy/Panel/PanelController.swift:58-59` |
| Add an undoable trash / soft-delete for clips instead of permanent removal | high | `Sources/Clippy/UI/ClipListView.swift:182-184`; `Sources/Clippy/Storage/ClipDatabase.swift:369-376` |
| Surface iCloud sync status in the menu bar and panel header, not only Settings | medium | `Sources/Clippy/Integrations/ICloudSyncService.swift:19-20`; `Sources/Clippy/AppDelegate.swift:297-298` |
| Make the global summon hotkey user-configurable | medium | `Sources/Clippy/Support/HotKeyCenter.swift:18-20`; `Sources/Clippy/AppDelegate.swift:96` |
| Add a keyboard shortcut to file the selected clip into a category | medium | `Sources/Clippy/UI/ClipListView.swift:396-410` |
| Extend multi-selection by keyboard (Shift+Up/Down, Cmd+Shift+A invert) | medium | `Sources/Clippy/UI/ClipListView.swift:355-360` |
| Add Quick-Look style full-content preview without opening the editor | medium | `Sources/Clippy/Storage/Clip.swift:43-46`; `Sources/Clippy/UI/ClipCardView.swift:132-137` |
| Add discoverable date-scope filter chips instead of hash-token syntax only | medium | `Sources/Clippy/Storage/ClipSearchQuery.swift:7-11`; `Sources/Clippy/UI/ClipListView.swift:349-411` |
| Add a per-clip Share menu (NSSharingServicePicker) and export-to-file | low | `Sources/Clippy/UI/ClipListView.swift:612-670` |
| Add snippet templates with fill-in placeholders to Scripts | low | `Sources/Clippy/Scripts/Script.swift:61-96`; `Sources/Clippy/Scripts/ScriptRunner.swift:30-37` |
| Introduce a lightweight Favorites/Star flag distinct from category membership | low | `Sources/Clippy/UI/ClipStore.swift:127-147` |

## User Stories

- As a user who has filed dozens of clips into a category, when I select that category and type in the search bar, nothing filters. I want the query to filter the clips in whichever pane I am viewing, so I can find one clip among 80 filed under a category without scrolling. | `ClipListView.swift:83-96`; `ClipStore.swift:193-206`
- As a user who selects 5 files in Finder and presses Cmd+C, I expect all 5 to land in Clippy as file clips. Today only the first file URL is captured; the other 4 silently disappear. I want my multi-file copy preserved so I can paste the whole set back. | `ClipboardMonitor.swift:156-167`
- As a user who accidentally deletes a clip, it is gone forever with no undo or Trash. I want a brief undo window (or a Trash category) so a misclick does not cost me a clip, especially a pinned one. | `ClipListView.swift:172-184`; `ClipStore.swift:215-218`
- As a user chatting with the AI Assistant, when the panel hides after a paste, the entire conversation is gone. I want my assistant thread to persist across panel show/hide cycles (and across restarts), so a paste does not throw away a multi-turn conversation. | `AIAssistantPanelView.swift:27-28`; `PanelController.swift:58-59`
- As a keyboard-first user, I can move the selection with Up/Down and select all with Cmd+A, but I cannot extend the selection with Shift+Up/Shift+Down. I want Shift+Arrow to extend the multi-selection from the keyboard anchor so I never have to reach for the mouse. | `ClipListView.swift:956-959`, `360-395`
- As a user who writes scripts, I want to parameterize a run with an argument or prompt input, not just feed it the clipboard. I want a "Run with input..." affordance so I can reuse one script against different inputs without editing its body each time. | `ScriptsPanelView.swift:316-327`; `Script.swift:42`
- As a user with many secrets in my Clippy vault, the 1Password pane lists every item with no search field. I want a search box at the top that filters items by title as I type, matching the History pane. | `OnePasswordView.swift:26-98`
- As a user, when the panel appears, I often want to nudge it, but only the 30pt header strip is draggable. I want to drag the panel by its body (or at least a larger title region) so repositioning does not require aiming for a thin strip. | `PanelController.swift:167`; `PanelHeaderView.swift:8-18, 77`
- As a user, the card shows a truncated preview line and the only full-content view is the editor, which commits on Save. I want a read-only quick preview (Space-bar Quick Look or inline expand) so I can read a long clip without launching an editing surface. | `ClipCardView.swift:132`; `ClipEditorView.swift:24-273`
- As a user who copied a batch of screenshots, I can run "Extract Text" one clip at a time but there is no batch OCR. I want to multi-select image clips and run Extract Text on all of them, the way I can multi-select and "Set Titles with AI". | `ClipListView.swift:644-660`, `244-272`
- As a user with maxHistoryItems set to 500, I have no idea how full history is. I want a small count (e.g. "342 / 500") so I can tell when old clips are about to be evicted. | `ClipListView.swift:909-929`; `AppSettings.swift:210-211`
- As a user who wants to stop Clippy from recording a particular app, I have to manually type bundle IDs into Settings. I want a "Don't capture from this app" command so I can exclude the frontmost app without hunting for its bundle identifier. | `SettingsView.swift:812-846`; `ClipboardMonitor.swift:83-87`

## Recommended Next Steps

1. Fix the main-thread hot paths first (they account for the most-reported "lag/freeze" pain): debounce search, replace `onChange(of: store.clips)` with an id-based or count-based change signal, move MCP Install off the semaphore-wait pattern, and cache `Theme.tokens` on `AppSettings`.
2. Repair the focus-restore path: replace deprecated `activate()` with `activate(options: .activateAllWindows)`, add a first-responder readiness check with bounded retry, and refresh `previousApp` at paste/keystroke time.
3. Replace silent fatal/error swallow paths with recovery UI: DB-open published error state, search error banner with Retry, OCR typed-status banner with retry, AI error-bubble retry buttons, script-save feedback.
4. Add undo/soft-delete for clips and persist AI conversations across panel sessions (the two highest-impact data-loss gaps).
5. Close the accessibility baseline: add `accessibilityHint`/`accessibilityValue` to stateful controls, role labels and live-region announcements to AI chat, `@ScaledMetric`/text-style fonts for Dynamic Type, and keyboard-reachable card actions.
6. Align cross-surface consistency: route Settings through `PanelTypography`, replace hardcoded `Color.white`/`Color.black`/`.regularMaterial` with tokens, move MCP into Integrations, and standardize empty states on `ContentUnavailableView`.
7. Make confirmation defaults safe: Deny as the Return default on AI tool-confirmation cards, and a first-run confirmation for panel-run scripts.
8. Add the missing keyboard verbs: Shift+Arrow range select, a "file to category N" hotkey, and container-scoped (not search-field-scoped) key handlers so focus loss does not strand the keyboard user.
9. Tackle the smaller polish items in a sweep: spacing scale token, trailing drop targets for reorder, insertion-line cue for category reorder, double-spinner removal, status-bar icon bbox fix, keychain labels.
10. Verify each fix with the reported repro: type in search with 300 clips, multi-select then background-copy, "Send as keystrokes" into a text field, ask the AI a long question, delete a clip, reopen the panel after a paste.