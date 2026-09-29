# Roadmap

Clippy's single source of truth for known gaps and planned work. Rebuilt on 2026-09-29
from a full audit of v1.10.0 plus the uncommitted OCR change (built as
`1.10.1-audit`). Every item below is backed by evidence; nothing was carried in from
memory.

## How this was produced

| Stream | Method | Output |
|---|---|---|
| Live build | `scripts/make-app.sh 1.10.1-audit` (exit 0), `swift test` (341 tests, 0 failures) | `.atlas/evidence/2026-09-29-audit-baseline-build-test.txt` |
| Live UI walkthrough | Drove the running build with System Events and CGEvent; resized the panel from 500x400 to 2200x1259; walked every panel section and every Settings tab | 72 screenshots in `.atlas/evidence/2026-09-29-ui-audit/` |
| Area code audit | 11 areas, each sent with line-numbered source to Ollama cloud models (`glm-5.3-flash`, `deepseek-v4.1-flash`) | 201 critical/high/medium claims |
| Claim verification | 4 parallel verifiers opened every cited line | 108 confirmed, 41 partial, 31 refuted, 21 duplicates. Only confirmed and partial claims appear here; the refuted ones are listed in Appendix A so nobody re-reports them |
| Root cause of reported defects | Explorer traced the six defects the owner named | Folded into sections 1-6 |
| Platform and competitor research | WWDC25/26 sessions, swift.org, vendor pages for Paste, Raycast, Maccy, Alfred, Pastebot, PastePal, CleanClip, Clipy | Sections 16-17 |

### Legend

- **Evidence**:
  - `L` means observed live, with the screenshot name under `.atlas/evidence/2026-09-29-ui-audit/`.
  - `C` means verified by reading the code at the cited `file:line`. Paths are relative to `Sources/Clippy/`.
  - `P` means a partial verification: the issue is real, but the claim's details or severity were adjusted.
- **Severity**:
  - `S1` covers data loss, crashes, security, and compliance.
  - `S2` means a feature is broken or unusable.
  - `S3` means a feature is degraded or confusing.
  - `S4` covers polish and code health.
- **IDs** are stable. Reference them in commits and CHANGELOG entries (`fix(PNL-03): ...`).

---

## Delivery plan

Phases run in order. The items within a phase are independent unless noted. Each item
closes only when its check is recorded in `.atlas/.run/findings.json` and the CHANGELOG.

### Phase 0: stop data loss, crashes, and compliance exposure (S1)
Ship as a point release before any redesign work.

- **DAT-01**: JSONFileStore wipes scripts or AI actions on a decode failure.
- **DAT-02**: JSONFileStore silently ignores write errors.
- **DAT-03**: a failed iCloud quarantine deletes the only remote copy.
- **DAT-04**: iCloud sync can overwrite a not-yet-downloaded archive.
- **DAT-05**: iCloud sync has no file coordination.
- **DAT-06**: the absolute ceiling evicts pinned or categorized clips.
- **EDT-01**: quitting the app discards dirty editors.
- **EDT-04**: the external editor writes empty text into the clip on truncate.
- **AI-01**: clearing the assistant mid-stream crashes the app.
- **SEC-02**: secrets render in clear text on cards.
- **SEC-03**: the MCP loopback endpoint is unauthenticated.
- **SEC-04**: the 1Password secret appears in the `op` argv.
- **MCP-02**: a config file that fails to parse is overwritten.
- **OCR-01**: OCR overwrites the user's clipboard.

### Phase 1: rebuild the panel shell and clip layout (the owner's top complaints)

1. **ARCH-01**: split `ClipListView` (1503 lines) and `SettingsView` (1748 lines). No
   behavior change, and it goes first because every item below touches these files.
2. **PNL-01 to PNL-10**: window style, resize, move, focus, and multi-display behavior.
3. **LAY-01 to LAY-12**: card grid, column math, the card rebuild, compact rows, and the
   preview pane.
4. **SBR-01 to SBR-06**: a resizable, collapsible sidebar with a persisted width.
5. **KEY-01 to KEY-08**: keyboard model and search behavior.

### Phase 2: make existing features correct
OCR (OCR-*), AI assistant and actions (AI-*), scripts (SCR-*), clip editor (EDT-*),
capture and paste (CAP-*), settings (SET-*), integrations (MCP-*, OPW-*).

### Phase 3: power-user feature set (section 16)
Paste stack, transforms, snippets, smart filters, Quick Look, retention rules, Shortcuts
and App Intents, a CLI and URL scheme, semantic search, and sensitive-content detection.

### Phase 4: platform modernization (section 17)
Liquid Glass, Swift 6 language mode with `@Observable`, the Foundation Models tool layer,
App Intents and Spotlight, `RecognizeDocumentsRequest`, and encryption at rest.

---

## 1. Popup panel window (PNL)

Owner report: "popup window behavior" is broken.

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| PNL-01 | S2 | The panel cannot be moved by the user. `isMovableByWindowBackground = false`, and there is no drag region in the header. The `.lastPosition` mode only remembers where `hide()` last saved it. | C `Panel/PanelController.swift:192`; `UI/PanelHeaderView.swift` has no drag handler | Make the header a drag region (`WindowDragGesture` on macOS 15+, or an `NSView` with `mouseDownCanMoveWindow`). Keep controls excluded. |
| PNL-02 | S2 | The resize affordance is unclear. A borderless `.resizable` panel shows no grip or cursor, and the AX-driven resize in the walkthrough does not prove that mouse edge-resize works. | C `Panel/PanelController.swift:182-187`; verifiers disagree (A82 refuted statically, explorer SUSPECTED). Runtime mouse check needed | Use a `.titled` + `.fullSizeContentView` + hidden titlebar style so AppKit supplies real resize edges and cursors, or add explicit edge and corner handles. |
| PNL-03 | S2 | The minimum size is below the layout's real minimum. `minSize.width = 280`, while the sidebar takes `max(150, 25%)`, which leaves about 130pt for a 140pt card. At 500x400, the timestamps wrap, the footer wraps, and the sidebar list is cut off. | C `Panel/PanelController.swift:196`, `UI/ClipListView.swift:384-386`; L `11-panel-500x400.png` | Derive `minSize` from the layout (sidebar min + one card min + gutters), or collapse the sidebar below a breakpoint (SBR-02). |
| PNL-04 | S3 | Opening the panel while it is visible rebuilds the view, which resets the query, the selection, the scroll position, and the frame. | C `AppDelegate.swift:264-266` | Guard on `panel.isVisible`: focus the search field instead of rebuilding. Keep one `ClipListView` alive and reset state explicitly. |
| PNL-05 | S3 | Caret mode shows the panel at the mouse, then jumps it to the caret after an async AX lookup. | C `Panel/PanelController.swift:85-94, 219, 249-251` | Resolve the caret before `orderFront`, with a 50 ms budget, and fall back to the mouse without moving afterwards. |
| PNL-06 | S3 | There is no screen-parameter observer. A saved origin on an unplugged display is clamped only on the next show. `centeredFrame` is unclamped, and `clamped()` pins the bottom edge when the panel is taller than the screen. | C `Panel/PanelController.swift:97-105, 222-224, 273-289` | Observe `NSApplication.didChangeScreenParametersNotification`. Store the frame per display (keyed by `CGDirectDisplayID`). Clamp every mode. |
| PNL-07 | S3 | Settings and editor windows open behind the panel, because the panel's default level is `.statusBar` (always-on-top). | C `AppDelegate.swift:276-294`, `Panel/PanelController.swift:169` | Lower the panel to `.normal` while any Clippy window is key, or hide the panel when Settings or the editor opens. |
| PNL-08 | S3 | `activate(options:)` is deprecated since macOS 14, and the comment above it describes the opposite behavior. | C `Panel/PanelController.swift:125-127` | Use `NSRunningApplication.activate(from:options:)` / `NSApp.yieldActivation(to:)`. |
| PNL-09 | S3 | The hotkey is fixed at Cmd+Shift+V. Registration failures are stored in `lastError` but never surfaced, and there is only one hotkey. | C `Support/HotKeyCenter.swift:24-26, 66-72`; L Settings General shows the hotkey as static text | Add a hotkey recorder with conflict detection. Add separate hotkeys for show, paste-plain, paste-previous, and paste-stack. Show registration errors in Settings. |
| PNL-10 | S4 | Clicking the status item always opens a menu, and the panel is reachable only through "Open Clipboard". The status item has no quick-paste of recent clips. | C `AppDelegate.swift:259`; L walkthrough | Left-click toggles the panel and right-click opens the menu (configurable). Show the last 5-10 clips in the menu. |
| PNL-11 | S4 | Escape hides the panel in one step, even when a search query is present. | L walkthrough | Two-stage Escape: the first press clears the query, the second hides the panel. |
| PNL-12 | S4 | The panel reports as `AXSystemDialog` with no title. | L walkthrough | Set an accessibility title and identifier for assistive tech and UI automation. |

## 2. Clip grid, cards, and card styles (LAY)

