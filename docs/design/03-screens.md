# Clippy screens: per-screen redesign (03)

Status: design proposal. Companion to `redesign-brief.md` (tokens, components, section 4 wireframes) and `04-interaction.md`. Gap IDs come from `docs/ROADMAP.md`. Screen names match files in `Sources/Clippy/UI/`.

Research provenance (fetched this session; nothing here comes from Mobbin):
- Paste shortcuts: <https://pasteapp.io/help/keyboard-shortcuts> (Cmd+1..9 quick paste, Shift-Return plain text, Space Quick Look, Tab switches search and results).
- Raycast Clipboard History: <https://manual.raycast.com/clipboard-history> (Cmd+K Action Panel, Cmd+P type filter, configurable Return action, Paste as plain text, Ask Clipboard AI extension).
- Alfred Clipboard: <https://www.alfredapp.com/help/features/clipboard/> (off by default for privacy, ignore-apps list, Concealed data ignored by default, Cmd+S saves a snippet).
- Pastebot 3: <https://tapbots.com/pastebot/> (number-key quick paste of last 10, resizable preview docked to the menu, stacks, Smart Pastebins, cheatsheet, blacklist per data type).
- Linear and Arc command palettes were not fetched; statements about them are `[INFERENCE]`.

## Conventions

Panel content-width breakpoints: **compact ~420** (icon rail, one column, no preview), **default ~720** (sidebar 176, Quick Look floats), **wide ~1100** (sidebar 200, preview or inspector column). Wireframes are drawn at 44, 72 and 98 characters wide. They show layout order and relative proportion, not pixels. Legend: `>` keyboard cursor, `#` masked text, `[ ]` button or chip, `( )` field, `Ret` the Return key, `^K` Cmd+K, `o` category dot.

Each screen lists **Today**, **Redesign** and **Resolves**.

---

## 1. Popup panel (History)

Today: `ClipListView` (1503 lines, ARCH-01) plus `ClipListView+*.swift`. Cards lead with the source app (LAY-07) and overflow at 4 columns (LAY-01..03). No header drag region (PNL-01); resize affordance is unclear (PNL-02). Escape hides in one step (PNL-11).

Redesign: compact 32pt rows by default with a density switch (compact, comfortable, cards). The header is the drag region. Metadata lives in one fixed trailing slot that crossfades to actions on hover or focus, never overlaying. The footer hint bar states what Return will do for the current selection.

Compact ~420 (rail):
```
+------------------------------------------+
| (Search clips...          )  [=] [..]    |
| [All][Text][Link][Img][Code]      >      |
+------+-----------------------------------+
| Hist | > Read from https://code.c..  33m |
| Pin  |   apikey_253c23af810d99c..   45m  |
| Tdy  |   https://microsoft.github..   2h |
| #1   |   [img] 1144x961 PNG        1d    |
| #2   |   ##########  Sensitive      2m   |
|      |                                   |
| 1P   |                                   |
| Scr  |                                   |
| AI   |                                   |
+------+-----------------------------------+
| Ret paste  Shift+Ret plain  Spc look  ^K |
+------------------------------------------+
```

Default ~720:
```
+----------------------------------------------------------------------+
| (Search  # kind  @ app  ! sensitive        ) [rows|cmf|cards] [..]   |
| [All][Text][Links][Images][Files][Code][Colors][Pinned][App v]       |
+----------------+-----------------------------------------------------+
| LIBRARY        | TODAY                                               |
| History  344   | > Read from https://code.claude..  Edge 33m         |
| Pinned     6   |   apikey_253c23af810d99..     Edge 45m              |
| Today     12   |   426233                    Claude 45m              |
| CATEGORIES     |   ########## Sensitive     1Pass  1h                |
| o claude  14   | YESTERDAY                                           |
| o prompts 16   |   [img] 1144x961 PNG      CleanShot 1d              |
| TOOLS          |   https://microsoft.github.io/mcp..  1d             |
| 1Password      |                                                     |
| Scripts   5    |                                                     |
| Assistant      |                                                     |
| + Category     |                                                     |
+----------------+-----------------------------------------------------+
| Ret paste  Shift+Ret plain  Cmd+Ret keep  Spc look  ^E edit  ^K more |
+----------------------------------------------------------------------+
```

Wide ~1100 (preview column):
```
+------------------------------------------------------------------------------------------------+
| (Search  # kind  @ app  ! sensitive                 )  [rows|cmf|cards]  [..]                  |
| [All][Text][Links][Images][Files][Code][Colors][Pinned][Today][App v][Sensitive]               |
+------------------+--------------------------------------------------+--------------------------+
| LIBRARY          | TODAY                                            | PREVIEW                  |
| History  344     | > Read from https://code..  33m                  | Read from https://code.  |
| Pinned     6     |   apikey_253c23af810d99..  45m                   | claude.com/docs/en/      |
| Today     12     |   426233               Claude 45m                | Text, 182 chars, Edge    |
| CATEGORIES       |   ########## Sensitive    1h                     | Copied 33m ago, used 2x  |
| o claude  14     | YESTERDAY                                        | Category: claude         |
| o prompts 16     |   [img] 1144x961 PNG     1d                      | [Paste][Edit][AI v][..]  |
| TOOLS            |   https://microsoft.githu..  1d                  |                          |
| 1Password        |                                                  |                          |
| Scripts   5      |                                                  |                          |
| Assistant        |                                                  |                          |
+------------------+--------------------------------------------------+--------------------------+
| Ret paste  Shift+Ret plain  Cmd+Ret keep open  Spc look  ^E edit  ^K more                      |
+------------------------------------------------------------------------------------------------+
```

