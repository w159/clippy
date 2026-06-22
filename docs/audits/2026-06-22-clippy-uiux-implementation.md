# Clippy UI/UX Audit - Implementation

> 2026-06-22. Implements the findings from `2026-06-22-clippy-uiux-audit.md`.
> Method: load-bearing core fixes done directly and verified building; remaining leaf fixes fanned out to 6 file-disjoint implementer agents + 1 build-and-fix stage.

## Verification status

- `swift build` : **green** (42 files changed across both phases, +~3300 / -~760).
- `swift test` : **not run** - this shell has only CommandLineTools (`xcode-select -p` = `/Library/Developer/CommandLineTools`), so the `XCTest` module is unavailable. This is an environment limitation, not a regression. To verify tests, install/select full Xcode (`xcode-select --install` or `sudo xcode-select -s /Applications/Xcode.app`) then run `swift test`. The changes are additive (new banners, retry buttons, a11y modifiers, debouncing, a token cache) and do not alter storage schemas or public APIs, so no new test failures are expected.
- No manual UI run was performed (no display in this environment). The audit's repro paths (search with 300 clips, multi-select then background-copy, send keystrokes into a text field, long AI answer, delete a clip, reopen after paste) should be exercised in the real app to confirm feel.

## Done directly (core, load-bearing)

| Area | Change | File |
|---|---|---|
| Perf | Debounced search (~180ms); empty query refilters immediately | `UI/ClipStore.swift` |
| Errors | `@Published searchError` + `retrySearch()`; `@Published observationError` + `retryObservation()` | `UI/ClipStore.swift` |
| Search scope | `clipsForCategory` now filters by the active query; added `Clip.matchesLocally(query:)` | `UI/ClipStore.swift` |
| Keystrokes | Iterate grapheme clusters (Character), not unicodeScalars - fixes emoji/combining-mark mangling | `Paste/KeystrokeService.swift` |
| Focus | `previousApp` re-resolved at action time; `activate(options: [.activateAllWindows])` | `Panel/PanelController.swift` |
| Panel | Escape routes through `hide()` (preserves origin/size); Settings/editor no longer dismisses panel; screen lookup no longer force-indexes | `Panel/PastePanel.swift`, `Panel/PanelController.swift` |

## Done by the workflow (file-disjoint implementers + build-fix)

Counts from each implementer's report:

| Group | Files | Implemented | Skipped |
|---|---|---|---|
| clip-list | ClipListView.swift | 16 | hover-action keyboard reach (owned by ClipCardView) |
| settings | SettingsView, AppSettings, McpInstallService, KeychainStore, ICloudSyncService | 17 | Theme.tokens cache on AppSettings |
| ai | AIAssistantPanelView, AIActionsView, AIAgent, AIStreaming, AIProviders, AIProvider, MarkdownTheme | 17 | word-level diff spans (copy button added) |
| scripts | Script, ScriptStore, ScriptRunner, ScriptsView, ScriptsPanelView, IconPickerView | 17 | none |
| categories-reorder | ReorderableForEach, CategorySidePane, CategoryEditorView, ClipDatabase+Categories | 11 | trailing drop target for ClipListView wiring; category insertion-line top/bottom by cursor |
| panel-a11y-misc | ClipDatabase, AppDelegate, StatusBarIcon, HotKeyCenter, CaretLocator, EditorWindowController, ClipboardMonitor, PanelHeaderView, SelectAllTextField, PlainTextEditor, ThemedBackground, OnePasswordView, ClipCardView | 17 | hover-action `isSelected || isHovering`; ClipCardView swatchRow isSelected trait |

Build-fix stage: 4 iterations, 8 cross-agent compile errors repaired (onKeyPress overload resolution, ObjCBool init, caseless-enum init, optional flattening in starter snapshot, in-memory DatabaseQueue try!, two @MainActor hop fixes in AppDelegate, URLError member name). Final build: green, zero unresolved.

## Known remaining / skipped (honest gaps)

Picked up after the workflow in a follow-on pass:

- Hover-revealed card quick actions now appear and accept input when the card is selected (`showsActions = isHovering || isSelected`), so keyboard users who navigate by selection can reach pin/edit/rename/delete. (`UI/ClipCardView.swift`)
- `Theme.tokens` is now memoized on `AppSettings` with an input-signature cache, so the ~13-hex reparse runs once per change instead of per-access per-card. (`Support/AppSettings.swift`)
- Category reorder trailing drop target and top insertion-line cue confirmed already wired by the workflow (`UI/CategorySidePane.swift` + `ReorderableForEach.reorderTrailingDropDestination`).

Still not implemented (follow-up):

1. Clip-within-category trailing drop target: DONE in the release pass. `ClipListView` now renders a `trailingClipDropZone` after the last clip in a category pane, wired via `reorderTrailingDropDestination(kind: "clip")` to `store.moveClip(_:inCategory:before: nil)` (nil target appends, confirmed in `ClipDatabase+Categories.moveClip`). History pane is excluded (no within-list reorder). `swift build` green.
2. Category reorder insertion line is top-only, not top/bottom-by-cursor-position. Deferred: SwiftUI's `.dropDestination` isTargeted callback does not expose the cursor location, so splitting top/bottom needs a location-aware drop surface (NSItemProvider/NSDraggingDestination or a half-row overlay). That is a non-trivial visual change that cannot be verified without a display, so it was not shipped in this release.
3. ClipCardView color-swatch `isSelected` a11y trait: the in-card swatch is a display element (not a selector), so the trait does not apply; left as-is. The selectable swatches in `CategoryEditorView` did get the trait.
4. Word-level diff highlighting in AIActionSheet skipped (copy button on code blocks was added).
5. Dynamic Type adoption is partial - the central `PanelTypography` still uses fixed point sizes; per-view `@ScaledMetric` was applied where local fonts are built. Full Dynamic Type via text-style-based fonts in `Theme.swift` was DEFERRED: it is a global typography change across every panel surface and could not be visually verified in this environment (no display). It should be implemented and verified in a UI-capable environment before release to avoid a visual regression. Per-view `@ScaledMetric` and Dynamic-Type-aware modifiers remain in place where local fonts are built.

## Feature requests implemented

- Multi-file Finder selections captured as separate file clips (`Capture/ClipboardMonitor.swift`) - was the highest-priority feature request.
- Others (persist AI conversations across sessions, undoable clip trash, configurable hotkey, Quick Look preview, date-scope filter chips, per-clip Share, snippet templates, Favorites flag) were **not** implemented in this pass - they require new storage/persistence and are larger than leaf-view edits. They remain in the audit report's Feature Requests table as a backlog.

## Next steps

1. Run `swift test` in an Xcode-configured environment to confirm no regressions.
2. Exercise the audit's repro paths in the running app to confirm the "lag/freeze" and focus/keystroke fixes.
3. Pick up the 7 known remaining items above.
4. Triage the Feature Requests backlog (separate workstream; most need storage changes).