Owner report: "cards/card styles/card columns/entire card UI overlaps and escapes the
window it's meant to be inside of".

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| LAY-01 | S2 | At 4 columns and 923pt wide, the layout breaks. Names truncate to "Micro...", timestamps collapse to one character per line ("2/h/a/g/o"), and text spills out of the card. Dimension labels clip at the right edge. | L `41-cols4-923.png`, `44-plain-4col.png` | See LAY-02 and LAY-03. |
| LAY-02 | S2 | Column-fit math ignores the card's own chrome. `minCardWidth` is a hard-coded 140pt, but the 4pt stripe and 20pt of padding leave 116pt of content. The header row (title, app icon, category icons, 28pt hover buttons) is wider than that. | C `UI/ClipListView.swift:98-102, 729-735`; P (overflow proven live) | Measure the header's minimum (`ViewThatFits` with a compact header variant), or use `GridItem(.adaptive(minimum:))` sized from the real minimum. Replace the fixed count with an "Auto" column mode that is the default. |
| LAY-03 | S2 | Card content has no minimum-width guard. The header row has no `.lineLimit`, `.truncationMode`, or `layoutPriority`, and the timestamp is allowed to wrap. | C `UI/ClipCardView.swift:144-171`, header row about lines 236-300 | Give the timestamp `.fixedSize()` + `.lineLimit(1)` with a high `layoutPriority`, give the title `.lineLimit(1)` + `.truncationMode(.tail)`, and drop the app name first under pressure. |
| LAY-04 | S3 | The first render ignores width. `listWidth` starts at 0, so the requested column count is used uncapped until `onGeometryChange` fires, one layout pass late. | C `UI/ClipListView.swift:97, 710-714, 730` | Seed from the panel's content width, or compute columns inside a `GeometryReader` or a custom `Layout`. |
| LAY-05 | S3 | Columns never increase with width. At 1400 and 2200pt wide, 2 columns become very wide cards and the sidebar grows to about 500pt. Columns cap at the setting and never adapt upward. | L `13-panel-1400x900.png`, `14-panel-2200x1300.png` | "Auto" mode (LAY-02). Cap the sidebar width (SBR-01). Cap the card width so wide panels add columns. |
| LAY-06 | S3 | The hover toolbar covers the timestamp and kind icon on every card, and the app name on narrow cards. After a resize, ghost toolbars stay on two cards at once. | L `10-panel-default.png`, `11-panel-500x400.png`, `14-panel-2200x1300.png` | Reserve trailing space for actions, or reveal them in place of metadata with a crossfade. Clear hover state on `onGeometryChange`. |
| LAY-07 | S3 | The card leads with the source app name instead of the content. About 93% of cards read "Microsoft Edge Dev" as their largest text. | 2026-09-16 audit, confirmed live | Rebuild the card with content as the headline and the source app as a small icon in the metadata row. |
| LAY-08 | S3 | There is no compact row mode. Seven clips fill a full-height window, which does not scale to a 600+ clip history. | 2026-09-16 audit | Add a density setting (compact about 32pt, comfortable, cards), with compact as the default for History. |
| LAY-09 | S3 | The per-card colored stroke and the selection compete for the same visual signal. The "Bordered" style could not be told apart from "Plain" in the walkthrough. | 2026-09-16 audit; L `45-bordered-4col.png` (unverified: click may not have applied) | Give the stroke to selection only. Confirm or remove the Bordered style. |
| LAY-10 | S3 | Image thumbnails are cropped inconsistently. A 2784x5380 image shows a thin slice, and a 177x100 image is upscaled and cut off. Transparent images render black because the JPEG thumbnail has no background fill. | L `21-search-kind-image-scrolled-top.png`; C `Storage/MediaStore.swift:193-202` | Use aspect-fit with a checkerboard or fill background, a consistent thumbnail box, and a PNG or HEIC thumbnail for images with alpha. |
| LAY-11 | S3 | There is no preview pane or Quick Look. The full content is visible only by opening the editor. | 2026-09-16 audit; missing-capability sweep | Add a Space-bar Quick Look (`QLPreviewPanel`) and an optional preview column. |
| LAY-12 | S4 | Per-redraw costs: every card observes `AppSettings.shared`, `cardMetadata` is O(clips x categories), `sectionTitle` does Calendar work per clip, and the drag-hover `@State` in the parent invalidates the whole list. | P `UI/ClipCardView.swift:43`, `UI/ClipListView.swift:89, 108, 627-652, 745-766` | Precompute view models in the store, and pass value types into cards. |
| LAY-13 | S4 | `Theme.isAvailable` calls `availableFontFamilies` for every font built, with no cache. | C `Support/Theme.swift:200-203, 257-259` | Cache the family set. |
| LAY-14 | S4 | The `panelMaterial` setting has no consumer. The blur is hard-coded to `.hudWindow`. | C `UI/ThemedBackground.swift:47` | Wire it up, or replace it with Liquid Glass (PLT-01). |

## 3. Category sidebar (SBR)

Owner report: "the popup sidebar can't be resized by grabber with drag left/right".

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| SBR-01 | S2 | The sidebar has no grabber, so it cannot be resized. The separator is a plain `Divider()`, and the width is computed as `max(150, 25%)`. No `DragGesture`, width `@State`, or settings key exists. Dragging at the divider scrolls the card list instead. | C `UI/ClipListView.swift:179-187, 383-386`; L `15-sidebar-drag-left.png`, `16-sidebar-drag-right.png` | Add a 6pt hit strip with `DragGesture` and a `resizeLeftRight` cursor. Clamp the width to 150 up to (panel width - one card - gutters). Persist the width in `AppSettings`. Double-click resets the width. |
| SBR-02 | S3 | The sidebar cannot be collapsed. At 500pt wide, the Scripts, Assistant, and AI Actions entries are hidden behind a nested scroller. | L `11-panel-500x400.png` | Add a toggle (Cmd+Ctrl+S) and an auto-collapse to an icon rail below a breakpoint. |
| SBR-03 | S3 | The History count uses `store.clips.count`, but the pane hides pinned clips. | C `UI/CategorySidePane.swift:116`, `UI/ClipListView.swift:133` | Count what is displayed. |
| SBR-04 | S3 | The "New Category" editor opened from the context menu omits `existingNames`, which disables the duplicate-name check. There is also no uniqueness constraint in the database. | C `UI/ClipListView.swift:955` | Pass `existingNames`, and add a UNIQUE index (with COLLATE NOCASE) on the category name. |
| SBR-05 | S4 | The hover line shows for every string drag, including clip-filing drags, so "file into" and "reorder" look the same. | C `UI/CategorySidePane.swift:191, 207-209` | Show distinct drop indicators for filing and reordering. |
| SBR-06 | S4 | Rows are tap-only, with no keyboard focus or key handling. There is no inline rename and no undo for delete or reorder. Clips cannot be dropped onto History to unfile them, and a multi-selection cannot be dropped onto a category. | P `UI/CategorySidePane.swift:365-370` | Make rows focusable, add rename on double-click, register actions with `UndoManager`, and accept multi-item drops. |
| SBR-07 | S4 | The legacy v5 `sortOrder` backfill SQL is wrong: `COUNT(*)` evaluates to 1 after the WHERE, so the values become 0, -1, -2 and legacy categories list oldest first. | C `Storage/ClipDatabase.swift:241-259` (verifier NEW) | Add a corrective migration that renumbers `sortOrder` by `addedAt DESC`. |

## 4. Keyboard, selection, and search (KEY)

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| KEY-01 | S2 | Filtered results can be invisible because the scroll position does not reset when the query changes. Typing `#image` after scrolling down shows a blank list, while the sidebar reports "History 7". | L `20-search-kind-image.png`, `21-...scrolled-top.png` | `ScrollViewReader.scrollTo(top)` on every query or filter change. |
| KEY-02 | S2 | An empty query does not bump `refilterToken`, so an in-flight FTS result overwrites the cleared list. | C `UI/ClipStore.swift:480-485, 497-501, 517` | Bump the token on every path. Better, make search a cancellable `Task` keyed by query. |
| KEY-03 | S3 | Arrow keys move a flat index through a row-major grid, and Left/Right have no handlers. After clearing the search, Down, Down, Right landed on a card far down the list. | C `UI/ClipListView.swift:493-511, 1383-1386`; L `23-arrow-nav.png` | Add 2D navigation that knows the column count. Add Home/End/PageUp/PageDown. |
| KEY-04 | S3 | Shift+arrow and Shift+click only add to the selection, so a range never shrinks. With a multi-selection active, the arrow keys move a hidden anchor. | C `UI/ClipListView.swift:1392-1405, 1420-1427, 801-804` | Use the anchor+cursor range model (as in Finder), and keep the cursor highlight visible. |
| KEY-05 | S3 | Cmd+A in the search field always selects all clips and never the query text. | C `UI/ClipListView.swift:516-520` | Route Cmd+A to the text when the field has text or a selection. |
| KEY-06 | S3 | Navigation keys are attached only to the search `TextField`, and every click forces focus back to search. | C `UI/ClipListView.swift:493-560, 1432` | Use `focusable()` + `onKeyPress` on the list container with a `FocusState` model. |
| KEY-07 | S3 | Right-clicking an unselected card during a multi-selection applies batch actions to the stale selection. | C `UI/ClipListView.swift:886-907` | Select the clicked card first, unless it is already in the selection (Finder semantics). |
| KEY-08 | S3 | Search is limited. There are no quoted phrases, negation (`-#image`), date ranges, size filters, source-app or category operators, or result highlighting. `#yesterday` returns today as well. An unusable FTS pattern is silently dropped. Derived-kind search can return fewer results than requested. | C `Storage/ClipSearchQuery.swift:120-122`, `Storage/ClipDatabase.swift:539-552, 579-600` | Add a query grammar plus filter chips (kind, app, date, category) that write to it, and highlight matches. |
| KEY-09 | S4 | The main search field stays visible in the Assistant, AI Actions, Scripts, and 1Password views, where it does nothing. The Scripts view stacks a second search field under it. | L `50-assistant.png`, `54-scripts-panel.png` | Give the search field to the active section, or hide it. |
| KEY-10 | S4 | "Show in Timeline" is offered while the user is already in the History timeline. | L `71-text-context-menu.png` | Hide it in context. |
| KEY-11 | S4 | There is no undo for deletions, no Cmd+C copy without pasting, and no drag-out of clips to other apps. | Missing-capability sweep | Add an undo buffer, a copy command, and `.draggable` on cards. |