Resolves: PNL-01, PNL-02, PNL-03, PNL-04, PNL-07, PNL-11, PNL-12, LAY-01..LAY-10, LAY-14, KEY-01, KEY-09.

---

## 2. Suggestions pane

Today: `SuggestionsPaneView` plus `ClipListView+Suggestions`. Ranking ships on-device but has not been driven in a running app with Accessibility granted (INT-01), gives no reason (INT-06, INT-07), and pays a warm-up cost per launch (INT-02).

Redesign: Suggestions become the first block of History (3 rows compact and default, 5 wide), headed "Suggested for <app>". Each row has a reason chip; the hover menu offers "Not relevant" and "Never suggest this clip". While context loads, three skeleton rows show. Without Accessibility, one banner row offers "Enable context" instead of an empty pane.

Compact:
```
+------------------------------------------+
| SUGGESTED FOR [Xcode]         [hide]     |
| > swift build -c release   Same app      |
|   https://developer.apple..  Today x3    |
|   func rank(_ clips:..      Selection    |
+------------------------------------------+
| RECENT                                   |
|   Read from https://code.c..   33m       |
+------------------------------------------+
```

Default:
```
+----------------------------------------------------------------------+
| SUGGESTED FOR [Xcode]                              [Why?] [hide]     |
| > swift build -c release --arch arm64     [Same app: Xcode]  Ret     |
|   https://developer.apple.com/documentation [Copied 3x today]        |
|   func rank(_ clips: [Clip]) -> [Clip]     [Matches selection]       |
+----------------------------------------------------------------------+
| RECENT                                                               |
|   Read from https://code.claude.com/docs..      Edge   33m           |
+----------------------------------------------------------------------+
```

Wide:
```
+------------------------------------------------------------------------------------------------+
| SUGGESTED FOR [Xcode]                                      [Why?]  [hide]                      |
| > swift build -c release --arch arm64             [Same app: Xcode]     Ret                    |
|   https://developer.apple.com/documentation/swiftui  [Copied 3x today]                         |
|   func rank(_ clips: [Clip]) -> [Clip]               [Matches selection]                       |
|   hover: [Paste] [Not relevant] [Never suggest this clip]                                      |
+------------------------------------------------------------------------------------------------+
| RECENT                                                                                         |
|   Read from https://code.claude.com/docs/en/overview      Edge   33m                           |
+------------------------------------------------------------------------------------------------+
```

Resolves: INT-01 (per-host state line makes the live check observable), INT-02 (skeleton hides warm-up), INT-06 (reason chip), INT-07 (dismiss actions), INT-08 (a host that times out shows "Context unavailable in this app"), KEY-09.

---

## 3. Sidebar (expanded and icon rail)

Today: `CategorySidePane`. Plain `Divider()` with width `max(150, 25%)` (SBR-01), no collapse (SBR-02), History count includes hidden pinned clips (SBR-03), tap-only rows (SBR-06).

Redesign: three groups (Library, Categories, Tools). A 6pt grabber (150-260pt, double-click resets, persisted). Under 520pt or on Cmd+Ctrl+S it becomes a 44pt rail. Rows are focusable, rename on Return. Drop indicators differ: accent inset ring for "file into", 2pt line for "reorder".

Expanded (176pt column) and icon rail (44pt), shown side by side:
```
+--------------------+   +------+
| LIBRARY            |   |  H   |
| > History      344 |   |  P   |
|   Pinned         6 |   |  T   |
|   Today         12 |   | ---- |
| CATEGORIES         |   |  o   |
|   o claude      14 |   |  o   |
|   o prompts     16 |   |  o   |
|   o scripts     10 |   | ---- |
| TOOLS              |   |  1P  |
|   1Password        |   |  Sc  |
|   Scripts        5 |   |  AI  |
|   Assistant        |   |  As  |
|   AI Actions       |   |  +   |
| + New Category     |   +      |
+--------------------+   +------+
```
Compact ~420:
```
+------------------------------------------+
| PANEL 420                                |
| +------+   History list                  |
| |  H   |   > selected clip               |
| |  P   |   other clips...                |
| |  T   |                                 |
| |  o   |                                 |
| |  Sc  |                                 |
| +------+                                 |
+------------------------------------------+
```

Default ~720:
```
+----------------------------------------------------------------------+
| SIDEBAR 176        | HISTORY LIST                                    |
| > History      | > selected clip                                     |
|   Pinned       |   other clips...                                    |
|   Categories   |                                                     |
|   Tools        |                                                     |
+----------------+-----------------------------------------------------+
```

