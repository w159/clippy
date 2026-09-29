# Clippy interaction model (04)

Status: design proposal. Extends `redesign-brief.md` section 5 and pairs with `03-screens.md`. Gap IDs are from `docs/ROADMAP.md`. Competitor conventions cited from pages fetched this session:
- Paste shortcuts: <https://pasteapp.io/help/keyboard-shortcuts>
- Raycast Clipboard History: <https://manual.raycast.com/clipboard-history>
- Alfred Clipboard: <https://www.alfredapp.com/help/features/clipboard/>
- Pastebot 3: <https://tapbots.com/pastebot/>

Anything about Linear, Arc or platform behavior not fetched is marked `[INFERENCE]`.

## 1. Focus map

Regions in Tab order: **Search field -> Filter chips -> Sidebar -> List -> Preview column -> Footer**. Shift+Tab reverses. Paste uses Tab to switch between the search field and the results (<https://pasteapp.io/help/keyboard-shortcuts>); Clippy extends that to a full ring.

```
  +--------------------------------------------------------------+
  | [1 Search]  [2 Chips]                                        |
  +----------------+-----------------------------+---------------+
  | [3 Sidebar]    | [4 List]                    | [5 Preview]   |
  +----------------+-----------------------------+---------------+
  | [6 Footer actions]                                           |
  +--------------------------------------------------------------+
  Tab -> next region, Shift+Tab -> previous, Cmd+F or / -> region 1
```

Rules:
1. The panel opens with focus in Search. Up and Down move the list cursor without leaving the field; Left and Right move the text caret (KEY-06).
2. Clicking a row focuses the List and does not pull focus back to Search (KEY-06). Typing a printable character while the List is focused moves focus to Search and inserts it.
3. Sidebar: Up and Down move, Return opens, Right moves into the List, Space does not toggle anything.
4. Every focus change draws the 2pt accent ring and returns focus to the prior region when an overlay closes.
5. When the panel is re-opened while visible, focus goes to Search and nothing else resets (PNL-04).
6. Non-History sections (Assistant, Scripts, 1Password, AI Actions) own their own focus order. The header search is hidden or replaced by a section search (KEY-09).

## 2. Shortcut table

Fixed unless marked "configurable". Where a key differs from Paste's convention it is noted.

| Keys | Context | Action | Notes |
|---|---|---|---|
| Cmd+Shift+V | global, configurable | Show or hide panel | Same default as Paste and Pastebot; recorder plus conflict detection (PNL-09) |
| Cmd+1 ... Cmd+9 | panel open | Paste the Nth visible row | Paste convention; badges appear while Cmd is held |
| Cmd+Shift+1 ... 9 | panel open | Paste Nth as plain text | Paste convention |
| Return | list or search | Paste selection | Formatted or plain per setting; footer states which |
| Shift+Return | list | Paste using the opposite format | Footer label flips between "plain" and "formatted" |
| Cmd+Return | list | Paste and keep panel open | Raycast uses Cmd+Return for "Copy to Clipboard" (<https://manual.raycast.com/clipboard-history>); Clippy documents its own meaning in the footer |
| Cmd+K | anywhere | Command palette on selection | Same as Raycast Action Panel |
| Space | list | Quick Look toggle | Paste and Pastebot use Space too |
| Cmd+F or / | anywhere | Focus search | Cmd+F again shows all filters when search is active in Paste |
| Cmd+Ctrl+S | panel | Toggle sidebar or rail | SBR-02 |
| Cmd+Ctrl+P | wide | Toggle preview column | |
| Up, Down, Left, Right | list | 2D navigation | Aware of column count (KEY-03) |
| Home, End, PageUp, PageDown | list | Jump | KEY-03 |
| Shift+Arrow | list | Extend range from the anchor | Range can shrink (KEY-04) |
| Cmd+A | list | Select all visible | In Search with text: selects the query (KEY-05) |
| Cmd+C | list | Copy selection without pasting | Does not create a duplicate history entry (KEY-11) |
| Cmd+E | list | Edit clip | Same as Paste |
| Cmd+P | list | Pin or unpin | |
| Delete or Cmd+Delete | list | Delete selection, with Undo toast | KEY-11 |
| Cmd+Z, Cmd+Shift+Z | panel | Undo or redo delete, reorder, category change | SBR-06 |
| Cmd+R | masked row | Reveal or re-mask | Re-masks on hide |
| Option (hold) | masked row | Peek | |
| Cmd+[ , Cmd+] | panel | Previous or next section | |
| Cmd+, | app | Settings | |
| Cmd+S | editors, Scripts, AI Actions | Save | SCR-01 |
| Esc | see section 3 | Two-stage unwind | PNL-11 |

Conflicts to check before shipping: Cmd+Return, Cmd+P (Print in editors), Cmd+Ctrl+S. [INFERENCE] These do not collide with macOS system shortcuts, but this was not tested.

## 3. Escape (two-stage and unwind order)

One step per press, focus returning to the previous region each time:
1. Close an open menu, popover or palette.
2. Close Quick Look.
3. Collapse a multi-selection to a single cursor.
4. Clear the search query and filter chips (PNL-11). This is the "first Esc clears" stage.
5. If in a non-History section, return to History.
6. Hide the panel.

Editors: Esc closes the find bar, then prompts only if dirty, then closes (EDT-01, EDT-10).

## 4. Drag and drop

- **Drag out** (`.draggable`, KEY-11): payload matches the kind (text, RTF, file URL, image). A masked sensitive row drags nothing until revealed. The drag preview is a chip with a glyph and "3 clips"; it never shows content when masked.
- **Drop on a category** = file into. Accent 2pt inset ring on the row plus a label "Move 3 clips to prompts". **Drop on History** = unfile.
- **Reorder** only applies when the dragged item is a category, shown as a 2pt insertion line. Filing and reordering never share an indicator (SBR-05).
- **Drop onto the list area** = create clips from files, images or text (dashed inset border and "Drop to add").
- **Drop text onto an AI Action row** runs that action on it.
- Option-drag copies instead of moving. Escape cancels.
- Auto-scroll at 32pt from list edges; hovering 600ms over a collapsed category opens it.

## 5. Multi-select semantics (anchor + cursor)

Finder-style model (KEY-04):
- Click selects one and sets the anchor. Cmd+click toggles a row without moving the anchor.
- Shift+click or Shift+Arrow selects from the anchor to the cursor; the range can shrink.
- Cmd+A selects everything visible.
- With two or more selected, a glass selection bar shows the count and batch actions (paste, copy, category, pin, delete), and the footer switches to batch hints.
- Right-click on an unselected row selects it first; on a selected row it keeps the selection (KEY-07).
- Return with several selected pastes them in on-screen order joined by the setting (newline by default) as one paste. Cmd+Return pastes one per press using a stack, with a queue indicator (Pastebot stacks are the precedent: <https://tapbots.com/pastebot/>).
- Sensitive clips in a selection require reveal or a confirmation before a batch paste.
- Dropping a multi-selection onto a category files all of them (SBR-06).

## 6. Accessibility behaviors

**VoiceOver**
- Each row is one element (`.accessibilityElement(children: .combine)`). Label reads kind, a content snippet, source app and age; for masked clips: "Sensitive clip, copied 5 minutes ago, source 1Password" and never the content.
- Custom actions on every row: Paste, Paste as plain text, Pin, Edit, Delete, Add to category, Open in Quick Look (A11Y items in ROADMAP section 14).
- The hint bar text is exposed as the row's accessibility hint so "what Return does" is spoken.
- Toasts post `AccessibilityNotification.Announcement`. Banners are focusable and read first when they appear.
- The panel exposes an accessibility title and identifier (PNL-12).
- Sidebar rows announce selected state and item counts; drop targets announce "file into" or "reorder".

**Reduce Motion**: all spring, offset and scale transitions become opacity-only at 80ms; selection scrolling is unanimated; toasts appear without sliding; skeleton shimmer becomes static.

**Reduce Transparency**: glass surfaces (chips, selection bar, palette, Quick Look toolbar, toasts) fall back to a solid elevated surface with a 1pt stroke.

**Increase Contrast**: strokes use the stronger token, glass becomes solid, focus ring stays 2pt, and secondary text in selected rows stays `textSecondary` (see the measured caveat in the brief, section 2.7).

**Text size**: rows use minimum heights and grow with Dynamic Type; above accessibility1 rows become two-line (brief section 2.8, SET-01 for contrast).

Color is never the only carrier of state: pinned is an icon, sensitive is a lock, error is a triangle plus text.

## 7. Empty, error and loading states

Pattern: centered glyph, headline, one line of secondary text, at most one primary button. Never a bare spinner for more than 400ms.

| Surface | Empty | Loading | Error |
|---|---|---|---|
| History | "Nothing copied yet" with the hotkey | 3 skeleton rows | "Couldn't open the clip database" + Try again + Reveal backup |
| Search | "No matches" + Clear filters | inline spinner in the field after 400ms | Unusable pattern: highlight the token and explain (KEY-08) |
| Category | "Drag clips here to file them" | skeleton | rename or duplicate-name error inline (SBR-04) |
| Suggestions | banner "Enable context" if Accessibility is missing | 3 skeleton rows | "Context unavailable in this app" (INT-01, INT-08) |
| Assistant | prompt chips | streaming text + Stop | inline error bubble kept out of the transcript replay (AI-05) |
| Scripts | "No scripts yet" + New script | Running state with Stop | distinct Failed, Cancelled, Timed out (SCR-06) |
| 1Password | "No items in this vault" | 20s timeout then error | Needs sign-in with Sign in button (OPW-01) |
| Image editor | "No text found; image unchanged" | `Extracting text…` inline with action disabled | distinguish failure; Retry remains explicit |
| Settings | no results for a search | none | per-row inline message with an action (SET-03, SET-04) |

Error text: plain cause, one action, "Copy details" that never includes clip content. Deleting always offers Undo for 30 seconds rather than a confirmation dialog, except where data is unrecoverable (scripts marked destructive ask first, SCR-10).