## 5. OCR and image clips (OCR)

Owner report: "the recent OCR change" is broken or useless.

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| OCR-01 | S1 | Extract Text overwrites the user's clipboard (`clearContents` + `setString`). The text is never shown; the user only sees a banner saying it was copied. | C `UI/ClipStore.swift:405-447` (lines 431-436) | Show the text in a sheet with Copy, Save as clip, and Paste actions. Never clear the clipboard implicitly. |
| OCR-02 | S3 | A full Vision request runs on every panel open (`OCRService.warmUp()` in `show()`), even if OCR is never used. This is deliberate: the uncommitted CHANGELOG entry measures a 24s cold model load. The cost of running it on every open has not been measured. | C `Panel/PanelController.swift:48`, `AppDelegate.swift:111`, `Support/OCRService.swift:52-70` | Measure the warm-up cost. Then warm up only when an image clip is visible or hovered, and rate-limit it (for example once per 10 minutes). |
| OCR-03 | S2 | OCR text is not searchable and is not linked to its source image. The result becomes an unrelated text clip named "Clippy OCR". | C `UI/ClipStore.swift:435`; missing-capability sweep | Store the OCR text in an `ocrText` column on the image clip, index it in FTS, and run it in the background at capture for images (opt-in). |
| OCR-04 | S3 | Whitespace-only output counts as success. OCR cannot be cancelled, and completion inserts a clip without checking that the source clip still exists. | C `UI/ClipStore.swift:418-441, 422` | Trim before the empty check, use a cancellable `Task`, and check existence. |
| OCR-05 | S3 | `ocrInFlightClipIDs` is `@Published` on the store, so every OCR start and finish re-renders the whole list. | C `UI/ClipStore.swift:33`, `UI/ClipListView.swift:816` | Move the per-card state into an `@Observable` per-clip model. |
| OCR-06 | S3 | OCR decodes the full-resolution bitmap with no downsampling, and the capture path round-trips through uncompressed TIFF. | C `Support/OCRService.swift:116-117`, `Storage/MediaStore.swift:167-171, 179` | Use `CGImageSourceCreateThumbnailAtIndex` with a max pixel size, and keep the original encoded data. |
| OCR-07 | S3 | There are no OCR options (language, fast or accurate) and no document-structure OCR. | C `Support/OCRService.swift:96-101` | Adopt `RecognizeDocumentsRequest` (macOS 26) for paragraphs and tables. Add a language setting. |
| OCR-08 | S3 | There is no full-size image preview, no GIF or video support, and no OCR for PDF file clips. Image clips cannot be batch-extracted. | Missing-capability sweep | Covered by the Quick Look item (LAY-11). Add PDF first-page text via PDFKit. |
| OCR-09 | S4 | The monitor suppression for OCR writes depends on `ClipStore.monitor`, which is optional and nil by default. | C `UI/ClipStore.swift:200-204, 430` (call site unverified) | Make it a required init dependency. The test `testOCRResultWriteIsNotRecaptured` must cover the production init. |
| OCR-10 | S4 | Image edits run synchronous main-thread DB writes and full PNG encodes. Save re-encodes even for a title-only change, and Save is disabled when the image fails to load, so rename is impossible. | C `UI/ClipStore.swift:371-381`, `UI/ClipEditorView.swift:562, 588-603` | Move writes off the main thread and write only the fields that changed. |
| OCR-11 | S3 | The v1.10.1 spinner scrim, result banner, single-row result, and "already running" message were verified by logic tests only. Nobody has driven them in the running app. | Session verification gap; `Tests/ClippyTests/OCRExtractTests.swift` covers store logic, not views | Launch the built app, run Extract Text on an image clip, and record screenshots under `.atlas/evidence/`. Add a snapshot test for the scrim (see ARCH-06). |
| OCR-12 | S3 | `recognitionLanguages = []` is set but `automaticallyDetectsLanguage` is never set, so automatic language detection is unconfirmed. English text is recognized correctly, but other scripts have not been tried. | C `Support/OCRService.swift` (`performRecognition(cgImage:)`) | Test with non-English samples. Set `automaticallyDetectsLanguage = true` if it helps, or expose the language setting from OCR-07. |
| OCR-13 | S4 | `OCRServiceTests` still call real Vision. A cold first call took 24-61s locally, so the timeouts were raised to 90s and the tests are slow on a cold machine. They may also fail on a runner without the models. | C `Tests/ClippyTests/OCRServiceTests.swift` | Route them through the injected recognizer, or skip them when `CI` is set, and keep one opt-in real-Vision smoke test. |
| OCR-14 | S4 | The "models are evicted after a period of disuse" figure rests on one observation (about 14 minutes). Warm-up design (OCR-02) assumes it. | Session measurement: 24.4s, then 23.81s 14 minutes later, then 0.1s | Measure eviction timing over several idle intervals, using the new `OCR finished in Xs` log lines, before tuning the warm-up rate limit. |

## 6. AI assistant and AI actions (AI)

Owner report: "the AI tools" are useless.

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| AI-01 | S1 | Clearing the conversation while a reply streams crashes the app with an out-of-range `messages[assistantIndex]`. Retry calls `send()` without `stop()`. | C `AI/AIAssistantPanelView.swift:135, 175, 183, 190-200` | Cancel the task on clear and retry. Address messages by id, not index. |
| AI-02 | S2 | The default provider (Apple Intelligence) ignores tools, yet the panel still offers "search my clips" and "create a clip" and passes the full registry. Replies are plain text and may hallucinate results. The only signal is a log line. | C `AI/AppleIntelligenceProvider.swift:129-144, 174-181`, `AI/AIAssistantPanelView.swift:109-140`, `Support/AppSettings.swift:354` | Short term: add a `supportsTools` capability on `AIProviderKind`, hide tool suggestions, and show a banner. Real fix: Foundation Models `Tool` conformances with `@Generable` arguments for search, create, get, and set-category (PLT-04). |
| AI-03 | S2 | The newest clip is auto-attached as context and hijacks unrelated prompts. "say hi" answered about the clip "Clippy" and refused to say hello. | L `51-assistant-reply.png` | Make attachment explicit (a chip the user adds or removes). Leave it off by default for free-form chat. |
| AI-04 | S2 | At the 8-round cap, the OpenAI, Anthropic, and Ollama providers send raw `__tool_result__` sentinel text to the model. Only Azure transforms it. | C `AI/AIAgent.swift:55, 119-122, 300, 428, 570` | Move the sentinel conversion into a shared message builder. |
| AI-05 | S2 | History replays error bubbles as assistant text, and tool turns as "Ran X" stubs with no results, which corrupts later turns. | C `AI/AIAssistantPanelView.swift:241-252` | Keep a structured transcript (role, tool call, tool result) separate from the display messages. |
| AI-06 | S3 | Streaming duplicates text on Apple Intelligence: a non-monotonic snapshot is yielded whole as a delta. | C `AI/AppleIntelligenceProvider.swift:156-158` | Diff against the previous snapshot, or replace instead of appending. |
| AI-07 | S3 | `create_clip` and `set_clip_category` (including `create_if_missing`) write with no confirmation. The execute-code confirmation truncates the code to 200 characters. | C `AI/AIToolDefinition.swift:170, 266, 375-376, 568-570` | Add a per-tool policy (always, ask, never). Show the full code in a scrollable, monospaced confirmation. |
| AI-08 | S3 | Closing the panel leaks a pending confirmation continuation and its task. | C `AI/AIAssistantPanelView.swift:205-211, 278-320` | Cancel on `onDisappear` and resume the continuation with a denial. |
| AI-09 | S3 | Editing an AI action resets its `sortOrder` to 0, which reorders the list. | C `AI/AIActionsManagerView.swift:311-321` | Preserve `sortOrder` on save. |
| AI-10 | S3 | Every action proposal shows a Before/After diff, including New Clip and Copy, where it makes no sense. The diff is not word-level. | C `AI/AIService.swift:126`, `AI/AIActionsView.swift:127` | Show a diff only for in-place rewrites. Use a word-level diff. |
| AI-11 | S3 | Ollama never sends `num_predict`, so `maxTokens` is ignored. `get_clip` loads `allClips()` to find one id. | C `AI/AIAgent.swift:572, 591, 604`, `AI/AIProviders.swift:141`, `AI/AIToolDefinition.swift:198, 242` | Pass `options.num_predict`. Fetch by primary key. |
| AI-12 | S3 | There is no tool-call transparency (the tool list is not visible in the UI). There is also no token or cost accounting, no context-window management, no conversation persistence, no per-action provider override, and no streaming for custom actions. | L `50-assistant.png`; missing-capability sweep | Add a tool drawer, per-turn usage, chunking against `SystemLanguageModel.contextSize`, and a persisted transcript. |
| AI-13 | S3 | The assistant reply text has low contrast, and AI Actions rows are dim grey on dark. | L `51-assistant-reply.png`, `52-ai-actions.png` | Use semantic label colors (see SET-01). |
| AI-14 | S4 | The New Action sheet nests the symbol-grid scroller inside a scrolling sheet, and the prompt template sits below the fold. There is no template validation, no test run, and no import or export of actions. | L `53-new-action.png` | Redesign as a two-pane editor with a live test against the selected clip. |

## 7. Scripts and the script editor (SCR)