Wide ~1100:
```
+------------------------------------------------------------------------------------------------+
| SIDEBAR 200      | HISTORY LIST                                     |                          |
| > History        | > selected clip                                  |                          |
|   Pinned         |   other clips...                                 |                          |
|   Categories     |                                                  |                          |
|   Tools          |                                                  |                          |
+------------------+--------------------------------------------------+--------------------------+
```

Per width: compact starts as the rail; default starts expanded at 176; wide starts expanded at 200. A user width always wins, clamped to (panel width - one card minimum - gutters).

Resolves: SBR-01, SBR-02, SBR-03, SBR-04, SBR-05, SBR-06, PNL-03.

---

## 4. Command palette / quick paste (Cmd+K)

Today: none. Actions live in `ClipListView+ContextMenu` and hover buttons; "Show in Timeline" is offered inside the timeline (KEY-10).

Redesign: Cmd+K opens a centered glass palette that acts on the selection, or on the app when nothing is selected (Raycast Action Panel model, <https://manual.raycast.com/clipboard-history>). Sections: Actions, Navigate, Settings, Recent queries. Fuzzy match, right-aligned keycaps, Return runs, Esc closes one step. Prefixes `>` commands, `@` apps, `#` kinds share the search grammar. [INFERENCE] Linear and Arc use scoped-prefix palettes too; not verified.

Compact:
```
+------------------------------------------+
| (> paste..                    ) [esc]    |
+------------------------------------------+
| ACTIONS on "Read from https://c.."       |
| > Paste                               Ret|
|   Plain text                    Shift+Ret|
|   Paste, keep open                Cmd+Ret|
|   Copy                              Cmd+C|
|   Pin                               Cmd+P|
|   Run script...                         >|
|   AI action...                          >|
+------------------------------------------+
| Ret run   Esc close                      |
+------------------------------------------+
```

Default:
```
+----------------------------------------------------------------------+
| (> paste..                                            )  [esc]       |
+----------------------------------------------------------------------+
| ACTIONS on "Read from https://code.claude.com/docs.."                |
| > Paste                                                           Ret|
|   Paste as plain text                                       Shift+Ret|
|   Paste and keep open                                         Cmd+Ret|
|   Copy without pasting                                          Cmd+C|
|   Pin / Unpin                                                   Cmd+P|
|   Edit clip                                                     Cmd+E|
|   Run script...                                                    > |
|   AI action...                                                     > |
+----------------------------------------------------------------------+
| NAVIGATE  Pinned   Categories >   Scripts   Assistant   Settings...  |
+----------------------------------------------------------------------+
| Ret run     Tab next section     Esc close                           |
+----------------------------------------------------------------------+
```

Wide:
```
+------------------------------------------------------------------------------------------------+
| (> paste..                                                                      )  [esc]       |
+------------------------------------------------------------------------------------------------+
| ACTIONS on "Read from https://code.claude.com/docs.."                                          |
| > Paste                                                                                     Ret|
|   Paste as plain text                                                                 Shift+Ret|
|   Paste and keep open                                                                   Cmd+Ret|
|   Copy without pasting                                                                    Cmd+C|
|   Pin / Unpin                                                                             Cmd+P|
|   Edit clip                                                                               Cmd+E|
|   Run script...  [dedup.py] [to-json.py] ...                                                   |
|   AI action...   [Summarize] [Fix grammar] ...                                                 |
+------------------------------------------------------------------------------------------------+
| NAVIGATE  Pinned   Categories >   Scripts   Assistant   Settings...                            |
+------------------------------------------------------------------------------------------------+
| Ret run     Tab next section     Esc close                                                     |
+------------------------------------------------------------------------------------------------+
```

Resolves: KEY-08 (shared query grammar), KEY-10 (only valid actions listed), KEY-11 (copy without pasting), PNL-09 (each action shows its bound key or offers "Assign shortcut").

---

## 5. Quick Look and preview column

Today: none (LAY-11). The full content is visible only in the editor.

Redesign: Space toggles Quick Look. Default and compact show a floating panel over the list; wide shows the docked preview column (Pastebot docks its preview to the quick paste menu, <https://tapbots.com/pastebot/>). Arrow keys change the previewed clip without closing. Masked clips show a placeholder until revealed. Cmd+Ctrl+P hides the column.

Compact ~420:
```
+------------------------------------------+
| Quick Look  Read from https://code..  [x]|
+------------------------------------------+
| Read from https://code.claude.com/docs/  |
| en/overview and check the install steps. |
|                                          |
| Text, 182 chars   Edge   33m ago         |
| Category: claude   Used 2x               |
+------------------------------------------+
| [Paste] [Edit] [Copy] [Share]   Up/Down  |
+------------------------------------------+
```

Default ~720:
```
+----------------------------------------------------------------------+
| Quick Look   Read from https://code.claude.com/docs.. [x]            |
+----------------------------------------------------------------------+
| Read from https://code.claude.com/docs/en/overview and check the     |
| install steps for the CLI before running the setup script.           |
|                                                                      |
| Text, 182 chars    Edge    copied 33m ago    Category: claude        |
| Find: Cmd+F        Arrow keys change the previewed clip              |
+----------------------------------------------------------------------+
| [Paste] [Paste plain] [Edit] [Copy] [Share]        Space/Esc close   |
+----------------------------------------------------------------------+
```

Wide ~1100:
```
+------------------------------------------------------------------------------------------------+
| (Search clips ...                          )   [rows|cmf|cards]                                |
| [All][Text][Links][Images][Files][Code][Colors][Pinned][App v]                                 |
+------------------+----------------------------------------------+------------------------------+
| > History        | > Read from https://code..  33m              | Read from https://code.      |
|   Pinned         |   apikey_253c23af810d99..  45m               | claude.com/docs/en/overview  |
|   Today          |   426233               Claude 45m            | and check the install        |
|   o claude       |   [img] 1144x961 PNG  CleanShot 1d           | steps.                       |
|   o prompts      |   https://microsoft.github.io..  1d          |                              |
|   1Password      |                                              | Text, 182 chars, Edge        |
|                  |                                              | Copied 33m ago, used 2x      |
|                  |                                              | Category: claude             |
|                  |                                              |                              |
|                  |                                              | [Paste][Edit][AI v][..]      |
+------------------+----------------------------------------------+------------------------------+
| Preview column follows the cursor. Cmd+Ctrl+P hides it. Space = full Quick Look.               |
+------------------------------------------------------------------------------------------------+
```

Resolves: LAY-11, LAY-10 (aspect-fit, checkerboard), KEY-03.

---

## 6. Clip editor

Today: `ClipEditorView`, `ClipEditor/*`. Dirty editors are lost on quit (EDT-01), a `let` snapshot can overwrite newer content (EDT-02), external sync is one-way and hard-coded to Sublime Text (EDT-03, EDT-05), no line numbers or wrap (EDT-06), window title never updates (EDT-10).

Redesign: shared text editor component with the script editor (line numbers, wrap, zoom, find). Title from the clip. Conflict banner (Reload, Keep mine, Compare) if the clip changed underneath. External app picker. Wide adds an inspector column. AI actions always stage a result first.

Compact ~420:
```
+------------------------------------------+
| [<] Read from https://code..  * unsaved  |
| [Save Cmd+S] [Revert] [AI v] [..]        |
+------------------------------------------+
| 1  Read from https://code.claude.com     |
| 2  /docs/en/overview and check the       |
| 3  install steps.                        |
|                                          |
|                                          |
|                                          |
+------------------------------------------+
| Ln 3, Col 15   182 chars   UTF-8   [Wrap]|
+------------------------------------------+
```

Default ~720:
```
+----------------------------------------------------------------------+
| Title: (Read from https://code.claude.com/..) * unsaved [Save]       |
| [Revert] [Find Cmd+F] [Wrap] [Aa+] [AI v] [Open in external app v]   |
+----------------------------------------------------------------------+
| 1  Read from https://code.claude.com/docs/en/overview and check the  |
| 2  install steps for the CLI before running the setup script.        |
| 3                                                                    |
|                                                                      |
|                                                                      |
|                                                                      |
|                                                                      |
|                                                                      |
+----------------------------------------------------------------------+
| Ln 2, Col 12    182 chars    UTF-8    Text    Source: Edge, 33m ago  |
+----------------------------------------------------------------------+
```

Wide ~1100:
```
+------------------------------------------------------------------------------------------------+
| Title: (Read from https://code.claude.com/docs.. )    * unsaved      [Save Cmd+S]              |
| [Revert] [Find Cmd+F] [Wrap] [Aa+] [AI v] [Open in external app v]  [Inspector]                |
+----------------------------------------------------------------------------+-------------------+
| 1  Read from https://code.claude.com/docs/en/overview and check            | INSPECTOR         |
| 2  the install steps for the CLI before running the setup                  | Kind      Text    |
| 3  script.                                                                 | Source    Edge    |
|                                                                            | Category  claude v|
|                                                                            | Copied    33m ago |
|                                                                            | Used      2x      |
|                                                                            | OCR       n/a     |
|                                                                            | Conflict  none    |
+----------------------------------------------------------------------------+-------------------+
| Ln 2, Col 12    182 chars    UTF-8    Text                                                     |
+------------------------------------------------------------------------------------------------+
```

Resolves: EDT-01, EDT-02, EDT-03, EDT-04, EDT-05, EDT-06, EDT-07, EDT-09, EDT-10.

---

## 7. Image editor

Today: `ImageClipEditor`, `ImageEditing`. The crop reuses the first drag start and stores view coordinates (EDT-08), with no undo for transforms. Extract Text overwrites the clipboard without displaying its result (OCR-01) and has no cancellation / whitespace-only guard (OCR-04). The owner reports no visible progress; the roadmap's spinner scrim is logic-tested but not verified in a running app (OCR-11).

Redesign: image-space crop selection, `UndoManager` for every transform, aspect-fit with checkerboard, and an inspector with size, format and OCR text at wide. OCR is an explicit action: its first activation immediately shows `Extracting text…` with activity feedback and disables duplicate activation while in flight. Success reveals the recognized text with Copy, Save as clip and Paste actions; it never overwrites the clipboard implicitly. Empty recognition and failure have distinct messages; cancellation leaves the image unchanged, and failure keeps an explicit Retry action.

Compact ~420:
```
+------------------------------------------+
| [<] Screenshot 1144x961         * unsaved|
| [Crop][Rotate][Flip][Resize][Undo][Redo] |
| [Text OCR]                               |
+------------------------------------------+
| +---------------------------------+      |
| |                                 |      |
| |   [image, fit to view]   [::]   |      |
| |                                 |      |
| +---------------------------------+      |
+------------------------------------------+
| 1,144x961 PNG 212 KB [Fit][100%] [Save]  |
+------------------------------------------+
```

Default ~720:
```
+----------------------------------------------------------------------+
| Screenshot 2026-09-29        * unsaved    [Undo][Redo]    [Save]     |
| [Crop][Rotate L][Rotate R][Flip][Resize][Text (OCR)][Copy text]      |
+----------------------------------------------------------------------+
| +--------------------------------------------------------------+     |
| |                                                              |     |
| |         [image, aspect-fit, checkerboard if alpha]           |     |
| |              crop handles in image-space [::]                |     |
| |                                                              |     |
| +--------------------------------------------------------------+     |
+----------------------------------------------------------------------+
| 1,144x961 PNG 212 KB Sel 400x300 at 120,80 [Fit][100%] [-][+]        |
+----------------------------------------------------------------------+
```

Wide ~1100:
```
+------------------------------------------------------------------------------------------------+
| Screenshot 2026-09-29     * unsaved       [Undo][Redo]      [Save Cmd+S]                       |
| [Crop][Rotate L][Rotate R][Flip][Resize][Text (OCR)][Copy text]     [Inspector]                |
+------------------------------------------------------------------------+-----------------------+
| +--------------------------------------------------------+             | INSPECTOR             |
| |                                                        |             | Size      1,144x961   |
| |       [image, aspect-fit, checkerboard if alpha]       |             | Format    PNG 212 KB  |
| |           crop handles in image-space [::]             |             | Selection 400x300     |
| |                                                        |             | OCR text  [Show v]    |
| +--------------------------------------------------------+             | Category  screenshots |
+------------------------------------------------------------------------+-----------------------+
| Ln --    [Fit] [100%] [-][+]    Undo stack: 3                                                  |
+------------------------------------------------------------------------------------------------+
```

Resolves: EDT-08, LAY-10, OCR-01 (show result, explicit copy/paste), OCR-04 (empty/cancel states). OCR-11 still needs live-app verification; this design is not proof of the running view.

---

## 8. Settings (sidebar + search)

Today: `SettingsView` (1748 lines) with `Settings/*Tab`. One scroll, no search, no reset (SET-09), low contrast (SET-01), wrapped hex values (SET-02), odd steppers (SET-05).

Redesign: sidebar of panes with a search field that jumps to the matching row. At compact, panes are a list that pushes. Per-pane reset, export and import. Rows follow the 44pt `SettingsRow` pattern. Integrations show an accurate MCP running/port state with bounded install probes (SET-03), and explain unavailable iCloud state (SET-04). Credential fields commit on focus loss and report Keychain failure without clearing the draft (SET-06); appearance updates on system theme changes (SET-08). AI Actions use a single list scroller (SET-07).

Compact ~420:
```
+------------------------------------------+
| Settings   (Search settings...      )    |
+------------------------------------------+
| > General          >                     |
|   Capture          >                     |
|   Appearance       >                     |
|   Intelligence     >                     |
|   AI               >                     |
|   Integrations     >                     |
|   Scripts          >                     |
|   About            >                     |
+------------------------------------------+
| Tap a pane; Cmd+[ goes back              |
+------------------------------------------+
```

Default ~720:
```
+----------------------------------------------------------------------+
| Settings                          (Search settings...         )      |
+------------------+---------------------------------------------------+
| > General        | GENERAL                                           |
|   Capture        | Launch at login       [ on ]                      |
|   Appearance     | Global hotkey  [Cmd+Shift+V] [Rec]                |
|   Intelligence   | Panel position  [Near caret v]                    |
|   AI             | Return pastes     [Formatted v]                   |
|   Integrations   | Max clip size     [10 MB v]                       |
|   Scripts        | Log level         [Info v]                        |
|   About          | [Reset this pane] [Export..]                      |
+------------------+---------------------------------------------------+
| Cmd+, opens. Search results jump to the row and flash it.            |
+----------------------------------------------------------------------+
```

Wide ~1100:
```
+------------------------------------------------------------------------------------------------+
| Settings                                      (Search settings...                  )           |
+--------------------+---------------------------------------------------------------------------+
| > General          | GENERAL                                                                   |
|   Capture          | Launch at login       [ on ]                                              |
|   Appearance       | Global hotkey  [Cmd+Shift+V] [Rec]   Shows in: General > Hotkey           |
|   Intelligence     | Panel position  [Near caret v]                                            |
|   AI               | Return pastes     [Formatted v]                                           |
|   Integrations     | Max clip size     [10 MB v]                                               |
|   Scripts          | Log level         [Info v]                                                |
|   About            | [Reset this pane] [Export..]                                              |
+--------------------+---------------------------------------------------------------------------+
| Cmd+, opens. Search results jump to the row and flash it.                                      |
+------------------------------------------------------------------------------------------------+
```

Resolves: SET-01, SET-02, SET-03, SET-04, SET-05, SET-06, SET-07, SET-08, SET-09, PNL-09 (hotkey recorder). SET-10 is a runtime warning, not addressed by this screen concept.

---

## 9. AI Assistant

Today: `AI/AIAssistantPanelView`. Clearing while streaming crashes (AI-01), tools are offered when the provider ignores them (AI-02), the newest clip auto-attaches (AI-03), low contrast (AI-13), no tool transparency or token accounting (AI-12).

Redesign: context is an explicit chip. Tool list and per-turn activity show in a drawer (wide: side column). Providers without tool support hide tool suggestions and show a banner. Write tools ask before running, showing full arguments. Structured transcript, persisted.

Compact ~420:
```
+------------------------------------------+
| Assistant  [Apple Intelligence v]  [+]   |
| Tools: search, create (asks first)  [i]  |
+------------------------------------------+
| You: find the link I copied yesterday    |
|                                          |
| Assistant: Found 2 clips.                |
|   > search_clips ran  [details v]        |
|   [Paste #1] [Paste #2]                  |
|                                          |
|                                          |
+------------------------------------------+
| (Ask about your clips...        ) [Send] |
+------------------------------------------+
```

Default ~720:
```
+----------------------------------------------------------------------+
| Assistant  [Apple Intelligence v]   Context: [+ Add clip]  [New chat]|
| Tools: search_clips, create_clip (ask first)      Tokens 412/4096    |
+----------------------------------------------------------------------+
| You: find the link I copied yesterday                                |
|                                                                      |
| Assistant: I found 2 clips from yesterday.                           |
|   > search_clips("link", yesterday)  ran in 41 ms   [details v]      |
|   [Paste #1] [Paste #2] [Open in History]                            |
|                                                                      |
|                                                                      |
+----------------------------------------------------------------------+
| (Ask about your clips... ) [Send] Esc stop                           |
+----------------------------------------------------------------------+
```

Wide ~1100:
```
+------------------------------------------------------------------------------------------------+
| Assistant  [Apple Intelligence v]     Context: [+ Add clip]     [New chat]                     |
+------------------------------------------------------------------------+-----------------------+
| You: find the link I copied yesterday                                  | TOOL ACTIVITY         |
|                                                                        | search_clips  41 ms   |
| Assistant: Found 2 clips.                                              | args: link, yesterday |
|   [Paste #1] [Paste #2] [Open in History]                              | result: 2 clips       |
|                                                                        | create_clip  waiting  |
|                                                                        |   [Allow once] [Deny] |
|                                                                        | Tokens 412 / 4096     |
+------------------------------------------------------------------------+-----------------------+
| (Ask about your clips...                          ) [Send]   Esc stops                         |
+------------------------------------------------------------------------------------------------+
```

Resolves: AI-01, AI-02, AI-03, AI-05, AI-07, AI-08, AI-12, AI-13, KEY-09.

---

## 10. AI Actions editor

Today: `AI/AIActionsManagerView`. Nested scrollers, prompt below the fold (AI-14), reorders on edit (AI-09), diff shown for every action (AI-10), dim rows (AI-13).

Redesign: list plus form, with a live test against the selected clip at wide. Result mode picker (replace, new clip, copy). Diff only for in-place rewrites, word-level.

Compact ~420:
```
+------------------------------------------+
| AI Actions   [+ New]   (Filter...)       |
+------------------------------------------+
| > Summarize           in place  [Edit]   |
|   Fix grammar         in place           |
|   Extract links       new clip           |
|   Translate to Spanish  copy             |
|                                          |
| Tap an action to edit it                 |
+------------------------------------------+
| Editing opens a full screen              |
+------------------------------------------+
```

Default ~720:
```
+----------------------------------------------------------------------+
| AI Actions   [+ New]   [Import] [Export]                             |
+--------------------------+-------------------------------------------+
| > Summarize              | Name      (Summarize             )        |
|   Fix grammar            | Icon      [text.badge.star]               |
|   Extract links          | Prompt     {{clip}} in template           |
|   Translate              |   Summarize in 2 sentences:               |
|                          |   {{clip}}                                |
|                          | Result    [Replace clip v]                |
|                          | Provider  [Default v]                     |
|                          | [Test on selected clip] [Save]            |
+--------------------------+-------------------------------------------+
| Unsaved changes are kept as a draft. Cmd+S saves.                    |
+----------------------------------------------------------------------+
```

Wide ~1100:
```
+------------------------------------------------------------------------------------------------+
| AI Actions   [+ New]   [Import] [Export]                    (Filter...)                        |
+--------------------------+--------------------------------------------+------------------------+
| > Summarize              | Name (Summarize)                           | TEST: [Selected]       |
|   Fix grammar            | Icon [text.badge.star]                     | Input: selected clip   |
|   Extract links          | Prompt {{clip}}                            | Output (streaming)     |
|   Translate              | Summarize in 2 sentences                   | Claude Code setup      |
|                          | {{clip}}                                   | and install steps      |
|                          | Result [Replace v]                         | Diff: word-level       |
|                          | Provider [Default v]                       | [Run test]             |
+--------------------------+--------------------------------------------+------------------------+
| Unsaved changes are kept as a draft. Cmd+S saves.                                              |
+------------------------------------------------------------------------------------------------+
```

Resolves: AI-09, AI-10, AI-13, AI-14.

---

## 11. Scripts (list, editor, output drawer)

Today: `ScriptsView`, `ScriptsPanelView`, `PlainTextEditor`. Plain editor without highlighting or Cmd+S (SCR-01), three nested scrollers (SCR-02), interpreters not found (SCR-03), undo garbage after switching (SCR-04), ambiguous status (SCR-06), draft row stays (SCR-09), no confirm on destructive run (SCR-10).

Redesign: split view, list left, editor filling the height, output drawer at the bottom that can be resized. Distinct states Success, Failed, Cancelled, Timed out. Per-script confirm flag, timeout and interpreter path with a preflight check. Compact shows a list that pushes into the editor.

Compact ~420:
```
+------------------------------------------+
| Scripts   (Filter...)   [+ New]          |
+------------------------------------------+
| > dedup.py       python   [Run]          |
|   to-json.js      node   [Run]           |
|   trim.sh          sh    [Run]           |
|                                          |
| Tap to open the editor; Run confirms     |
| when marked destructive.                 |
+------------------------------------------+
| OUTPUT  last run: Success 0.3 s   [v]    |
+------------------------------------------+
```

Default ~720:
```
+----------------------------------------------------------------------+
| Scripts   (Filter...)  [+ New] [Import] [Run] [Stop] [Save Cmd+S]    |
+----------------------+-----------------------------------------------+
| > dedup.py py        | Name (dedup.py) Interp [python3 v]            |
|   to-json js         | Confirm [x] Timeout [30s]                     |
|   trim sh            | 1 import sys                                  |
|                      | 2 data = sys.stdin.read()                     |
|                      | 3 print(dict.fromkeys(data.splitlines()))     |
|                      | 4                                             |
|                      |                                               |
+----------------------+-----------------------------------------------+
| OUTPUT Success [Copy] [Save as clip] [Clear] [resize]                |
|   3 lines out, exit 0                                                |
+----------------------------------------------------------------------+
```

Wide ~1100:
```
+------------------------------------------------------------------------------------------------+
| Scripts   (Filter...)   [+ New]   [Import]     [Run Cmd+Ret] [Stop] [Save Cmd+S]               |
+------------------------+-----------------------------------------------------------------------+
| > dedup.py    python   | Name (dedup.py)  Interp [python3 v]  Path /opt/homebrew/bin           |
|   to-json.js     node  | Confirm before run [x]  Timeout [30s]  Args (           )             |
|   trim.sh          sh  | 1  import sys                                                         |
|                        | 2  data = sys.stdin.read()                                            |
|                        | 3  print("\n".join(dict.fromkeys(data.splitlines())))                 |
|                        | 4                                                                     |
+------------------------+-----------------------------------------------------------------------+
| OUTPUT  Success 0.3 s  exit 0      [Copy] [Save as clip] [Clear]   [History v]                 |
|   3 lines out                                     [drag handle to resize]                      |
+------------------------------------------------------------------------------------------------+
```

Resolves: SCR-01, SCR-02, SCR-03, SCR-04, SCR-05, SCR-06, SCR-08, SCR-09, SCR-10, SCR-12 (arguments, history), EDT-06 (shared editor).

---

## 12. 1Password view

Today: `OnePasswordView`. Spins indefinitely with no error (OPW-01), stale detail tasks (OPW-02), no account or TOTP countdown (OPW-03).

Redesign: an explicit state machine (needs sign-in, loading, empty, error, ready) with a 20s timeout and an `op signin` action. Account and vault pickers, local item search, TOTP countdown, clipboard auto-clear notice. Items never enter History.

Compact ~420:
```
+------------------------------------------+
| 1Password  [Vault: Private v]  [..]      |
+------------------------------------------+
| State: Needs sign-in                     |
|                                          |
| 1Password CLI (op) is installed but      |
| you are not signed in.                   |
|                                          |
| [Sign in]   [Open 1Password]             |
| Times out after 20 s with details        |
+------------------------------------------+
| Esc back to History                      |
+------------------------------------------+
```

Default ~720:
```
+----------------------------------------------------------------------+
| 1Password  [Account: work v] [Vault: Private v]  (Search items...)   |
+------------------------------+---------------------------------------+
| > GitHub  jerry@             | GitHub                                |
|   AWS root                   | username   jerry@                     |
|   Plaid sandbox              | password   ##########  [Reveal]       |
|                              | one-time  123 456  (18 s)  [Copy]     |
|                              | [Paste password] [Paste code]         |
|                              | Auto-clear clipboard in 30 s          |
+------------------------------+---------------------------------------+
| State: Ready. Loaded 3 items in 0.8 s. Items never enter History.    |
+----------------------------------------------------------------------+
```

Wide ~1100:
```
+------------------------------------------------------------------------------------------------+
| 1Password  [Account: work v]  [Vault: Private v]        (Search items...)                      |
+----------------------------------+-------------------------------------------------------------+
| > GitHub  jerry@                 | GitHub                                                      |
|   AWS root                       | username    jerry@                                          |
|   Plaid sandbox                  | password    ##########  [Reveal]                            |
|   Azure portal                   | one-time    123 456  (18 s)  [Copy]                         |
|                                  | website     github.com                                      |
|                                  | [Paste password] [Paste code] [Open]                        |
+----------------------------------+-------------------------------------------------------------+
| State: Ready. Loaded 4 items in 0.8 s. Items never enter History. Clipboard clears in 30 s.    |
+------------------------------------------------------------------------------------------------+
```

Resolves: OPW-01, OPW-02, OPW-03, KEY-09.

---

## 13. First-run onboarding and permissions

Today: no dedicated screen in `Sources/Clippy/UI/`; permission problems surface as banners or silence (INT-01). [INFERENCE] There is no first-run flow, based on the file list only.

Redesign: three steps (Permissions, Privacy, Hotkey). Accessibility status updates live after the user returns from System Settings. States what is stored and that nothing leaves the Mac unless AI is enabled. Skippable, and re-openable from Settings. Alfred also keeps clipboard history off until enabled with Accessibility granted (<https://www.alfredapp.com/help/features/clipboard/>).

Compact ~420:
```
+------------------------------------------+
| Welcome to Clippy               1 of 3   |
+------------------------------------------+
| Clippy keeps what you copy so you can    |
| paste it again.                          |
|                                          |
| [ ] Accessibility  needed to paste       |
|     [Open System Settings]               |
| [x] Hotkey        Cmd+Shift+V  [Change]  |
| [ ] Skip and finish later                |
+------------------------------------------+
| [Back]                     [Continue]    |
+------------------------------------------+
```

Default ~720:
```
+----------------------------------------------------------------------+
| Welcome to Clippy                                      Step 1 of 3   |
+------------------------------+---------------------------------------+
| 1 Permissions                | Clippy keeps what you copy            |
| 2 Privacy                    | Other apps need Accessibility         |
| 3 Hotkey                     | Status: Not granted [Open Settings]   |
|                              | Status updates on return.             |
|                              | Hotkey [Cmd+Shift+V] [Change]         |
+------------------------------+---------------------------------------+
| [Back]        [Skip for now]                            [Continue]   |
+----------------------------------------------------------------------+
```

Wide ~1100:
```
+------------------------------------------------------------------------------------------------+
| Welcome to Clippy                                                   Step 1 of 3                |
+------------------------------+----------------------------------------------------+------------+
| 1 Permissions                | Clippy keeps what you copy                         | PRIVACY    |
| 2 Privacy                    | so you can paste again.                            | Local only |
| 3 Hotkey                     | Accessibility: not granted                         | 1Pass off  |
|                              | [Open System Settings]                             | Masked     |
|                              | Status updates on return.                          | AI opt-in  |
|                              | Hotkey [Cmd+Shift+V]                               |            |
+------------------------------+----------------------------------------------------+------------+
| [Back]          [Skip for now]                                         [Continue]              |
+------------------------------------------------------------------------------------------------+
```

Resolves: INT-01, SET-06 (needs-approval state), PNL-09 (hotkey conflict shown early).

## Cross-reference index

| Screen | Primary ROADMAP IDs |
|---|---|
| 1 Panel | PNL-01..04, PNL-07, PNL-11..12, LAY-01..10, LAY-14, KEY-01, KEY-09 |
| 2 Suggestions | INT-01, INT-02, INT-06..08 |
| 3 Sidebar | SBR-01..06 |
| 4 Palette | KEY-08, KEY-10, KEY-11 |
| 5 Quick Look | LAY-11 |
| 6-7 Editors | EDT-01..10, OCR-01, OCR-04 |
| 8 Settings | SET-01..09, PNL-09 |
| 9-10 AI | AI-01..03, AI-05, AI-07..10, AI-12..14 |
| 11 Scripts | SCR-01..06, SCR-08..10, SCR-12 |
| 12 1Password | OPW-01..03 |
| 13 Onboarding | INT-01, SET-06, PNL-09 |