Owner report: "the script editor" is broken or useless.

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| SCR-01 | S2 | The editor is a plain monospaced `NSTextView` with no highlighting, line numbers, indentation handling, or Cmd+S. It ignores theme tokens. | C `UI/ScriptsView.swift:282-330`, `UI/PlainTextEditor.swift:7-142`; L `35-scripts-0.png`, `61-script-typed.png` | Build a code editor view: TextKit 2 with a line-number ruler, syntax highlighting per `ScriptInterpreter` (tree-sitter or regex grammars), auto-indent, Cmd+S, and theme fonts and colors. |
| SCR-02 | S2 | The editor sits inside three nested scrollers (page, list, detail). The list shows about 5 rows, and Save, Run, and the output are below the fold with no auto-scroll. | L `62-script-bottom.png`, `65-script-output.png` | Use a `NavigationSplitView` with the list on the left and the editor filling the height, plus a resizable output drawer. |
| SCR-03 | S2 | node, python3, ruby, and swift launch through `/usr/bin/env` with the GUI PATH, so Homebrew and asdf interpreters are not found. | C `Scripts/Script.swift:50-54`, `Scripts/ScriptRunner.swift:57-60` | Resolve with `Subprocess.findBinary` plus a login-shell PATH probe. Add a preflight check in the editor. Allow a custom interpreter path or shebang. |
| SCR-04 | S2 | Undo survives script switches, and programmatic text replacement bypasses `shouldChangeText`, so Cmd+Z after switching scripts produces garbage. The `isEditingFromTextView` one-shot flag can swallow external updates. | P `UI/PlainTextEditor.swift:79-90, 113-119, 136-140` | Key the editor by script id (`.id(script.id)`), clear undo on switch, and route replacements through `shouldChangeText`/`didChangeText`. |
| SCR-05 | S3 | Timeout and cancel only send SIGTERM, with no SIGKILL escalation, so a script that ignores SIGTERM hangs the run. The 30s timeout is hard-coded. | C `Scripts/ScriptRunner.swift:133-153, 174` | Escalate to SIGKILL after a grace period (kill the process group). Make the timeout a per-script setting. |
| SCR-06 | S3 | The panel output block scrolls horizontally only and is capped at 120pt. The status label reads green "Failed (exit N)" for truncated runs and "Failed" for a user Stop. | C `UI/ScriptsPanelView.swift:357-367, 420-423` | Use a two-axis scrolling output view and distinct Success, Failed, Cancelled, and Timed out states. |
| SCR-07 | S3 | A single bad entry fails the whole Script array decode, and the store then resets to empty (see DAT-01). | C `Scripts/Script.swift:125-140`, `Support/JSONFileStore.swift:105-109` | Decode per element (lossy), and quarantine bad entries. |
| SCR-08 | S3 | The Settings Run ignores `outputToClipboard` and has no "Save as clip". Failed runs cannot be saved either. | C `UI/ScriptsView.swift:475-495` | Share a single run-result component between the panel and Settings. |
| SCR-09 | S3 | After Save, a stale "New script" draft row stays at the top, and the saved script moves to the bottom. The draft survives a delete. `isDirty` ignores `isEnabled`. | L `66-script-list-after-save.png`, `69-script-deleted.png`; C `UI/ScriptsView.swift:38-47` | Replace the draft in place, sort stably, and include every field in the dirty check. |
| SCR-10 | S3 | The Run (play) button on a destructive script row (`dedup.py --delete`) has no confirm step in the panel list, and the up/down arrow badges are unexplained. | L `54-scripts-panel.png` | Add a per-script "confirm before run" flag, and a legend or tooltips for the badges. |
| SCR-11 | S4 | Concurrent runs share a temp file named by script id. The whole clip goes into the `CLIPPY_CLIP` environment variable with no size cap. | C `Scripts/ScriptRunner.swift:41-42, 50, 57-58` | Use a unique temp name per run, and pass large input by stdin or file only. |
| SCR-12 | S4 | Missing features: arguments, working directory, environment variables, streaming output, run history, duplicate, import/export, open in external editor, search in script bodies, custom stdin, and batch operations. | Missing-capability sweep | Phase 2 and 3 backlog. |

## 8. Clip editor and external editor (EDT)

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| EDT-01 | S1 | Quitting discards dirty editors without a prompt, because there is no `applicationShouldTerminate`. | C `AppDelegate.swift:552`, `Panel/EditorWindowController.swift:91-112` | Implement `applicationShouldTerminate`, and prompt or autosave drafts. |
| EDT-02 | S2 | The editor text is initialized once from a `let` snapshot and never observes the store, so Save can overwrite newer content (for example an external-editor sync or an MCP write). | C `UI/ClipEditorView.swift:10, 36, 75` | Observe the clip and detect conflicts, offering Reload, Keep mine, or Compare. |
| EDT-03 | S2 | External-editor sync is one-way. In-app edits never reach the temp file, and a stale snapshot can overwrite them. Sessions, watchers, file descriptors, and temp files are never cleaned up. The watcher silently stops after an atomic save if the re-arm fails. | C `Support/ExternalEditorService.swift:22, 52-96, 114-165` | Add a session object with a lifecycle tied to the editor window, `NSFilePresenter`, and a re-arm with retry. |
| EDT-04 | S1 | There is no debounce and no empty-read guard. A non-atomic save that truncates first writes empty text into the clip. A failed DB write is silent, and `lastKnownText` still advances. | C `Support/ExternalEditorService.swift:122, 156-165` | Debounce 250 ms, ignore an empty read when the previous text was non-empty, and advance `lastKnownText` only after a successful write. |
| EDT-05 | S3 | The external editor is hard-coded to Sublime Text. | C `Support/ExternalEditorService.swift:25-37, 98-108` | Add a picker of apps that open `public.plain-text`. |
| EDT-06 | S3 | There is no markdown preview, rich-text (RTF/HTML) view, syntax highlighting, line numbers, word-wrap toggle, font zoom, or export for text clips. Spell check and smart substitutions are hard-disabled. | Missing-capability sweep | Share one code or text editor component with SCR-01. On macOS 26, use the rich `TextEditor` with `AttributedString` for rich text. |
| EDT-07 | S3 | Save writes text and title separately and runs `renameClip` every time, so a failed title write leaves the editor permanently dirty. | P `UI/ClipEditorView.swift:339-357` | Make the update one transaction. |
| EDT-08 | S3 | The image crop drag reuses the first drag's start point, and the selection is stored in fitted-view coordinates, so a resize misplaces it. There is no undo for transforms. | C `UI/ClipEditorView.swift:531-539, 644-661, 569-583` | Add `onEnded` to reset, store image-space coordinates, and register with `UndoManager`. |
| EDT-09 | S3 | AI actions in the editor are inconsistent: New Clip, Copy, and Category apply immediately, while Title, Rewrite, and Summary only stage. An empty instruction silently dismisses. | C `UI/ClipEditorView.swift:186-192, 263-286` | Stage every action, and validate the input. |
| EDT-10 | S4 | The window title is "Clippy" and never updates after a rename. Closing uses `orderOut`, not `close`, and leaves tab-group state. The dirty prompt is app-modal `runModal`. Find is prefilled with a stale term. The accessibility label is not passed to the text view. | C `Panel/EditorWindowController.swift:53-55, 80-84, 102`, `UI/ClipEditorView.swift:97-103`; L `80-clip-editor.png`, `82-editor-find.png` | Title from the clip, `close()`, a sheet-modal prompt, a per-window find state, and labels. |

## 9. Capture and paste (CAP)

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| CAP-01 | S2 | Paste clears the pasteboard, and an image or file write can silently do nothing, yet Cmd+V is still sent. | C `Paste/PasteService.swift:27, 92-107` | Check `writeObjects` or `setData` results, and abort with a banner on failure. |
| CAP-02 | S3 | The bare "skip next change" flag retires whatever change count comes next, so a foreign copy made in that window is lost. | C `Capture/ClipboardMonitor.swift:142-144, 163-167` | Record the exact change count Clippy produced, and skip only that one. |
| CAP-03 | S3 | Pasteboard coverage is incomplete: JPEG-only, PDF, color, vCard, RTFD, file promises, and multi-item non-file pasteboards are not captured, and the `public.url` flavor is lost on link clips. | C `Capture/ClipboardMonitor.swift:204-225, 475-482` | Add a flavor-preserving capture that stores all representations up to a size budget and restores them on paste. |
| CAP-04 | S3 | The ignore list and source attribution use the frontmost app at poll time, not at copy time. The `org.nspasteboard.source` hint is not used. | C `Capture/ClipboardMonitor.swift:208-212` | Read `org.nspasteboard.source` first, and track app activation history as the fallback. |
| CAP-05 | S3 | Capture failures only go to the log, and `captureFileIfPresent` returns true even when every save failed. | C `Capture/ClipboardMonitor.swift:398-410, 458` | Return the real result and surface repeated failures. |
| CAP-06 | S3 | The Cmd+Option+V move keystroke is sent with no Finder check. Multi-paste uses a fixed 0.15s cadence, and the focus restore uses a fixed 0.12s delay, with no verification. | C `Paste/PasteService.swift:27, 37-45, 67-76` | Target the frontmost bundle id and wait for activation (`NSWorkspace.didActivateApplication`) instead of sleeping. |
| CAP-07 | S4 | `ClipKind.detect` and `previewText` trim a full copy of large text before the size guard. | C `Storage/ClipKind.swift:16-17, 92-96`, `Storage/Clip.swift:44` | Take the prefix before trimming. |
| CAP-08 | S3 | Missing features: capture of the clipboard already present at launch, per-app paste profiles (always plain text into terminals), auto-clear of the clipboard after a delay, a paste stack or sequential paste, merge or append clips, cancellable typing, and a user-defined type blocklist. | Missing-capability sweep; competitor matrix | Phase 3 backlog (section 16). |

## 10. Storage, archive, and sync (DAT)

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| DAT-01 | S1 | `JSONFileStore` sets items to `[]` on a decode failure, and the next save overwrites the file, erasing every script or AI action. | C `Support/JSONFileStore.swift:101-111` | Keep the file untouched on decode failure, rename it to `.corrupt-<date>`, show an alert, and refuse to save until the user resolves it. |
| DAT-02 | S1 | `JSONFileStore.save()` uses `try?` for both encode and write, so failures are silent and the UI reports success. | C `Support/JSONFileStore.swift:120-121` | Throw, log, and surface the error. Write atomically (`.atomic`). |
| DAT-03 | S1 | If `moveItem` fails during quarantine, the code deletes the remote archive, which is permanent loss of the only copy. | C `Integrations/ICloudSyncService.swift:138` (verifier NEW) | Never delete. On failure, copy to local Application Support and stop syncing. |
| DAT-04 | S1 | Pull waits at most 2s for an iCloud placeholder to download, then writes anyway, which can overwrite a not-yet-downloaded archive. | C `Integrations/ICloudSyncService.swift:147-160, 95-96` | Use `NSMetadataQuery` or `startDownloadingUbiquitousItem` and wait for `ubiquitousItemDownloadingStatus == .current` before any write. |
| DAT-05 | S1 | Sync runs pull, import, export, and write with no `NSFileCoordinator`, no lock, and no `NSFileVersion` conflict handling, so two Macs can lose updates. | C `Integrations/ICloudSyncService.swift:88-96, 142-160` | Use coordinated reads and writes and a conflict-version merge. Longer term, move to CloudKit (`CKSyncEngine`) per-record sync. |
| DAT-06 | S1 | Above 10,000 clips, the oldest clips are deleted even if they are pinned or categorized, with no warning. | C `Storage/ClipDatabase.swift:360-388` | Exclude pinned and categorized clips, warn at 90%, and make the ceiling user-configurable. |
| DAT-07 | S2 | File clips export with no path or text and are skipped on import, so they never sync. Image paths are stored as absolute local paths, so images cannot import on another Mac. | C `Storage/ClippyArchive.swift:151-155, 244-262`, `Storage/ClipDatabase+Archive.swift:110` | Bundle media inside the archive (a package) with relative paths. |
| DAT-08 | S3 | Each upsert is its own write, so an import that throws midway leaves a partial import. | C `Storage/ClippyArchive.swift:231-264` | Run the whole import in a single `dbQueue.write` transaction. |
| DAT-09 | S3 | Category export orders by `createdAt` and ignores the per-category `sortOrder`. A duplicate image import keeps the old title and source app. | C `Storage/ClipDatabase+Archive.swift:22-29, 117-119` | Order by `clip_category.sortOrder`, and merge metadata. |
| DAT-10 | S3 | `ExternalChangeWatcher` advances `lastDataVersion` even when the notify call throws, so a change is missed. It polls every 2s on the main thread and can block behind a write. | C `Storage/ExternalChangeWatcher.swift:50-54, 78-90` | Advance only on success. Poll off the main thread, or use a `DispatchSource` on the WAL file. |
| DAT-11 | S3 | `insertTextClip` (the OCR and AI paths) and MCP writes bypass cap and ceiling eviction. `JSONFileStore` rewrites the whole file per mutation and races with MCP edits inside the 2s poll window. | C `Storage/ClipDatabase.swift:448-463`, `Support/JSONFileStore.swift:43-93` | Route every insert through a single eviction chokepoint. Route MCP mutations through the app (XPC or a local socket). |
| DAT-12 | S3 | The database, media, and TOML archive are plaintext. The header comment promises encryption. | C `Storage/ClipDatabase.swift:4-6, 122` | Use SQLCipher (GRDB supports it) with the key in the Keychain, plus a Data Protection class for media. This is a compliance control (GLBA / Reg S-P) for a clipboard that holds client data. |
| DAT-13 | S3 | The default GRDB configuration has no WAL mode or busy timeout, while two processes (the app and MCP) write to the database. | P `Storage/ClipDatabase.swift:122` | Use `DatabasePool` in WAL mode with `busyMode = .timeout(5)`. |
| DAT-14 | S4 | Category create, update, and delete use `try?`, so errors are swallowed. | C `UI/ClipStore.swift:290-300` (verifier NEW) | Throw and surface errors. |
| DAT-15 | S4 | Missing features: a backup and restore UI with snapshots, `VACUUM` and integrity check, orphaned-media sweep reporting, deletion-aware sync, and access to clips older than the 300-item resident cap. | Missing-capability sweep | Phase 3 backlog. |

### DAT-12: encryption at rest. Status: blocked (feasible, needs owner decisions)

Feasibility was measured on 2026-09-29 with a throwaway package outside the repo. Nothing in `Package.swift`, `Sources/`, or `Tests/` was changed for DAT-12, because a working opt-in encryption forces a dependency swap and breaks the MCP reader.

**What was proven**
- GRDB 7.11.0 (`Package.resolved`) has no SwiftPM trait for SQLCipher. Its README says to fork GRDB and edit `Package.swift` (the "GRDB+SQLCipher" comments): add `SQLCipher.swift` (`from: "4.11.0"`), define `SQLITE_HAS_CODEC` for C and Swift plus `SQLCipher`, delete the `GRDBSQLite` library, `systemLibrary` target, and dependency, and enable the `GRDBSQLCipher` target with the `SQLCipher` and `GRDBSQLCipher` dependencies on `GRDB`.
- With those edits the fork resolved SQLCipher.swift 4.19.0 (community, SQLite 3.53.4) and built. A copy of the repo at `HEAD`, pointed at that fork, built both `Clippy` and `clippy-cli`, and its 341-test suite passed with 0 failures. (`HEAD` predates the uncommitted work; the 1110-test suite was not run against the fork.)
- In the fork: a `DatabasePool` (WAL) with an FTS5 table works. `sqlcipher_export` converted plaintext to encrypted and back with all rows and FTS results intact. The encrypted file no longer starts with `SQLite format 3`. A wrong key and a keyless open both fail with SQLite error 26. A plaintext database still opens with no key in the cipher build, so plaintext installs keep working.
- Gotcha: `Database.usePassphrase(Data)` treats the bytes as a passphrase and runs PBKDF2 on every connection. A 256-bit random key should be set as a raw key with `PRAGMA key = "x'<64 hex chars>'"`, which skips key derivation. The app already has the seam for it: `ClipDatabase.prepareConnection` (`Storage/ClipDatabase.swift`) runs on every pool connection.

**Blockers (each needs an owner decision or a capability that is not verifiable here)**
1. **Dependency swap.** GRDB must come from a hosted fork (a git URL under the owner's account) or a vendored copy (about 5 MB of source) used through `.package(path:)`. Every future GRDB upgrade becomes a manual merge. SwiftPM offers no lighter way.
2. **MCP server breaks.** `integrations/clippy-mcp/src/db.ts:57` opens the file with Node's built-in `node:sqlite` (`new DatabaseSync(dbPath)`), which has no cipher support and cannot be given a key. Once the database is encrypted, every MCP tool fails. It also writes. The fix is the DAT-11 design (route MCP reads and writes through the running app over a local socket or XPC), or disabling MCP while encryption is on. Shipping encryption without one of these would silently break a shipped feature.
3. **CLI needs the key.** `ClippyCLI/ClipReader.swift:46` opens the database read-only with no key. It would have to read the Keychain item. A Keychain item is bound to the creating code signature: an ad-hoc build (`make-app.sh` default, `Signature=adhoc`, no team) has a cdhash that changes on every rebuild, so the CLI would prompt or fail after each rebuild. Sharing a key between the app and the nested CLI without prompts needs a `keychain-access-groups` entitlement (Team ID plus provisioning profile) or a legacy trusted-application ACL. Also unresolved: `Info.plist` says `com.jerry.clippy` while `KeychainStore` uses service `com.bytesavvy.clippy.secrets`.
4. **Database-only encryption is not a compliance control.** `media/`, the TOML archive and package export, `scripts.json`, and `ai-actions.json` stay plaintext. macOS has no iOS-style Data Protection classes for ordinary files, so the roadmap's "Data Protection class for media" cannot be met that way. Media would need per-file AES-GCM (CryptoKit) with the same Keychain key, which also affects the CLI and MCP paths that read media by filename. User-facing archive export would need an optional passphrase.

**Design once unblocked**
- Key: 32 bytes from `SecRandomCopyBytes`, stored as a generic-password Keychain item (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable), created only when the user turns on the opt-in setting (default off). Reuse `Support/KeychainStore.swift`.
- Open: `prepareConnection` issues `PRAGMA key` when the setting is on and the file is encrypted. Detect the state by trying a keyless `SELECT count(*) FROM sqlite_master` (error 26 means encrypted) instead of trusting the setting.
- Migration (plaintext to encrypted and back): close the pool, `ATTACH` a temp file in the same directory with `KEY` (or `KEY ''` to decrypt), `SELECT sqlcipher_export(...)`, then verify `PRAGMA integrity_check` and per-table row counts against the source. Only then swap with `FileManager.replaceItemAt`, keep `clippy.sqlite.pre-encrypt` until the next successful launch, and remove the stale `-wal` and `-shm` files. A crash at any step must leave the original openable.
- Tests to write: plaintext to encrypted to plaintext round trip with rows, categories, and FTS results preserved; wrong key and keyless open fail; encrypted header check; a simulated failure mid-export leaves the original untouched; CLI open with and without a key.

**Exact prerequisites**: (a) a decision and a home for the GRDB fork; (b) the DAT-11 app-mediated MCP path, or an explicit "MCP off while encrypted" rule; (c) a Developer ID build with a team and a provisioning profile (or an accepted per-rebuild Keychain prompt) so the CLI can read the key; (d) a decision on media and archive encryption scope.

### DAT-07: archive package with bundled media. Status: implemented in the working tree

The row above describes the pre-fix code. The working tree now has `ClippyArchive.exportPackage` and `importPackage`: a `*.clippyarchive` folder with `clippy.toml` plus `media/`, package-relative `media` paths, file clips exported with `file_path`, absolute and `..` paths rejected on import, and old absolute-path archives still readable. `ICloudSyncService` writes and reads that package. Tests: `DataLayerArchiveTests` (`testPackageRoundTripCarriesImagesAndFileClipsToAnotherDatabase`, `testImportRejectsTraversalAndAbsoluteMediaPaths`, `testImportPackageWithoutManifestThrows`, `testPathReferenceFileClipsImportInsteadOfBeingSkipped`) and `ICloudSyncTests.testForcedSyncWritesArchivePackageWithoutCrashing`. Not yet re-run after these were written: the tree did not compile while the Swift 6 mode migration was in progress, so run the full gate before closing DAT-07.

### PLT-12: CloudKit sync (`CKSyncEngine`). Status: blocked on signing and provisioning

Today's sync is an iCloud Drive file (`docs/icloud-setup.md`), which needs no entitlement. CloudKit does, and the current build pipeline cannot carry one.

**What was checked**
- `Clippy.entitlements` already lists container `iCloud.com.bytesavvy.clippy`, the `CloudKit` service, and a key-value store id. `scripts/make-app.sh` never passes `--entitlements` when signing the app, and nothing embeds an `embedded.provisionprofile`. The built `build/Clippy.app` reports `Signature=adhoc`, `TeamIdentifier=not set`, `Identifier=com.jerry.clippy`. The bundle id does not match the entitlement's `com.bytesavvy.clippy` naming.
- `CODESIGN_IDENTITY` (Developer ID, hardened runtime) is the CI path. This Mac has one valid identity (`Developer ID Application: Jerry Morgan (V7F55EQ974)`), but a Developer ID signature alone does not authorize iCloud. Apple treats the iCloud container entitlements as restricted: they must be backed by a provisioning profile embedded in the bundle (not exercised here, since no profile exists to test with). `docs/icloud-setup.md` records that calling CloudKit without the entitlement crashes the app.

**Exact prerequisites (none are reachable from this repo or verifiable without an Apple account)**
1. An App ID for the final bundle id with the iCloud (CloudKit) capability, and the CloudKit container created in the developer portal.
2. A Developer ID provisioning profile for that App ID, embedded as `Contents/embedded.provisionprofile`.
3. `make-app.sh` signing the app with `--entitlements`, including `com.apple.application-identifier` and `com.apple.developer.team-identifier` from the profile, keeping the inside-out signing order (Sparkle parts, the bundled CLI, then the app).
4. A decision on the bundle id (`com.jerry.clippy` versus the `com.bytesavvy.clippy` names in the entitlements, the Keychain service, and the container).
5. The CloudKit schema deployed to Production before release, and a signed-in iCloud account on a test Mac to exercise `CKSyncEngine`.

**Engine-agnostic groundwork: deliberately not built.** DAT-07 only asks for portable archives, which are done. Change tracking and tombstones (deletion-aware sync, DAT-15) need a stable cross-device clip identity that does not exist yet: clips use local autoincrement ids plus a content dedupe key. Designing that layer without the `CKSyncEngine` record and zone model to check it against would produce code with no consumer and no way to prove it correct, so it stays in this backlog item.

## 11. Settings and theming (SET)

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| SET-01 | S2 | Contrast failures: dim grey titles on dark in AI Actions, low-contrast assistant text, and script text near-black on dark grey when the window is inactive. | L `51`, `52`, `35-scripts-0.png` | Use semantic colors (`.primary`, `.secondary`, `.tint`) and check WCAG AA against every preset. |
| SET-02 | S3 | Appearance color rows wrap the hex value ("#8F909 / 1"), show the hex value twice, and show an empty black swatch. The color wheel writes settings on every drag tick. | L `32-appearance-0.png`, `32-appearance-0.5.png`; C `UI/SettingsView.swift:766-768` | Use a `ColorPicker` row with a single monospaced hex field, and commit on drag end. |
| SET-03 | S3 | The MCP port shows as "6,015" with a thousands separator and a duplicated label. It reads "Port 6,015 is available" while the server is running on that port. The three "Install for..." rows spin indefinitely. | L `36-integrations-1.png`, `37-integrations-after5s.png` | Use `.number.grouping(.never)`, a single label, a status derived from the running server, and timeouts on install probes. |
| SET-04 | S3 | iCloud reads "iCloud Drive is off on this Mac" while its toggle is on and "Sync now" is disabled. | L `36-integrations-0.5.png` | Disable the toggle with an explanation, or link to System Settings. |
| SET-05 | S3 | The "Confirm before typing more than 600 characters" stepper shows no value. The Shift+Return description sits under the wrong toggle. Log level defaults to Debug. "Store file contents up to: 391 MB" is an odd stepper value. Ignored Apps is a free-text area. | L `30`, `31`, `33-capture-1.png` | Fix the layout, use Info as the default log level, use preset size steps, and add an app picker (`NSOpenPanel` on /Applications plus running apps). |
| SET-06 | S3 | `ValidatedTextField` commits only on submit, never on focus loss. The draft API key is cleared even when the Keychain write fails. Launch at login shows Off when the status is `.requiresApproval`. | C `UI/SettingsView.swift:293-294, 346, 495, 521, 1270-1271` | Commit on focus loss, clear the key only after success, and show a "Needs approval" state with a button that opens System Settings. |
| SET-07 | S3 | A stray empty row sits between "Ready" and "Test AI connection". The AI Actions list is a nested scroller inside the page scroller. | L `34-ai-0.png`, `34-ai-0.5.png` | Rework the layout per SET-09. |
| SET-08 | S4 | Cached theme tokens do not update on a system light/dark flip. `customIsDark` has no UI. The amber accent overrides preset accents by default. | C `Support/ThemePreset.swift:205, 209-211, 290`, `Support/AppSettings.swift:564-584` | Invalidate the cache on `effectiveAppearance` change, and expose or remove `customIsDark`. |
| SET-09 | S3 | Settings is one 1748-line view with no search, no per-section reset, no backup or restore of preferences, and no window frame persistence. | Missing-capability sweep | Use a macOS 26 `Settings` scene with a sidebar, `.searchable`, per-pane files, and export/import of preferences. |
| SET-10 | S4 | The runtime log shows about 146 "Publishing changes from within view updates is not allowed" warnings on the Integrations tab, plus repeated CoreSpotlight donation errors (`CSIndexErrorDomain -1000`). | L walkthrough log capture | Move state mutations out of `body` and `onAppear` into tasks. Fix or gate the Spotlight donations. |

## 12. Integrations: MCP and 1Password (MCP, OPW)

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| MCP-01 | S2 | `stop()` can run before the async publish of `process`, which orphans the node child. `pollHealth` can then report `.running`. | C `Integrations/McpServerController.swift:240-243, 270, 292-296` | Serialize lifecycle on an actor. Kill by the stored pid on stop. |
| MCP-02 | S1 | An existing client config file that fails to parse is overwritten with only the Clippy entry, which deletes the user's other MCP servers. | C `Integrations/McpInstallService.swift:220-233` | Refuse to write, and show a diff with a backup. |
| MCP-03 | S3 | The tools/list health check does not check status, so a rejection reports success with 0 tools. The Claude Desktop entry uses bare `npx`. Installed configs are not re-synced when the port changes. There is no support for Cursor, Windsurf, or Zed, and no preview of the JSON that will be written. | C `Integrations/McpServerController.swift:402-418`, `Integrations/McpInstallService.swift:82-85` | Check status, use absolute paths, re-sync on port change, and add more clients with a dry-run preview. |
| OPW-01 | S2 | The 1Password view spins indefinitely (more than 12s) with no timeout, error, or sign-in prompt, even though Settings reports "op found". | L `90-1password.png`, `91-1password-10s.png` | Add a state machine (needs sign-in, loading, empty, error) around `Subprocess.run` (20s) with a visible error and an `op signin` action. |
| OPW-02 | S3 | A stale detail task clears `detailLoading` unconditionally, leaving a blank detail panel. The list reloads only on `onAppear`, not on vault change. `isInstalled` is cached for the life of the process. | C `UI/OnePasswordView.swift:32, 245-258`, `Integrations/OnePasswordService.swift:125-126` | Cancel and replace the task, reload on `.onChange(of: vault)`, and re-probe on demand. |
| OPW-03 | S3 | Missing features: multi-account (`--account`), item search, a live TOTP countdown, and a notification when auto-clear wipes the clipboard. | Missing-capability sweep | Phase 3 backlog. |

## 13. Security and compliance (SEC)

Henssler operates under the FTC Safeguards Rule, SEC Reg S-P, and GLBA. Clippy captures
whatever staff copy, which includes client NPI. The items below are controls, not
conveniences.

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| SEC-01 | S2 | On the audited Mac, "Allow AI to run my scripts" and "Allow AI to execute generated code (full environment access)" are both ON, and web search is on too. The code defaults are OFF for scripts and code execution, so this is a stored user choice. Web search defaults ON, and the "off by default" copy does not mention it. For a regulated firm, nothing lets IT enforce these switches. | L `34-ai-1.png`; C `Support/AppSettings.swift:389-401`, `UI/SettingsView.swift:1236` | Honor managed preferences (an MDM configuration profile) that lock these switches. Show a persistent indicator in the Assistant when code execution is enabled. Default web search to OFF, and state it in the copy. |
| SEC-02 | S1 | Secrets render in clear text on cards (for example an `apikey_253c...` clip). Nothing detects or masks them. | L `10-panel-default.png` | Sensitive-content detection at capture (regex for key formats, PEM, card numbers and SSN with Luhn checks, plus an on-device classifier). Mask previews, exclude from MCP and sync, and auto-expire. |
| SEC-03 | S1 | The loopback MCP HTTP endpoint has no token or auth, so any local process can read and write clips. | C `Integrations/McpServerController.swift:196-200`, `integrations/clippy-mcp/src/index.ts:341` | Use a per-install bearer token stored in the Keychain and written into client configs. Prefer stdio transport. |
| SEC-04 | S1 | The 1Password secret value is passed in the `op` argv, where `ps` can read it. | C `Integrations/OnePasswordService.swift:182-185` | Pass it via stdin or a file descriptor. |
| SEC-05 | S2 | The log file is created with default permissions, and every message is `.public`, including clip-derived text. | P `Support/ClippyLog.swift:125-131, 212, 246` | Use 0600, `.private` interpolation for content, and a redaction layer. |
| SEC-06 | S2 | There is no app lock (Touch ID / `LAContext`) for viewing history, and no data-at-rest encryption (DAT-12). | Missing-capability sweep | Add an optional lock on panel open after idle, and for pinned or sensitive clips. |
| SEC-07 | S3 | `execute_code` has no sandbox. The only controls are a per-call confirmation and a 30s timeout. | Carried from the previous roadmap | Run in `sandbox-exec` with a deny-network, read-only profile by default, or in an XPC helper with App Sandbox. |
| SEC-08 | S3 | There is no audit log of AI and MCP actions that is visible to the user or exportable for an examiner. | Missing-capability sweep | Add an append-only local audit log (who, what tool, which clip ids) with an export. |

## 14. Accessibility (A11Y)

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| A11Y-01 | S2 | `.accessibilityElement(children: .ignore)` removes a card's action buttons and rename editor from VoiceOver. The card claims `.isButton` with no `accessibilityAction`. | C `UI/ClipCardView.swift:139-143, 209-221` | Use `children: .combine` with `accessibilityAction(named:)` for Paste, Pin, Delete, and Edit. |
| A11Y-02 | S3 | Category rows are not keyboard-focusable, the crop canvas has no accessibility affordance, and the editor text view has no label. | P `UI/CategorySidePane.swift:365-370`, `UI/ClipEditorView.swift:97-103, 560-562` | Add focusable rows, labels, and an accessibility rotor for clips. |
| A11Y-03 | S3 | There is no support for Reduce Motion, Reduce Transparency, or Increase Contrast, and fonts use fixed sizes. | P `Support/Theme.swift:262, 266`; missing-capability sweep | Read the `accessibilityReduce*` environment values and scale fonts with a user text-size setting. |

## 15. Architecture and code health (ARCH)

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| ARCH-01 | S2 | Six files break the project's own 300-line ceiling by up to about 6x: `ClipListView` 1503, `SettingsView` 1748, `AIAssistantPanelView` 964, `AIAgent` 925, `ClipCardView` 881, `AppSettings` 823. | `wc -l` baseline | Split by feature: sectioning, card, context menu, selection model, keyboard, status banner, and AI proposal. This goes first in Phase 1. |
| ARCH-02 | S3 | The app still runs in the Swift 5 language mode on a Swift 6.4 toolchain. The build produces 2 concurrency warnings (`ScriptRunner.swift:147` non-Sendable capture, `OCRService.swift:40` unnecessary `nonisolated(unsafe)`). | `Package.swift`; build log | Adopt Swift 6 mode per module with default `MainActor` isolation (Swift 6.2 approachable concurrency) and `@concurrent` for background work. **Status: partial.** the `Clippy` target now builds in Swift 6 language mode with 0 errors (`swift build` clean); `ClippyCLICore`, `clippy-cli`, and `ClippyTests` stay on v5. Test classes touching main-actor APIs were annotated `@MainActor`. `swift test`: 1111 tests, 1 skipped (opt-in real-Vision test), 0 failures. Deferred: Swift 6 mode for the other three targets, default `MainActor` isolation, and `@concurrent`. |
| ARCH-03 | S3 | Stores use `ObservableObject`/`@Published` throughout, so broad invalidation drives the per-redraw costs in LAY-12 and OCR-05. | Carried from the previous roadmap | Migrate to `@Observable` + `@MainActor`. Rewire the Combine `$` projections (`ClipboardMonitor.$pollingIntervalMs`, `McpServerController.$mcpEnabled`/`$mcpPort`) before removing `@Published`. **Status:** not started. No store uses `@Observable` yet (the only source match is a regex string in `EditorLanguageSniffer`). |
| ARCH-04 | S3 | MCP still writes SQLite directly, so app invariants do not apply; concurrent writes are serialized but not routed through the app. | Carried from the previous roadmap; DAT-11 | **Status: partial** (interim guardrails only; the app is not yet the single writer). Remaining: make the app the single writer over XPC or a Unix socket. Interim guardrails: MCP preserves app-owned WAL mode, waits up to 5s for locks, uses `BEGIN IMMEDIATE` for each SQLite mutation, rejects missing/incompatible schemas (no migrations from MCP), and relies on the app's external-change watcher; CLI reads read-only and routes `add` through `clippy://add`. |
| ARCH-05 | S4 | Stale build products exist under the old iCloud Drive path ("Stale file ... Mobile Documents ... outside of the allowed root paths", about 770 warnings). | Build log | Run `swift package clean` once, and document it in the README. |
| ARCH-06 | S4 | Test gaps: no UI or snapshot tests for layout (LAY-*), `warmUp`, the OCR banner, or `saveScriptOutput` error paths. The test suite writes to the user's production log. | Test inventory; previous roadmap | Add ViewInspector or snapshot tests at 3 panel widths x 4 column settings, and give the tests their own log. |
| ARCH-07 | S4 | Logging defaults: 27 INFO and 22 WARN lines against 1313 ERROR over three months, so the log cannot answer a capture question. | Carried from the previous roadmap | Define log-level policy and add a diagnostics export. |
| ARCH-08 | S4 | Retire the five deprecated MCP tool aliases (`clippy_search`, `clippy_get`, `clippy_add`, `clippy_delete`, `clippy_set_category`). | Carried from the previous roadmap | Remove them once client configs have migrated. |
| ARCH-09 | S4 | Pre-existing lint findings: `identifier_name` on `let s = AppSettings.shared` (5 places in `AppDelegate.swift`) and on loop variables in `ClipListView.swift`. `file_length` on `ClipListView` is covered by ARCH-01. | pi-lens output, verified present at HEAD `9fa1906` | Rename the locals during the ARCH-01 split so the rename is not a separate churn commit. |

---

## 16. Feature backlog: what a power user expects (FEAT)

Ranked by user value, cross-checked against competitors (P = Paste, R = Raycast, M =
Maccy, A = Alfred, PB = Pastebot, PP = PastePal, CC = CleanClip). "Have" marks what
Clippy already covers.

| ID | Feature | Seen in | Notes |
|---|---|---|---|
| FEAT-01 | Concealed and transient type skip plus content-based secret detection | R, M, A | Honor `org.nspasteboard.ConcealedType`, `TransientType`, and `AutoGeneratedType`, plus legacy ids. Pairs with SEC-02. |
| FEAT-02 | Ignore rules per app and per data type, with an app picker | P, A, PB, R | Replaces the free-text list (SET-05). |
| FEAT-03 | Keyboard-first command palette: type to filter, Return pastes, Cmd+1..9 quick paste, Cmd+K actions menu | all | Builds on KEY-*. |
| FEAT-04 | Pinboards and collections with smart (rule-based) collections | P, PB, PP, CC | Categories exist. Add rules such as "from Terminal", "kind:url", "older than 30d". |
| FEAT-05 | Filter chips: kind, source app, date range, category | R, PB, PP, CC | Replaces the hidden `#kind` syntax. |
| FEAT-06 | Paste stack and sequential paste (collect N items, paste in order) | PB, CC | Paste Queue with a menu bar badge. |
| FEAT-07 | Text transforms: case, trim, JSON pretty/minify, base64 and URL encode/decode, hashes, sort lines, dedupe lines, regex replace, chainable | PB, PP | Local, no AI. Available from the context menu and the command palette. |
| FEAT-08 | Snippets with text expansion and placeholders (date, clipboard, cursor, fill-in fields) | A, PP, Clipy | Needs an event tap with Accessibility permission, which is already granted. |
| FEAT-09 | Quick Look and a preview pane | PB, R | LAY-11. |
| FEAT-10 | Retention rules: per-kind and per-app TTL, "forget after N days", auto-expire sensitive clips | A, R | Compliance-friendly. |
| FEAT-11 | Shortcuts and App Intents: get clip, search, add, transform, run script | PB, PP | See PLT-05. |
| FEAT-12 | CLI (`clippy get/search/add`) and a `clippy://` URL scheme | PB | Reuse the MCP tool layer. |
| FEAT-13 | Merge or append clips (Cmd+C twice appends) | A | |
| FEAT-14 | Rich previews: color swatches, link previews (`LPMetadataProvider`), syntax-highlighted code, table rendering for CSV | R | |
| FEAT-15 | Semantic search over clips (`NLContextualEmbedding`, mean-pooled, stored in SQLite), hybrid-ranked with FTS | none confirmed | Carried from the previous roadmap. |
| FEAT-16 | AI auto-filing suggestions (93% of clips are uncategorized) | none | On-device only. Carried from the previous roadmap. |
| FEAT-17 | OCR search across image clips | none confirmed (differentiator) | OCR-03. |
| FEAT-18 | Encryption at rest and an app lock | R (encryption) | DAT-12, SEC-06. |
| FEAT-19 | Per-app paste profiles (always plain text into terminals and IDEs) | none confirmed | CAP-08. |
| FEAT-20 | Undo delete, "copy without paste", drag clips out to other apps | common | KEY-11. |
| FEAT-21 | Clipboard auto-clear after N seconds for sensitive clips, with a notification | 1Password-style | OPW-03, SEC-02. |
| FEAT-22 | Share a clip or collection (AirDrop, share sheet, export as file) | P (team pinboards) | |
| FEAT-23 | Multi-display and Stage Manager aware placement with per-display memory | | PNL-06. |
| FEAT-24 | Menu bar quick list of recent clips | M (menu-first design) | PNL-10. |
| FEAT-25 | Translate clip (on-device Translation framework) | | |
| FEAT-26 | Conversation persistence and tool transparency for the assistant | | AI-12. |
| FEAT-27 | MLX on-device provider with model management | | Carried from the previous roadmap. Lower priority now that Foundation Models is pluggable on macOS 27 (PLT-04). |
| FEAT-28 | AI vision: describe or extract from image clips with multimodal models (Foundation Models image input on macOS 27) | | Carried from the previous roadmap. |

## 17. Platform modernization (PLT)

Target: macOS 26 minimum (already set in `Package.swift`), with macOS 27 enhancements
gated by `if #available`. Items marked UNCONFIRMED in the research need an Apple doc
check (via Context7 or developer.apple.com) before implementation.

| ID | Capability | API | Min OS | Use in Clippy |
|---|---|---|---|---|
| PLT-01 | Liquid Glass | `glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`, `NSGlassEffectView` / `NSGlassEffectContainerView` (AppKit) | 26 | Panel background, the header, hover toolbars, and filter chips. Replaces `.hudWindow` blur (LAY-14). Signatures UNCONFIRMED. |
| PLT-02 | SwiftUI and AppKit bridging | `NSHostingSceneRepresentation`, `NSHostingMenu`, `NSGestureRecognizerRepresentable`, automatic `@Observable` tracking in AppKit | 27 (tracking back to 15) | Host the Settings scene and a `MenuBarExtra` from AppDelegate. Status item menu in SwiftUI. |
| PLT-03 | Rich text and web | SwiftUI rich `TextEditor` with `AttributedString`, SwiftUI `WebView` | 26 | Rich-text clip editing and an HTML clip preview (EDT-06). |
| PLT-04 | Foundation Models | `LanguageModelSession`, `@Generable`, `Tool`, snapshot streaming, `contextSize` / `tokenCount(for:)`. On 27: the public `LanguageModel` protocol (Claude, Gemini, MLX plug in), image input, Dynamic Profiles, system OCR tools | 26 / 27 | Real tool calling on the default provider (AI-02). One session API across local and cloud providers replaces the per-provider `AIAgent` classes. Context chunking (AI-12). |
| PLT-05 | App Intents and Spotlight | `AppEntity`, `IndexedEntity`, interactive snippets, Spotlight as an intents client, `IndexedEntityQuery` | 26 / 27 | Clips and snippets searchable in Spotlight. Shortcuts actions (FEAT-11). Fixes the CoreSpotlight donation errors (SET-10). |
| PLT-06 | Vision | `RecognizeDocumentsRequest`, Swift-native `RecognizeTextRequest` | 26 | Structured OCR (OCR-07). |
| PLT-07 | Language | `NLContextualEmbedding` | 14 | Semantic search (FEAT-15). |
| PLT-08 | Translation | `TranslationSession` via `.translationTask` | 15 (UNCONFIRMED) | FEAT-25. |
| PLT-09 | Pasteboard privacy | `NSPasteboard.accessBehavior`, `detectPatterns` | 15.4 preview | Detect before reading, to avoid prompts. Enforcement status on 26 and 27 is UNCONFIRMED (a developer comment says the preview default is inert on 27.2 beta). Watch release notes. |
| PLT-10 | Swift 6.2 to 6.4 | Default `MainActor` isolation, `nonisolated(nonsending)`, `@concurrent`, Swift Testing interop, `withTaskCancellationShield` | toolchain | ARCH-02. Cancellable OCR, AI, and script tasks. |
| PLT-11 | Login items | `SMAppService.mainApp` with the `.requiresApproval` state | 13 | SET-06. |
| PLT-12 | Sync | `CKSyncEngine` (CloudKit) | 14 | Replaces the single TOML archive sync (DAT-04, DAT-05, DAT-07). Blocked on signing and provisioning; see the PLT-12 note in section 10. |

---

## 18. Smart Suggestions (INT)

Shipped unreleased: on-device context-aware ranking (`Intelligence/`), Suggestions pane,
Find Similar Clips, Intelligence settings tab. Open items:

| ID | Sev | Gap | Evidence | Fix direction |
|---|---|---|---|---|
| INT-01 | S3 | The Accessibility context capture (`ContextReader`) and the Suggestions pane were verified by unit tests and a real-embedder ranking run only. No one has driven them in a running app with Accessibility granted, in Mail, Slack, a browser, and an Electron app. | Session verification gap | Launch the built app with a granted build, capture screenshots into `.atlas/evidence/`, and record which hosts expose text (Electron and some web views may not). |
| INT-02 | S3 | Embeddings are recomputed in memory (LRU, about 2000 clips) after each launch, so the first suggestion after launch pays the cost. | C `Intelligence/SuggestionEngine.swift` cache | Persist vectors in an `embeddings` table keyed by clip id + text hash, and invalidate on text edit. |
| INT-03 | S3 | The cosine floor (0.36) and span (0.12) were calibrated on a handful of English samples. The gap between relevant (0.41-0.46) and unrelated (up to 0.35) text is narrow. | Session calibration run | Build a labelled fixture set, measure precision at k, and tune. Re-check when the embedding revision changes. |
| INT-04 | S3 | English embeddings only. Non-English clips and contexts are ranked by keyword, recency, and app signals alone. | C `NLTextEmbedder` | Pick the embedding by detected language (`NLLanguageRecognizer`) where a sentence embedding exists, and show which language was used. |
| INT-05 | S3 | Image and file clips have no text signal, so they rank only by recency, app, and kind. | C `SuggestionEngine.rank` | Feed OCR text (opt-in, see OCR-03) and file names into the embedding. |
| INT-06 | S3 | No re-ranking or explanation with Apple Intelligence. Foundation Models could rewrite a reason or re-rank the top 20, but only if the tool layer allows it (see PLT items). | Design note | Optional second stage behind the on-device gate, off by default. |
| INT-07 | S4 | There is no per-clip feedback ("not relevant") to learn from, and no way to exclude a clip or an app from suggestions besides Ignored Apps. | Design note | Store dismissals and down-weight; add "Never suggest this clip". |
| INT-08 | S4 | A context read costs up to 250ms of Accessibility messaging on a background queue at every panel open. The timing across real apps has not been measured. | C `Intelligence/ContextReader.swift` | Log elapsed time per host and skip hosts that repeatedly time out. |

---

## Appendix A: refuted claims (do not re-report)

The verifiers checked these against the code and found them false as of 2026-09-29.

- **Archive and sync**:
  - B52: TOML over-escapes backslash plus control characters.
  - B53/B69: sync writes an empty sentinel DB (launch aborts first).
  - B59: duplicate image import leaks media (content-hashed filenames).
- **Reordering and categories**:
  - B64: reorder self-drop moves an item to the end (callers guard against it).
  - A112: category delete leaves junction rows (`onDelete: .cascade`).
  - A113: `sortOrder` default misorders new clips.
  - A116: the reorder sentinel is broken.
- **Panel and window**:
  - A82: borderless panels cannot resize (static read; runtime mouse check still owed under PNL-02).
  - A86: the `.statusBar` level is wrong (it is a documented option).
  - A90: the custom hotkey is not re-applied (none is persisted).
  - A96: `hideOnClickAway` should default on (it is a design choice).
  - A111: the sidebar width is not persisted (nothing to persist; see SBR-01).
- **Editors and media**:
  - A28: app icons are uncached (caches exist).
  - A71: updating an image leaks old media (deleted in `updateClipImage`).
  - A73: path-only file clips are treated as images.
  - A99: Cancel loses edits (it prompts when dirty).
  - A101: the settings number field clamps mid-typing.
- **Integrations and subprocesses**:
  - A109: MCP completions are off the main thread.
  - B14: the Accessibility permission is never requested (it is requested at launch).
  - B23: user sounds do not resolve.
  - B30/B33: `Subprocess` and `op` have no timeout (20s default).
  - B39: `.scpt` text bodies fail in osascript (a test run succeeded).
  - B41: MCP scripts land enabled (MCP writes `isEnabled: false`).

## Appendix B: evidence index

- `.atlas/evidence/2026-09-29-audit-baseline-build-test.txt`: build exit 0, 341 tests passing.
- `.atlas/evidence/2026-09-29-ui-audit/*.png`: 72 live screenshots. Screenshots 10-16 cover the panel and sizes, 20-23 search and keyboard, 30-37 Settings, 40-49 cards and columns, 50-53 AI, 54-69 scripts, 71-72 context menus, 80-82 the editor, and 90-91 1Password.
- `.atlas/.run/findings.json`: per-claim verifier verdicts (the `audit-*` and `ollama-claims-*` ids).
- The raw Ollama area reports were kept in the session scratchpad only. Every item above cites code or screenshots directly, so the roadmap does not depend on them.
