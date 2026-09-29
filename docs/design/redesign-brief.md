# Clippy UI/UX Redesign Brief

Status: proposal for engineering. Scope: the whole app UI (panel, editors, Settings, AI, Scripts, 1Password, onboarding).
Audit source of truth: `docs/ROADMAP.md` (IDs cited as PNL-xx, LAY-xx, SBR-xx, KEY-xx, SET-xx, A11Y-xx). Screenshots: `.atlas/evidence/2026-09-29-ui-audit/`.

> Research provenance. Mobbin MCP was unavailable (OAuth-gated), so nothing here comes from Mobbin. Sources were public pages and web search results:
> - Apple Liquid Glass / SwiftUI guidance: <https://developer.apple.com/design/human-interface-guidelines/materials>, <https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views>, <https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass>, WWDC25 "Build a SwiftUI app with the new design" <https://developer.apple.com/videos/play/wwdc2025/323/>, and WWDC25 session 284 <https://developer.apple.com/videos/play/wwdc2025/284/> (linked from search results; only the summaries in those results were read, not the full transcripts).
> - Clipboard managers: Paste shortcuts <https://pasteapp.io/help/keyboard-shortcuts> (Cmd+1..9 quick paste, Shift+Cmd+1..9 plain text), Raycast Clipboard History <https://manual.raycast.com/clipboard-history> (searchable history, Cmd+K action panel), Maccy shortcuts <https://maccymanager.com/documentation> (Option+1..9, Option+Shift+Return plain).
> - Alfred, Pastebot, Things 3, Linear, Arc, Craft, Bear were NOT fetched. Statements about them below are marked `[INFERENCE]` (general knowledge, not verified this session).
> - WCAG ratios in section 2 were computed in this session with the standard relative-luminance formula (WCAG 2.x, <https://www.w3.org/TR/WCAG21/#contrast-minimum>).

---

## 0. What is wrong today (from the audit, so the redesign is aimed)

| Symptom | Evidence | Design response |
|---|---|---|
| Card leads with source app name ("Microsoft Edge Dev" is the biggest text on ~93% of cards) | LAY-07, `10-panel-default.png` | Content is the headline; app is a 14pt icon in metadata |
| Cards overflow, timestamps wrap to one char per line at 4 cols | LAY-01..03 | Compact row (32pt) is the default; card min width derived from layout; `ViewThatFits` headers |
| Hover toolbar covers timestamp/kind | LAY-06 | Actions crossfade over metadata in the trailing slot, never overlay content |
| Per-card colored strokes fight selection | LAY-09 | Stroke belongs to selection/focus only; kind is a glyph tint, not a border |
| No resizable sidebar / no collapse | SBR-01, SBR-02 | 6pt grabber, 150-260pt, icon rail 44pt under 520pt |
| Search bar shown where it does nothing (Assistant, Scripts, 1Password) | KEY-09, `50-assistant.png` | Header search is section-scoped; hidden or replaced per screen |
| Nav keys only on the search field; click steals focus | KEY-03, KEY-06 | Explicit focus map (section 5) |
| Low contrast text, no Reduce Motion / Transparency support, fixed font sizes | SET-01, A11Y-03 | Semantic tokens with AA-verified values; Dynamic Type mapping; accessibility fallbacks per material |
| No preview / Quick Look | LAY-11 | Space = Quick Look; preview column at >= 900pt |
| Settings: 1.7k-line single scroll, no search | SET-09 | Sidebar Settings with search |
| Footer shortcut bar says "paste plain" for Return (mislabelled), always shows the same 6 hints | `10-panel-default.png` | Context-sensitive hint bar driven by focus and selection |

---

## 1. Design principles

Clippy is opened dozens of times a day, for 2-10 seconds each, from the keyboard, over someone else's app, with client NPI on screen (FTC Safeguards, Reg S-P, GLBA).

1. **Keyboard first, mouse complete.** Every action reachable without a pointer, and the fastest path (Hotkey, type, Return) is at most 3 keystrokes. Every pointer affordance has a key equivalent shown in its tooltip. Test: paste the 3rd-most-recent clip with hands on the home row.
2. **Content is the headline.** The clip's own text or pixels are the largest, highest-contrast thing in a row. Source app, time and kind are metadata: 12pt, secondary color, one line, always in the same position so the eye learns it.
3. **Glanceable at 400ms.** A row is identifiable by shape before it is read: a kind glyph tint, a 32pt thumbnail for images, a swatch for colors, monospace for code. No decoration that does not carry information (kills per-card gradients, per-card colored borders).
4. **Sensitive by default, revealed on intent.** Clips flagged sensitive (1Password, secure input, matched patterns) render masked in every surface, including Quick Look and screenshots of the panel. Reveal is an explicit, temporary, keyboard-accessible action (hold Option or Cmd+R), and re-masks on panel hide. No clip text ever reaches logs, toasts, or accessibility labels while masked.
5. **Density is a user choice; calm is the default.** Three densities (Compact row 32pt, Comfortable row 56pt, Cards) share one data model. Default = Compact. Chrome recedes; glass is used only for the floating control layer.
6. **State is always visible, motion is only feedback.** Selection, focus, pending (paste in flight), error and "what Return will do" are shown persistently. Animation (<= 220ms) confirms a cause; nothing animates on its own; Reduce Motion replaces every transition with a crossfade or nothing.
7. **One system, everywhere.** The panel, editors, Settings and AI use the same tokens, radii, row heights and components (section 3). A new screen is assembled, never styled. Themes change token values, never layout.

---

## 2. Visual language (macOS 26)

### 2.1 Liquid Glass usage rules

Basis: Apple says Liquid Glass is for the *functional layer* (controls, navigation) floating above content, not for content itself; use standard materials for content backgrounds; group nearby glass in a `GlassEffectContainer`; use `.interactive()` on custom controls; tint only to convey meaning; test with Reduce Transparency / Increase Contrast ([HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views), [WWDC25-323](https://developer.apple.com/videos/play/wwdc2025/323/)).

| Layer | Treatment | Rationale |
|---|---|---|
| Panel window backdrop | System window material via `NSVisualEffectView` `.underWindowBackground`/`.hudWindow` (fallback), on macOS 26 `NSGlassEffectView` as the window content background | Panel floats over arbitrary apps; a glass window is the platform idiom. Fixes dead `panelMaterial` setting (LAY-14) |
| Clip list rows and cards | **Solid**: `surface` / `surfaceElevated` tokens, no glass | Repeated content; glass per row is expressly discouraged and hurts perf |
| Header (search field), footer hint bar | Sit directly on the panel backdrop; the search field is a solid inset (`surfaceInset`) capsule, not glass | Text input needs predictable contrast |
| Filter chips row, selection action bar (appears when >=2 selected), Quick Look toolbar, toasts, command palette container | **Glass**, `.glassEffect(.regular, in: Capsule/RoundedRectangle)`, grouped in one `GlassEffectContainer(spacing: 8)` per cluster | These are the floating control layer |
| Icon-only buttons (pin, edit, delete, close) | `.buttonStyle(.glass)` on macOS 26 only inside the action cluster; otherwise `.plain` with hover fill | Avoids 6 glass blobs per row |
| Sidebar | Solid `surfaceSidebar` (tinted 4% toward accent) on light/dark; on macOS 26 may use the system sidebar glass by hosting inside `NavigationSplitView` in Settings only | Sidebar in the popup is dense with small text; keep solid |
| Sheets/inspectors/editors | System sheet/inspector materials, no custom glass | Let the system do it |
| Destructive confirmations | Solid, never glass | Clarity |

Rules:
1. Never nest glass in glass. Never put glass behind body-size text in a scrolling region.
2. `GlassEffectContainer(spacing:)`: use `spacing = 8` for chip rows and action clusters (blend when closer than 8pt, i.e. never at the default 6pt gaps + 2pt stroke; keep clusters visually separate unless you want a merged pill), and `spacing = 24` for the toast+banner stack so they do not merge. Use `glassEffectID` + `@Namespace` only for two morphs: search field <-> command palette, and chip -> chip-menu.
3. Tint glass only for meaning: `accent` tint on the primary action in a bar, `danger` on destructive. No decorative tint.
4. **Fallbacks are mandatory** (A11Y-03). One helper `ClippyGlass` (section 7) implements: macOS 26 and `!reduceTransparency` -> `glassEffect`; otherwise `.regularMaterial` in a solid `surfaceElevated` overlay with `stroke` 1pt; with Increase Contrast (`colorSchemeContrast == .increased`) -> solid `surfaceElevated` + `strokeStrong` 1pt. Deployment target below 26 -> material path.
5. Vibrancy: text on glass uses `.primary`/`.secondary` semantic styles, not fixed hex.

### 2.2 Radii scale

| Token | pt | Used for |
|---|---|---|
| `radius.xs` | 4 | Kbd hint keycaps, tag chips inside rows, color swatch corners |
| `radius.sm` | 8 | Rows (compact), inline buttons, text fields, list selection pill |
| `radius.md` | 12 | Cards, thumbnails, popover content, code blocks |
| `radius.lg` | 16 | Command palette, sheets content blocks, toasts (non-capsule), preview column container |
| `radius.xl` | 24 | Panel window (macOS 26 window corner concentricity; on macOS 26 use `ConcentricRectangle` where available so inner shapes follow the container inset) |
| `radius.full` | capsule | Chips, search field, glass action clusters |

Concentricity rule: inner radius = outer radius - inset (row 8 inside a 12pt inset list container of radius 20 is close enough; do not exceed).

### 2.3 Spacing scale (4pt grid)

`space.0=0, 1=4, 2=8, 3=12, 4=16, 5=20, 6=24, 8=32, 10=40`. Panel outer padding 12; header height 48; footer 32; compact row 32 tall with 8 horizontal padding and 4 vertical gap between rows (row pitch 36); comfortable row 56 (pitch 60); card min 180 wide, 12 padding, 8 gap. Sidebar row 30 tall. Settings row min 44. Hit target minimum 28x28 for pointer, 44x44 for touch-like accessibility (Settings toggles use the system size).

### 2.4 Elevation

Three levels, using shadow only where content really floats (no shadow on rows):

| Level | Use | Light | Dark |
|---|---|---|---|
| e0 | rows, sidebar | none, 1pt `stroke` only when selected | same |
| e1 | cards (Cards density), popovers | `0 1 2 rgba(0,0,0,.08)` + 1pt `stroke` | `0 1 2 rgba(0,0,0,.4)` + 1pt `stroke` |
| e2 | command palette, Quick Look floating toolbar, toasts | `0 8 24 rgba(0,0,0,.16)` | `0 8 24 rgba(0,0,0,.5)` |

The panel window's own shadow is the system window shadow; do not add one.

### 2.5 Motion

| Token | Duration | Curve | Use |
|---|---|---|---|
| `motion.instant` | 80ms | ease-out | hover fill, pressed state |
| `motion.quick` | 140ms | `.easeOut` | selection move, chip toggle, action crossfade |
| `motion.standard` | 220ms | `.spring(response: 0.28, dampingFraction: 0.86)` | preview column open, sidebar collapse, palette open (scale 0.98 -> 1 + fade) |
| `motion.toast` | 260ms in / 180ms out | spring in, ease-in out | toast |
| `motion.masked` | 120ms | linear | reveal/mask blur transition |

Panel show: fade 100ms + 4pt upward offset; panel hide: fade 80ms. No bounce elsewhere.
Reduce Motion (`accessibilityReduceMotion`): all spring/offset/scale transitions become `.opacity` only at `motion.instant`; list selection scroll uses no animation; toast appears without slide; the helper `Motion.animation(_:reduce:)` returns `nil`/`.easeInOut(0.01)`.

### 2.6 Iconography

SF Symbols 7 (macOS 26). Sizes/weights: row glyph 14pt `.regular`, `imageScale(.medium)`; sidebar 15pt `.medium`; header/toolbar buttons 15pt `.medium`; empty-state hero 40pt `.light`; kbd hints use text, not symbols (except Return/Delete/Esc glyphs). Rendering: `.monochrome` for chrome (tinted by `textSecondary`, `accentText` when active); `.hierarchical` for kind glyphs; `.palette` only for the AI sparkle. Variants: use `.fill` only for selected/active state (sidebar selected item, pin active); outline elsewhere. Category icons keep the existing `IconPickerView` set. Kind glyph map: text `text.alignleft`, link `link`, email `envelope`, color `circle.fill` (swatch instead), file `doc`, filePath `folder`, image `photo`, code `curlybraces` (see 2.7 for code detection, currently `ClipKind.text`), sensitive `lock.fill`, pinned `pin.fill`, AI `sparkles`, script `terminal`.

### 2.7 Color roles (semantic tokens)

Naming maps onto the existing `ThemeTokens` (see section 6). Contrast targets: WCAG 2.x AA, 4.5:1 for text under 18pt (or under 14pt bold), 3:1 for large text and for meaningful non-text UI (control borders, focus rings, icon-only glyphs). Ratios below were computed this session (relative luminance formula); "on surface / on elevated" = against `surface` / `surfaceElevated`.

| Token | Light | Dark | Notes / measured contrast |
|---|---|---|---|
| `surface` (panel base under rows) | #F5F5F7 | #1C1C1E | fallback under glass |
| `surfaceElevated` (cards, palette, sheet blocks) | #FFFFFF | #2C2C2E | |
| `surfaceInset` (search field, text wells) | #EAEAEE | #141416 | |
| `surfaceSidebar` | #EFEFF3 | #18181A | |
| `selection` (row fill) | #FBEFD6 | #4A3A17 | accent-tinted; keyboard cursor = `selection` fill + 2pt `accent` leading bar; focus ring separate |
| `stroke` (hairlines, dividers) | #D9D9DE | #3A3A3E | decorative, exempt |
| `strokeStrong` (input borders, focus outline) | #8A8A90 | #7C7C82 | light 3.15 on surface, 3.43 on elevated; dark 4.10 on surface, 3.36 on elevated. Passes 3:1 non-text on non-selected surfaces |
| `textPrimary` | #1D1D1F | #F5F5F7 | 15.5 / 16.8 light; 15.6 / 12.8 dark |
| `textSecondary` | #55555A | #B4B4BA | 6.8 / 7.4 light; 8.3 / 6.8 dark |
| `textTertiary` | #6A6A70 | #9A9AA0 | 4.9 / 5.4 light; 6.1 / 5.0 dark (still AA; never below this) |
| `accent` (fills, bars, ring) | #E0A23C (Clippy Amber) | #F2BC55 | fill with `onAccent` text #1D1D1F: 7.5 light, 9.7 dark |
| `accentText` (links, active labels) | #7A4E00 | #F2BC55 | 6.6 / 7.2 light; 9.8 / 8.0 dark. Raw amber #E0A23C on white is ~2.1:1, so it is **never** used as text |
| `onAccent` | #1D1D1F | #1D1D1F | |
| `success` | #176B33 | #4CC46A | 6.1 light; 7.6 dark |
| `warning` | #7A4E00 | #F2BC55 | same numbers as `accentText`; pair with `exclamationmark.triangle.fill` (never color alone) |
| `danger` | #B3261E | #FF7A70 | 6.0 light; 6.7 dark |
| `masked` (blur placeholder fill) | #D9D9DE | #3A3A3E | with `lock.fill` glyph in `textSecondary` |

Measured caveat: on the dark `selection` fill (#4A3A17) `textTertiary` is 3.93, `danger` 4.33 and `strokeStrong` 2.65 (all below AA), while `textPrimary` 10.1, `textSecondary` 5.33 and `accentText` 6.34 pass. Rule: **inside a selected row, secondary/tertiary metadata is rendered in `textSecondary`, and destructive glyphs use `danger` only on hover-revealed buttons over `surfaceElevated`.** (On light `selection`: `textTertiary` 4.71, `danger` 5.73: all pass.)

Per-kind hues (glyph tint and 3pt kind bar in Cards density; never a card border). Light/dark, all >= 4.5 on their surfaces (measured 4.8-7.0 light on elevated, 6.3-8.3 dark on elevated):

| Kind | Light | Dark | Glyph |
|---|---|---|---|
| text | #55555A | #B4B4BA | text.alignleft |
| link | #0B57D0 | #7AB0FF | link |
| email | #B34700 | #FF9F5A | envelope |
| image | #7B2FBE | #C79BFF | photo |
| file / path | #6B5B00 | #E3C65A | doc / folder |
| color | #B0246B | #FF8FC2 | swatch |
| code | #0F6B5C | #4FD1B8 | curlybraces |
| sensitive | `textSecondary` | `textSecondary` | lock.fill |

Category colors keep `CategoryPalette.hexes`; category color is used only for the 8pt sidebar dot and the row's category chip, always paired with the category name.

Accessibility: Increase Contrast -> `stroke` becomes `strokeStrong`, glass becomes solid (2.1 rule 4). Never encode state by color alone (pinned = icon, sensitive = lock, error = triangle + text).

### 2.8 Typography

System font (SF Pro) by default; the existing `PanelFontFamily` override continues to apply to `body` and `title` roles only (monospace roles are fixed). Mapped to SwiftUI text styles so Dynamic Type/`.dynamicTypeSize` works (macOS 14+ respects text-size settings via `Font.TextStyle`; the current fixed `.system(size:)` path in `PanelTypography.make` is the A11Y-03 bug).

| Role | Style / size at default | Weight | Line limit | Use |
|---|---|---|---|---|
| `title` | `.headline` 13pt | semibold | 1 | Settings pane titles, AI action names, editor title |
| `body` | `.body` 13pt | regular | 1-2 in comfortable, 1 in compact, 4 in cards | clip preview text |
| `bodyEmphasis` | `.body` | medium | 1 | selected row text, chip labels |
| `meta` | `.caption` 10pt -> use `.callout`-relative: 11pt via `.system(.caption, design: .default)` with min 11 | regular | 1 | time, app name, dimensions |
| `micro` | `.caption2` 10pt | medium | 1 | counts, kbd caps (never below 10) |
| `mono` | `.system(.body, design: .monospaced)` 12pt | regular | per context | code clips, hex, script editor |
| `display` | `.title2` 17pt | semibold | 1 | empty-state headline, onboarding step titles |

Dynamic Type behavior: rows use `minHeight` not fixed height, so compact row = 32pt at default and grows with the text size (`@ScaledMetric(relativeTo: .body) var rowHeight = 32`, capped at 2x via `.dynamicTypeSize(...DynamicTypeSize.accessibility1)` on the list container; above that the row goes to 2-line layout). The user text-size setting (`fontSizeBase`) becomes a multiplier applied through `.environment(\.dynamicTypeSize, …)` mapped from 5 steps (Small = `.small` ... Large = `.xxLarge`) instead of an absolute size.

---

## 3. Component inventory

All components live in the shared design-system module (section 7). Common state rules: **hover** = `hover` fill (`textPrimary` @ 6% light / 8% dark) over `motion.instant`; **pressed** = @ 12%; **selected** = `selection` fill + 2pt accent leading bar (rows) or 1.5pt `accent` inner stroke (cards); **focused (keyboard)** = 2pt `accent` focus ring outset 1pt, `radius` of component + 1 (never hidden by clipping; use `.focusEffectDisabled()` then draw own); **disabled** = 40% opacity, still exposes AX label with "dimmed".

### 3.1 Panel shell + header/search
Anatomy: window (radius.xl) > header 48pt [search field capsule (flex) | scope chip (optional) | density toggle | overflow menu] > filter chips row 32pt (collapsible) > body [sidebar | list | preview] > hint footer 32pt.
- Header is the drag region (`WindowDragGesture`, PNL-01); interactive children excluded. No title text; the window has AX title "Clippy" (PNL-12). Pin and close move to the overflow/traffic-less chrome: close = Esc; pin = Cmd+Shift+P toggles "stay open" (shown as `pin.fill` in the header only when active).
- Search field: 32pt tall, `surfaceInset`, `radius.full`, leading `magnifyingglass` 14pt `textTertiary`, placeholder "Search clips  (# kind, @ app, ! sensitive)", trailing clear `xmark.circle.fill` when non-empty, trailing `Cmd+F` hint when empty and unfocused. States: rest/hover (stroke) / focused (2pt accent ring) / disabled (hidden in sections with no search, KEY-09).
- Resize: `.titled` + `.fullSizeContentView` + hidden titlebar so AppKit provides edge resize cursors (PNL-02); min size derived: 360x320 in compact (rail), 560x360 with sidebar.
- SwiftUI: `PanelShell` (ZStack with `ClippyGlass` backdrop) hosting `PanelHeader`; window level lowered to `.normal` while a Clippy window is key (PNL-07).

### 3.2 Filter chips
Anatomy: 28pt tall capsule, 10pt horizontal padding, optional leading glyph 12pt, label `meta` medium, optional count `micro`. Row is a horizontally scrolling `ScrollView(.horizontal)` inside one `GlassEffectContainer(spacing: 8)`.
States: rest = glass regular; hover = `.interactive()`; selected = accent-tinted glass + `accentText` label + `checkmark` prefix omitted (tint conveys; the chip also carries `accessibilityAddTraits(.isSelected)`); disabled = 40%.
Chips: All, Text, Links, Images, Files, Code, Colors, Pinned, Today, App... (menu chip opening app list), Sensitive. Multi-select within a group is OR; across groups AND. A chip writes into the search query grammar (KEY-08), and typing the grammar toggles the chip (`#image`).

### 3.3 Clip row (compact, 32pt)
Anatomy (left to right): 2pt leading selection bar | 8 | kind glyph 16x16 (or 24x24 rounded thumbnail for image/file with preview, 20x20 color swatch) | 8 | content (`body`, 1 line, `truncationMode(.tail)`, mono for code) | flex | metadata slot (trailing): [category chip (only if in a category and width >= 560)] [app icon 14x14] [relative time `meta`, `.fixedSize()`, `layoutPriority(2)`] | 8. Quick-paste index badge (`micro` in `radius.xs` keycap, "⌘1"..."⌘9") replaces the kind glyph column's tooltip and shows in the trailing slot for the first 9 visible rows when Cmd is held (always visible in Comfortable).
- Hover: trailing slot crossfades (motion.quick) from metadata to action cluster [pin, edit, AI, delete] (each 24x24). Metadata never overlaps actions (LAY-06). Keyboard-focused row shows the action cluster too.
- States: rest, hover (hover fill), pressed, selected (fill + bar), focused (ring), disabled (dimmed + "Unavailable" AX), pending-paste (trailing spinner 12pt), sensitive-masked (3.8).
- Multi-line clips show ` ...` and line count `micro` ("+12 lines") only in Comfortable.
- Truncation priority under width pressure: category chip -> app icon -> line count -> content shrinks last; time is never dropped and never wraps (LAY-03).
- SwiftUI: `ClipRow` (value-type `ClipRowModel` input, `Equatable`, no `@ObservedObject AppSettings`, LAY-12), `LazyVStack` in `ScrollView` with `.scrollTargetLayout()` + `scrollPosition(id:)`; accessibility: `.accessibilityElement(children: .combine)` + `accessibilityAction(named: "Paste" / "Pin" / "Edit" / "Delete")` (A11Y-01).

### 3.4 Clip card (comfortable / cards density)
Comfortable row: 56pt tall, two lines of body text (`body` 2 lines) + one metadata line? No: metadata stays in trailing slot; the second body line is content. Cards density: adaptive grid `GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 8)`, min card height 96, max 200; anatomy: 3pt kind bar on top edge (kind hue) | 12 padding | preview (2-6 lines text, or image aspect-fit 16:10 max 120pt, or link title + host + favicon) | metadata footer row 20pt (app icon, time, pin) . `surfaceElevated`, e1, `radius.md`. Selected = 1.5pt accent inner stroke, no other borders (LAY-09). Hover reveals action cluster in the footer replacing time (same crossfade rule). Column count is "Auto" by default (LAY-02, LAY-05); manual counts allowed, clamped so card >= 180pt.

### 3.5 Previews: image / file / link / color / code
- Image: aspect-fit in a 16:10 (cards) or 24pt square (row) box; background = checkerboard (8pt squares, `stroke`/`surface`) when the image has alpha, else `surfaceInset`; `radius.sm`/`md`; dimensions and size in `meta` ("1,144x961 PNG, 212 KB"). OCR text available -> `text.viewfinder` glyph in metadata (OCR items). Never crop-fill (LAY-10).
- File: 24pt system file icon (`NSWorkspace.icon(forFile:)`, cached) + filename (body, middle-truncation) + parent path (`meta`, tail-truncated) + size. Missing file -> `exclamationmark.triangle` and "File moved" in `warning`.
- Link: favicon 16 (cached, fetched only if the user enabled link previews; **no network by default**, compliance) + title else host (body) + host (`meta`); scheme other than https shows `exclamationmark.shield` `warning`.
- Color: 20x20 swatch (`radius.xs`, 1pt `stroke`) + hex in `mono` + contrast chip "AA 7.1" optional in preview column.
- Code: `mono` 12pt, first 2 (row: 1) lines, language chip (`radius.xs`, `micro`) when detected, background `surfaceInset` in cards; syntax coloring only in the preview column/editor, not in list.

### 3.6 Sensitive-clip masked state
Row: content replaced by 10 `masked` capsule blocks? Simpler and safe: a single 96x10 `masked` capsule + `lock.fill` glyph in the kind column + label "Sensitive" `meta` `textSecondary`; the AX label is "Sensitive clip, copied 5 minutes ago, source 1Password", never the content. Not selectable-copyable via drag (drag exports nothing until revealed). Reveal: hold Option on the focused row (peek while held) or Cmd+R (toggle, auto re-mask after 10s and on panel hide); reveal crossfade `motion.masked`. Paste still works (that is the point) with Return; a paste of sensitive clip uses the clipboard-transient marker (owned by CapturePaste). Quick Look shows a masked placeholder until revealed. Screenshots: window `sharingType = .none` while any sensitive row is visible and masking is enabled (`NSWindow.sharingType`, owner decision recommended; flagged in section 7 open questions).

### 3.7 Reason chip (Suggestions)
Small capsule (20pt, `meta`, `radius.full`) explaining *why* a suggestion appears: "Same app: Xcode", "Copied 3x today", "Matches selection", "Used here last Tuesday". Leading 10pt glyph. Tint = `textSecondary` on `surfaceInset`; hover shows a popover with the rule and a "Don't suggest this" action. Max 1 shown, 2 on wide. States: rest/hover/pressed/focused.

### 3.8 Toast / banner
Toast: glass capsule, 36pt tall, max width 360, bottom-center above the footer (or bottom of the window in Quick Look), leading glyph 14 (`checkmark.circle.fill` success / `exclamationmark.triangle.fill` warning / `xmark.octagon.fill` danger), one-line message (`bodyEmphasis`), optional trailing action ("Undo") in `accentText`. Duration 3s, 6s if it has an action, pause on hover; VoiceOver posts `AccessibilityNotification.Announcement`. Never contains clip content (use "Copied", "Deleted 3 clips").
Banner: full-width, 40pt, under the header, solid tinted `warning`/`danger` at 12% over `surface`, 1pt `stroke`, glyph + one sentence + one button (e.g. "Accessibility permission needed  [Open Settings]"), dismissible only when non-blocking.

### 3.9 Empty / loading / error states
Pattern: centered column, 40pt `.light` hierarchical glyph in `textTertiary`, `display` headline, `body` `textSecondary` one-liner (max 2 lines, 320pt), optional single primary button.
- Empty history: "Nothing copied yet" - "Copy something and it shows up here. Cmd+Shift+V opens Clippy anywhere."
- Empty search: "No matches for that search" + chips to widen ("Clear filters").
- Empty category: "Drag clips here to file them".
- Loading: skeleton rows (3 x 32pt `surfaceInset` capsules, shimmer 1.2s linear, static under Reduce Motion); spinner only for actions > 400ms.
- Error: `warning`/`danger` glyph + cause in plain English + "Try again" + "Copy details" (no clip content in details). Database error offers "Reveal backup".

### 3.10 Sidebar rail (expanded and icon rail)
- Expanded: width 176 default, 150-260 resizable via 6pt grabber (resize cursor, double-click reset, SBR-01). Sections: **Library** (History, Pinned, Today) | **Categories** (user, drag-reorder, count `micro`, 8pt color dot + icon) | **Tools** (1Password, Scripts, Assistant, AI Actions) | footer "+ New Category". Row 30pt, `radius.sm` selection pill = `selection` + 2pt accent bar? (pill only in the sidebar: `selection` fill, accent glyph fill variant, label `bodyEmphasis`).
- Icon rail: 44pt wide, 28x28 hit targets, glyph 16, tooltip = label + count, selection = `selection` circle behind glyph; auto when panel width < 520 or toggled (Cmd+Ctrl+S). Categories without unique icons show colored dot + first letter.
- Both: rows are focusable (Tab/arrows), rename on Return or double-click, drop target shows an accent 2pt inset ring for "file into" and a 2pt horizontal insertion line for "reorder" (SBR-05), each announced.
- SwiftUI: `SidebarView` + `SidebarRail`, chosen by `ViewThatFits`-like breakpoint using `onGeometryChange`.

### 3.11 Segmented controls
System `Picker(.segmented)` for 2-4 options (density: rows/comfortable/cards; Settings appearance: system/light/dark), `controlSize(.regular)` 28pt tall; glass on macOS 26 comes from the system. Custom `ClippySegmented` only for icon-only segments with tooltip + AX label. Selected = system; never a custom accent fill under 3:1.

### 3.12 Settings rows
`SettingsRow`: min height 44, label `body` (leading), optional description `meta` `textSecondary` beneath (max 2 lines), control trailing (Toggle, Picker, Stepper with visible value, ColorPicker + single monospaced hex field, hotkey recorder, button). Grouped in `SettingsSection` (title `micro` caps `textTertiary`, container `surfaceElevated` `radius.md`, hairline separators inset 16). States: hover (hover fill on whole row for rows with a navigation chevron), focused (ring around control), disabled (40% + explanation line "Requires iCloud Drive" with a link button). Rows support `searchKeywords` for the Settings search.

### 3.13 Sheet / inspector
Use system `.sheet` (modal, 480 wide, header `title` + close via Esc, footer buttons: Cancel (left of primary), primary `.borderedProminent` tinted `accent`, `onAccent` label; destructive uses `danger` role) and `.inspector` (trailing, 280-360 wide) in editors for metadata (categories, tags, source, OCR text). Both restore focus to the invoking element on dismiss.

### 3.14 Command palette overlay (Cmd+K)
Centered over the panel, 560 wide (max 90% of panel), radius.lg, glass container, e2. Anatomy: input row 44 (`command` glyph, text field, `esc` keycap) | results list, rows 36 grouped by section header (`micro` caps): Actions (on selection: Paste, Paste plain, Copy, Pin, Edit, Delete, Run script..., AI action...), Navigate (go to category/section), Settings (search settings), Recent queries | footer hint bar. Fuzzy-matched; shows shortcut keycaps right-aligned; Return runs; Esc closes (one step). Opens as the Raycast Action Panel does on Cmd+K ([Raycast manual](https://manual.raycast.com/clipboard-history)), acting on the selected clip when present, else on the app. Morph from the search field via `glassEffectID`.

### 3.15 Quick Look preview
Space toggles. Wide: renders in the preview column (3.16). Compact/default: floating glass panel anchored over the list, 90% width, max 640x420, radius.lg, e2, with a glass toolbar (paste, edit, copy, share, close). Content: full text (selectable, mono if code, find with Cmd+F), image zoom (fit/100% via `+`/`-`/`0`), link card, file `QLPreviewView` where possible, color large swatch + values (hex/rgb/hsl, click to copy any). Arrow keys change the previewed clip without closing. Esc closes preview first. Masked clips show placeholder until revealed.

### 3.16 Preview column (wide only, >= 900pt)
Right column 320-480 (default 360), `surfaceElevated` `radius.lg`, inset 8; header (kind glyph, title, time) + preview + metadata list (source app, size, category, tags, used N times, OCR toggle) + action cluster at bottom. Collapsible (Cmd+Ctrl+P / `sidebar.right`).

---

## 4. Per-screen concepts and wireframes

Breakpoints (panel content width): **compact ~420** (rail 44, one column, no preview), **default ~720** (sidebar 176, list; Quick Look floats), **wide ~1100** (sidebar 200, list >= 360, preview column 360). Legend: `[ ]` button/chip, `( )` field, `▌` selection bar, `*` selected, `░` masked, `⌘` keycap. Wireframes show layout, not pixel metrics; numbers are in section 3.

### 4.1 Popup panel (History)

Compact 420:
```
+------------------------------------------+
| (🔍 Search clips…          )  [≡] [⋯]    |  48
| [All][Text][Links][Img][Code]  ›         |  32
+----+-------------------------------------+
| ⏱  |▌ ¶ apikey_253c23af810d99c…  Edge 33m |
| 📌 |  🔗 https://microsoft.github.io/… 2h |
| ●  |  🖼 [thumb] 1,144×961 PNG      1d   |
| ●  |  ░░░░░░░░░ 🔒 Sensitive        2m   |
| ●  |  ¶ Read from https://code.cl…   5m  |
|----+                                     |
| 🔑 |                                     |
| >_ |                                     |
| ✦  |                                     |
+----+-------------------------------------+
| ↩ paste   ⇧↩ plain   ␣ look   ⌘K more    |  32
+------------------------------------------+
```
Default 720:
```
+--------------------------------------------------------------+
| (🔍 Search clips  # kind  @ app  ! sensitive      )  [▤▦▥] [⋯]|
| [All][Text][Links][Images][Files][Code][Colors][Pinned][App▾]|
+--------------+-----------------------------------------------+
| LIBRARY      | TODAY                                         |
| ⏱ History 344|▌¶ Read from https://code.claude.com/docs…  ⌘1 |
| 📌 Pinned   6|  ¶ apikey_253c23af810d99c455…  ◉ Edge   33m  ⌘2|
| Today     12 |  ¶ 426233                     ◉ Claude  45m  ⌘3|
| CATEGORIES   |  ░░░░░░░░░ 🔒 Sensitive        ◉ 1Pass    1h ⌘4|
| ● claude  14 | YESTERDAY                                     |
| ● prompts 16 |  🖼 [thumb] 1,144×961 PNG   ◉ CleanShot    1d  |
| ● scripts 10 |  🔗 microsoft.github.io/mcp-gateway ◉ Edge  1d |
| TOOLS        |                                               |
| 🔑 1Password |                                               |
| >_ Scripts 5 |                                               |
| ✦ Assistant  |                                               |
| + New Categ. |                                               |
+--------------+-----------------------------------------------+
| ↩ paste  ⇧↩ plain  ⌘↩ paste & keep  ␣ look  ⌘E edit  ⌘K more  |
+--------------------------------------------------------------+
```
Wide 1100:
```
+-------------------------------------------------------------------------------------+
| (🔍 Search clips  # kind  @ app  ! sensitive           )      [▤▦▥]  [◧] [⋯]        |
| [All][Text][Links][Images][Files][Code][Colors][Pinned][App▾][Sensitive]            |
+-----------+-------------------------------------------+-----------------------------+
| LIBRARY   | TODAY                                     |  🔗 Link · Edge · 2h        |
| ⏱ History |▌🔗 https://microsoft.github.io/mcp-gat… ⌘1|  ┌───────────────────────┐  |
| 📌 Pinned | ¶ Read from https://code.claude.com…   ⌘2 |  │ microsoft.github.io   │  |
| CATEGORIES| ¶ apikey_253c23af810d99…               ⌘3 |  │ MCP Gateway docs      │  |
| ● claude  | ░░░░░░░░ 🔒 Sensitive                  ⌘4 |  └───────────────────────┘  |
| ● prompts | YESTERDAY                                 |  Source  Microsoft Edge     |
| TOOLS     | 🖼 [thumb] 1,144×961 PNG                  |  Used    3 times            |
| 🔑 1Pass  |                                           |  [Paste] [Edit] [Pin] [⋯]   |
+-----------+-------------------------------------------+-----------------------------+
| ↩ paste   ⇧↩ plain   ⌘↩ paste & keep   ␣ look   ⌘E edit   ⌘K more                   |
+-------------------------------------------------------------------------------------+
```
Notes: list stays the single focus target; preview follows the cursor (debounced 80ms; masked clips never load content into the column until revealed). Section headers sticky, `micro`. Replaces `ClipListView` body, `ClipCardView`, `PanelHeaderView`, footer.

### 4.2 Suggestions pane
Shown above the list when the frontmost app or context yields suggestions (`SuggestionsPaneView`), max 3 items, dismissible per session, hidden if setting off.

Compact:
```
| SUGGESTED FOR Xcode                 [×] |
| ¶ swift build 2>&1 | xcpretty  [Same app]|
| ¶ com.henssler.clippy    [Copied 3× today]|
```
Default:
```
| SUGGESTED FOR  Xcode  ─────────────────────────────── [Hide] |
| ¶ swift build 2>&1 | xcpretty      (Same app)          ⌘⌥1   |
| ¶ com.henssler.clippy              (Copied 3× today)   ⌘⌥2   |
| 🔗 https://developer.apple.com/…    (Used here Tue)     ⌘⌥3   |
```
Wide: same rows, reason chips get the two-chip form (rule + count) and the preview column follows the suggestion cursor. Suggestions use standard rows with a `surfaceElevated` container (`radius.md`), no glass. Reasons come from Smart Suggestions (ROADMAP section 18); every row shows a reason chip (3.7) - no unexplained suggestions.

### 4.3 Sidebar (three states)
Compact = icon rail:
```
+----+
| ⏱  |  <- History (selected: circle behind)
| 📌 |
|----|
| ●c |  categories: dot + letter
| ●p |
|----|
| 🔑 |
| >_ |
| ✦  |
| ＋ |
+----+
```
Default expanded 176:
```
| LIBRARY          |
|▌⏱ History     344|
|  📌 Pinned      6|
| CATEGORIES   [+] |
|  ● claude      14|  drag handle on hover
|  ● prompts     16|
| TOOLS            |
|  🔑 1Password    |
|  >_ Scripts     5|
|  ✦ Assistant     |
|  ✧ AI Actions    |
|               ┆  |  ← 6pt grabber
```
Wide 200: as expanded with counts always visible and the "New Category" row replaced by a persistent `[+]` in the section header. Count = what is displayed (SBR-03). Replaces `CategorySidePane`.

### 4.4 Quick paste / command palette (Cmd+K)
Two modes sharing one component: **Quick paste** (index badges, Cmd+1..9) is the History list itself; **Palette** is the Cmd+K overlay.

Compact 420 (palette fills width - 24):
```
+------------------------------------------+
|  ┌────────────────────────────────────┐  |
|  │ ⌘ (Type a command…            ) esc│  |
|  │ ACTIONS on “apikey_253c…”          │  |
|  │▌Paste                        ↩     │  |
|  │  Paste as plain text        ⇧↩     │  |
|  │  Paste & keep open          ⌘↩     │  |
|  │  Pin                        ⌘P     │  |
|  │  Edit…                      ⌘E     │  |
|  │  Run script ▸                      │  |
|  └────────────────────────────────────┘  |
```
Default 720: palette 560 wide with a second group "Navigate" (History, Pinned, categories, Scripts…) and "Settings" results. Wide 1100: palette 560 centered, preview column dims (scrim 20%) and shows the target clip so actions are unambiguous. Opened with the search text `>`? no: Cmd+K always; typing `>` in search also opens it. Replaces the hidden context-menu-only actions.

### 4.5 Quick Look / preview column
Compact:
```
+------------------------------------------+
|   ┌──────────────────────────────────┐   |
|   │ [Paste] [Edit] [Copy]      [✕]   │   |  glass toolbar
|   │                                  │   |
|   │  full clip text, selectable,     │   |
|   │  mono for code …                 │   |
|   │  ░ or masked placeholder ░       │   |
|   └──────────────────────────────────┘   |
```
Default: same, max 640x420 floating over the list, list dimmed 30%. Wide: docked preview column (4.1) with the same content and a bottom action cluster; Space expands it to a full-height overlay for long text. Image: fit-to-width with `+`/`-`/`0`; dimensions/OCR toggle below.

### 4.6 Clip editor (separate window, replaces `ClipEditorView` chrome)
Window min 560x400, default 720x520, remembers frame.

Compact 420 (min-width window, inspector as sheet):
```
+------------------------------------------+
| Edit clip            [Cancel] [Save ⌘S]  |
|------------------------------------------|
| ┌──────────────────────────────────────┐ |
| │ editable text (mono toggle)          │ |
| │                                      │ |
| └──────────────────────────────────────┘ |
| [Aa] [{ }] [Find ⌘F] [AI ▾]  1,204 chars |
```
Default 720:
```
+----------------------------------------------------------------+
| Title (inline rename)             [Cancel]  [Save ⌘S]  [⋯]     |
|----------------------------------------------------------------|
| ┌────────────────────────────────────────────┐ INSPECTOR       |
| │ editable text, line numbers optional       │ Category  ▾     |
| │                                            │ Tags   +        |
| │                                            │ Source  Edge    |
| └────────────────────────────────────────────┘ Sensitive  ◻    |
| [Aa][{ }][Find][Transform ▾][AI ▾]   ln 3 col 8  UTF-8        |
+----------------------------------------------------------------+
```
Wide 1100: editor + inspector + a live "Result" diff/preview pane toggle (`Cmd+Opt+D`) for AI/script transforms. Rules: Cmd+S saves, Esc asks to discard only if dirty (two-stage), find/replace bar in-window, text view has AX label "Clip text" (A11Y-02).

### 4.7 Image editor
Compact (tool strip collapses to a bottom glass bar):
```
+------------------------------------------+
| Edit image           [Cancel]  [Save ⌘S] |
|   ┌────────────────────────────────┐     |
|   │            canvas              │     |
|   └────────────────────────────────┘     |
| [Crop][Rotate][Markup][Redact] ⟲ ⟳  100% |
```
Default 720:
```
+----------------------------------------------------------------+
| Edit image                      [Cancel]  [Save ⌘S] [Save as…] |
|------+---------------------------------------------------------|
| Tool |                                                         |
| ▢Crop|            canvas (checkerboard for alpha)              |
| ↻Rot |                                                         |
| ✎Mark|                                                         |
| ▧Redact                                                        |
| Text |   [Fit] [100%]  1,144×961                               |
+------+---------------------------------------------------------+
```
Wide 1100 adds a right inspector: size, format (PNG/HEIC/JPEG), quality, OCR text (editable), "Copy text". Redact is the compliance-relevant tool: solid opaque rectangles (no blur, blur is reversible), applied destructively on save with a confirm. Tool glass cluster in one `GlassEffectContainer`; canvas AX: labeled with an accessible crop-field alternative (numeric x/y/w/h fields in the inspector) (A11Y-02).

### 4.8 Settings (window; sidebar + search)
System `Settings`/window with `NavigationSplitView`, `.searchable`, min 640x460, default 780x560 (frame persisted).

Compact (<= 640: sidebar collapses to a popover pane list):
```
+------------------------------------------+
| [☰ General ▾]   (🔍 Search settings )    |
| APPEARANCE                               |
|  Theme                     [Match system▾]|
|  Density            [Rows|Comfort|Cards] |
|  Accent                      ● ● ● ● ●   |
```
Default 780:
```
+--------------+-------------------------------------------------+
| (🔍 Search)  | General                                         |
|▌General      |                                                 |
|  Appearance  | STARTUP                                         |
|  Shortcuts   |  Launch at login                        [ ● ]   |
|  Capture     |  Show in menu bar                       [ ● ]   |
|  Privacy     | HOTKEY                                          |
|  AI          |  Open Clippy            [ ⌘⇧V ]  [Record]       |
|  Scripts     |  Paste plain            [ ⌘⇧P ]  [Record]       |
|  Integrations| PANEL                                           |
|  Sync&Backup |  Position   [Cursor ▾]   Size  [Remember ▾]     |
|  Advanced    |                                  [Reset section]|
+--------------+-------------------------------------------------+
```
Wide 1100: content centered, max 640 wide, sidebar 220; live theme preview card at the right in Appearance (a mini panel rendered with current tokens). Panes: General, Appearance (theme, accent, density, font size, panel material w/ Reduce Transparency note), Shortcuts (recorders + conflict detection, PNL-09), Capture (ignored apps picker, size steps, sensitive patterns), Privacy (masking, screen-share protection, retention, clear history), AI (provider, model, key status), Scripts, Integrations (MCP port shown `.number.grouping(.never)`, install probes with timeouts, SET-03), Sync & Backup (iCloud state, export/import prefs), Advanced (log level Info default, SET-05). Search results show pane + row with highlight; per-pane "Reset" (SET-09). Replaces `SettingsView` (split into `Settings/*Pane.swift`).

### 4.9 AI Assistant
Compact:
```
+------------------------------------------+
| ✦ Assistant                     [⋯ New]  |
|                                          |
|        ✦   Ask about your clips          |
|  [Find meeting notes]  [Summarize today] |
|------------------------------------------|
| ▸ Context: 1 clip  [×]                   |
| ( Ask anything…                     ↑ )  |
```
Default 720: transcript centered max 620 wide; user bubbles right (`selection`), assistant left (no bubble, `body`); tool-call rows collapsed (`micro`, "Searched clips: 3 results ▸") showing counts only, never clip content, unless expanded by the user; context tray above the composer (attached clips as chips, masked if sensitive). Wide 1100: transcript + right "Context" column listing attached/related clips (preview-column component). Composer: `surfaceInset` capsule to rounded rect growing to 6 lines, Return sends, Shift+Return newline, Cmd+. stops. A "Data leaves this Mac" indicator (`network` glyph + provider name) is permanently visible in the header when a cloud provider is selected (compliance: it is the only screen that can send content off-device). Header search hidden here (KEY-09). Replaces the Assistant view under `Sources/Clippy/AI` UI plus the shared header.

### 4.10 AI Actions editor
Actions are prompt templates that run on a selected clip.

Compact: list only; tapping pushes editor (navigation stack, back = Esc).
```
| AI Actions                       [＋ New] |
| ✦ Summarize                    ⌘⌥1  ›   |
| ✦ Fix grammar                  ⌘⌥2  ›   |
| ✦ Translate → EN               —    ›   |
```
Default 720 (list + editor):
```
+---------------------+------------------------------------------+
| AI Actions   [＋]   | Name  (Summarize            )            |
|▌Summarize           | Icon  [✦▾]   Shortcut [Record]           |
|  Fix grammar        | Prompt                                   |
|  Translate → EN     | ┌──────────────────────────────────────┐ |
|                     | │ Summarize the following in 3 bullets: │ |
|                     | │ {{clip}}                              │ |
|                     | └──────────────────────────────────────┘ |
|                     | Output [Replace clip ▾]  Model [Default▾]|
|                     | Temp ──●───  0.3      Max tokens 512     |
|                     | [Test on selected clip]   [Delete] [Save]|
+---------------------+------------------------------------------+
```
Wide 1100: adds a right "Test" column with sample input and result. Titles use `textPrimary` (fix SET-01 dim grey). Placeholders `{{clip}}`, `{{app}}` are inserted via a chip menu, highlighted in the editor. Replaces the AI Actions section of the panel and Settings' nested scroller (SET-07).

### 4.11 Scripts (list + editor + output drawer)
Compact: list; editor pushes; output drawer is a bottom sheet (half height).
```
| Scripts                          [＋ New] |
| >_ Trim whitespace         zsh   ⌘⌥T   ▶ |
| >_ JSON prettify           node        ▶ |
```
Default 720:
```
+---------------------+------------------------------------------+
| Scripts   [＋]      | Name (Trim whitespace)  Lang [zsh▾]  [▶ Run ⌘↩]|
|▌Trim whitespace     | ┌──────────────────────────────────────┐ |
|  JSON prettify      | │ 1  #!/bin/zsh                        │ |
|                     | │ 2  pbpaste | sed 's/ *$//'           │ |
|                     | └──────────────────────────────────────┘ |
|                     | Input [Selected clip▾]  Output [Replace▾] |
|                     |------- OUTPUT  exit 0 · 43ms ▾  [Clear] --|
|                     | stdout: …                                |
+---------------------+------------------------------------------+
```
Wide 1100: list 220 | editor | output docked right (side-by-side) instead of the bottom drawer. Editor uses `mono`; text colors from tokens so the inactive-window near-black-on-grey bug (SET-01) cannot occur (`textPrimary`, never `NSColor.textColor` literals on custom backgrounds). Run states: idle / running (stop button, spinner) / done (exit code chip: success/danger) / timed out. Output shows only script output; input clip content is never logged. Replaces `ScriptsView`, `ScriptsPanelView`.

### 4.12 1Password view
Compact:
```
| 🔑 1Password                 (● Connected)|
| ( Search vault…                        ) |
| 🔒 GitHub           jerry@…        ⌘1   |
| 🔒 Azure Portal     admin@…        ⌘2   |
```
Default 720:
```
+---------------------+------------------------------------------+
| ( Search items )    | GitHub                                    |
| [All][Logins][Notes]|  Username   jerry@…             [Copy]   |
|▌GitHub              |  Password   ●●●●●●●●●●●         [Copy]   |
|  Azure Portal       |  Website    github.com          [Open]   |
|  Plaid              |  Copies clear in 30s (clipboard-transient)|
+---------------------+------------------------------------------+
```
Wide 1100: list | detail | field-history. Rules: fields masked (`masked` capsules) by default; secrets never enter History (copy uses transient pasteboard type, CapturePaste); a persistent header state pill: Connected / Locked (Touch ID) / Not installed with one action; "auto-clears in 30s" countdown ring on the toast. The header search binds to the vault here, not to clips. Replaces `OnePasswordView`.

### 4.13 Onboarding / permissions first run
One window, 520x440 fixed (centered), 4 steps, each shows what/why, one primary button, a "Skip for now" that leaves a persistent banner (3.8) until done. Compact/default/wide is identical (fixed size window); at panel-width contexts the permission banner appears in the panel instead.

Step layout (all widths):
```
+------------------------------------------+
|                 (hero glyph 56)          |
|        Welcome to Clippy                 |
|   Your clipboard, searchable and safe.   |
|                                          |
|   ●───○───○───○                          |
|                                          |
|            [ Continue ]                  |
+------------------------------------------+
```
Steps: 1 Welcome (what is stored: local only; "Nothing leaves this Mac unless you use AI or iCloud"), 2 Accessibility (needed to paste; live status, `[Open System Settings]`, auto-advance when granted, request-then-verify loop; shows the exact app path), 3 Hotkey (recorder, default Cmd+Shift+V, test button "Try it"), 4 Privacy defaults (masking on, ignore password managers preset list, retention 30 days, screen-share protection) and "Start". Also handles "Launch at login" (approval state, SET-06). Never blocks the app: without Accessibility it degrades to copy-only with a banner.

---

## 5. Interaction and keyboard model

### 5.1 Focus map
Regions, in Tab order: **Search field** -> **Filter chips** -> **Sidebar** -> **List** -> **Preview column** -> **Footer actions**. Shift+Tab reverses. The panel opens with focus in **Search** (type-to-search) and arrow keys work from Search (Up/Down move the list cursor without leaving the field; Left/Right move the caret) - this preserves the fastest path while fixing KEY-06 by making the *list* a real focus target (`.focusable()`, `@FocusState var focus: Region?`, `onKeyPress`). Clicking a row focuses the List (does not steal back to Search); typing any printable character while List is focused moves focus to Search and inserts the character. `Cmd+F` or `/` focuses Search. Sidebar rows navigate with Up/Down, Return opens, Right arrow moves into List, Left from List moves to Sidebar, `F2`/Return-on-selected renames.

### 5.2 Shortcuts

| Keys | Context | Action |
|---|---|---|
| Cmd+Shift+V (configurable) | global | toggle panel (PNL-09 adds recorder + extra hotkeys) |
| Return | list/search, clip selected | Paste (default behavior selectable in Settings: formatted or plain; hint bar always states which) |
| Shift+Return | list | Paste with the opposite of the default (plain if default is formatted); labelled "plain" or "formatted" accordingly (fixes mislabelled footer) |
| Cmd+Return | list | Paste and keep panel open (stack pasting) |
| Cmd+1 ... Cmd+9 | panel open | Paste the Nth visible row (Paste-app convention, [Paste help](https://pasteapp.io/help/keyboard-shortcuts)); badges show while Cmd held and always in Comfortable |
| Cmd+Shift+1 ... 9 | panel open | Paste Nth as plain text (same convention) |
| Space | list | Quick Look toggle |
| Cmd+K | anywhere | Command palette on selection |
| Up/Down, Left/Right | list | 2D navigation in grid; Left/Right in rows collapse/expand nothing (no-op) |
| Home / End / PageUp / PageDown | list | jump (KEY-03) |
| Cmd+Up/Down | list | jump to top/bottom section header |
| Cmd+F or / | anywhere | focus search |
| Cmd+A | list focused: select all visible; search focused with text: select query text (KEY-05) |
| Cmd+C | list | Copy selected to clipboard without pasting (KEY-11); flags "self-copy" so it does not duplicate the history entry |
| Cmd+E | list | Edit clip |
| Cmd+P | list | Pin/unpin (moves to Cmd+Shift+P if Cmd+P conflicts with system Print in editors; in the panel Cmd+P remains pin) |
| Cmd+Delete | list | Delete selected; toast with Undo (Cmd+Z restores within 30s) |
| Cmd+Z / Cmd+Shift+Z | panel | Undo/redo last delete, reorder, category edit (SBR-06) |
| Cmd+R | list, masked row | Reveal/re-mask sensitive |
| Option (hold) | list | Peek sensitive row |
| Cmd+Ctrl+S | panel | Toggle sidebar / rail |
| Cmd+Ctrl+P | wide | Toggle preview column |
| Cmd+, | app | Settings |
| Cmd+Shift+P | panel | Pin panel (stay open when focus moves) |
| Cmd+[ / Cmd+] | panel | Previous/next section (History, Pinned, categories, Tools) |
| Esc | see 5.3 | |

### 5.3 Esc (two-stage, extended)
Order of unwinding, one step per press: (1) close open menu/popover/palette, (2) close Quick Look, (3) clear the multi-selection back to single cursor, (4) clear the search query and filter chips (PNL-11), (5) if in a non-History section, return to History, (6) hide the panel. Focus returns to the previous region at each step. In editors: Esc closes find bar, then asks to discard only if dirty, then closes.

### 5.4 Multi-select semantics
Anchor + cursor model (Finder-style, KEY-04): click = single; Cmd+click toggles; Shift+click/Shift+Arrow extends from the anchor to the cursor (range can shrink); Cmd+A selects all visible. With >= 2 selected, a glass **selection bar** appears (count, [Paste all in order joined by newline], [Copy], [Category ▾], [Pin], [Delete]) and the hint bar switches to batch actions. Right-click on an unselected row selects it first; on a selected row keeps the selection (KEY-07). Paste of multiple: Return pastes items in on-screen order (top to bottom) joined by the user setting (newline default) as one paste; `Cmd+Return` pastes sequentially one per press ("paste stack", queued indicator in the footer). Sensitive clips in a multi-select require reveal or explicit confirm ("Paste 1 sensitive clip?") before joining.

### 5.5 Drag and drop rules
- Drag out (`.draggable`, KEY-11): row = text/RTF/file URL/image payload per kind; sensitive masked rows drag nothing until revealed; drag preview is a 240x32 chip showing kind glyph + "3 clips" (never content when masked).
- Drop on a sidebar category = **file into** (accent 2pt inset ring on row + "Move 3 clips to prompts" label); drop on History = unfile; drop *between* category rows = **reorder** only when the dragged item is a category (2pt insertion line). The two never share an indicator (SBR-05).
- Drop of files/images/text onto the list area = create clips (accent inset dashed 2pt border around the list + "Drop to add"). Drop of text onto an AI Action row = run that action on it.
- Modifier: Option-drag copies (file into a category without removing from History if multi-category is on); Escape cancels.
- Auto-scroll at 32pt edges of the list; spring-loaded (hover 600ms) opens collapsed sidebar categories.

---

## 6. Themes

### 6.1 Token model
`ThemeTokens` (existing: `panel, scrollBackground, cardSurface, cardBorder, headerBar, footerBar, sidebar, scrollbar, textPrimary, textSecondary, accent, success, danger, isDark`) stays as the *storage* format so `ThemePreset` cases, custom color wells and saved settings keep working. The new semantic layer `ClippyTokens` is derived from it by a pure function `ClippyTokens.resolve(from: ThemeTokens, contrast: ColorSchemeContrast)`; views read only `ClippyTokens`.

| Semantic token | Derived from `ThemeTokens` |
|---|---|
| `surface` | `scrollBackground` |
| `surfaceElevated` | `cardSurface` |
| `surfaceInset` | `panel` darkened (dark) / `panel` blended 4% black (light) - `mix(panel, isDark ? .black : .black, 0.20 / 0.06)` |
| `surfaceSidebar` | `sidebar` |
| `stroke` | `cardBorder` |
| `strokeStrong` | `textSecondary` at 55% opacity blended over `surface`, then forced to >= 3:1 vs `surface` by `Contrast.adjust` |
| `textPrimary` / `textSecondary` | same names |
| `textTertiary` | `mix(textSecondary, surface, 0.25)` then `Contrast.adjust(min: 4.5)` |
| `accent` | `accent` |
| `accentText` | `Contrast.adjust(accent, against: surfaceElevated, min: 4.5)` (darkens or lightens accent until it passes) |
| `onAccent` | black or white, whichever has higher contrast against `accent` |
| `selection` | `mix(surface, accent, isDark ? 0.22 : 0.16)` |
| `success` / `danger` | same; `warning` new = `Contrast`-adjusted amber |
| `kind.*` | fixed hues from 2.7, passed through `Contrast.adjust(min: 4.5)` against `surfaceElevated` per theme |
| `headerBar`, `footerBar` | folded into the panel backdrop (no separate bars); tokens retained for Custom compatibility and ignored unless `custom` |

`Contrast.adjust` guarantees AA for every preset, resolving SET-01 systematically: a theme cannot ship a failing pair because derived colors are corrected at resolve time; a unit test iterates every `ThemePreset` x {text, accentText, kind hues} and asserts >= 4.5.

### 6.2 Presets

| Preset (unchanged names) | Mapping notes |
|---|---|
| `.system` | Resolves to the **Clippy default** table below, light or dark by `effectiveAppearance`; cache invalidated on appearance change (SET-08) |
| `.cleanLight` | Existing GitHub-light palette. `surface #F6F8FA`, `surfaceElevated #FFFFFF`, accent #0969DA (already AA as text: `accentText` = accent) |
| `.githubDark` | `surface #0D1117`, elevated `#161B22`, accent #2F81F7 (text-adjusted to ~#58A6FF) |
| `.dracula` | `surface #21222C`, elevated `#343746`; accent #BD93F9 (passes on elevated) |
| `.materialDarkPlus` | surface `#121212`, elevated `#1E1E1E`, accent #03DAC6; `onAccent` black |
| `.nord`, `.oneDark`, `.tokyoNight`, `.solarizedDark` | direct mapping of existing tables; `surfaceInset`/`selection` derived; `Solarized` tertiary text is the likeliest to be lifted by `Contrast.adjust` (base01 on base03 is ~3.7:1 in the stock palette) `[INFERENCE, verify in the unit test]` |
| `.custom` | Per-token color wells remain; only base tokens editable (`panel`, `scrollBackground`, `cardSurface`, `cardBorder`, `sidebar`, `textPrimary`, `textSecondary`, `accent`, `success`, `danger`, `isDark`); derived tokens are computed; a live contrast checker badge next to each well ("AA ✓ 7.2" / "Fails 3.1: adjusted automatically"). `customIsDark` gets a real toggle (SET-08) |

Fixed-palette presets: glass is still used for the control layer, tinted neutral (no theme tint on glass); their `panel` becomes the fallback color when Reduce Transparency is on. `AccentTheme` (clippyAmber, system, blue... graphite) overrides `accent` only when the preset is `.system`; fixed presets keep their own accent unless the user chooses "Use my accent" (the amber override currently beats preset accents by default, SET-08). `CardStyle`/`CardColorMode` collapse into the density control; `Bordered`/`Plain`/etc. legacy values map to Cards density with `stroke` variants and are migrated on load. `PanelMaterialStyle` maps to backdrop: glass (default), vibrancy(`.hudWindow`), solid.

### 6.3 Default theme proposal: "Clippy" (Match system)
- Backdrop glass on macOS 26; neutrals from 2.7 (Apple-gray family: #F5F5F7/#1C1C1E), amber accent kept (brand continuity, `clippyAmber` #E0A23C fills; `accentText` #7A4E00 / #F2BC55 for text).
- Density Compact; sidebar expanded above 520; preview column auto at >= 900.
- Default panel size 720x520 (position: near cursor, clamped, per-display memory, PNL-06); minimum 360x320.
- Font: system, 13pt body.
- Sensitive masking on; screen-share protection on.

---

## 7. Implementation map

Priority order: design-system module first, then screens; each screen migration is independently shippable behind the density/legacy setting until removed.

### 7.1 Design-system module (`Sources/Clippy/DesignSystem/`), build first
Proposed Swift API (names and signatures, not implementations):

```swift
// Tokens
struct ClippyTokens: Equatable {
    var surface, surfaceElevated, surfaceInset, surfaceSidebar: Color
    var stroke, strokeStrong: Color
    var textPrimary, textSecondary, textTertiary: Color
    var accent, accentText, onAccent, selection: Color
    var success, warning, danger, masked: Color
    var kind: (ClipKindStyle) -> Color
    static func resolve(from t: ThemeTokens, contrast: ColorSchemeContrast) -> ClippyTokens
}
extension EnvironmentValues { var clippyTokens: ClippyTokens { get set } }

enum Contrast {
    static func ratio(_ a: Color, _ b: Color) -> Double
    static func adjust(_ fg: Color, against bg: Color, min: Double) -> Color
}

enum Radius { static let xs: CGFloat = 4, sm = 8, md = 12, lg = 16, xl = 24 }
enum Space  { static let s1: CGFloat = 4, s2 = 8, s3 = 12, s4 = 16, s5 = 20, s6 = 24, s8 = 32 }
enum RowHeight { static func compact(_ scale: CGFloat) -> CGFloat; static let comfortable: CGFloat = 56 }

enum Motion {
    static let instant: Animation, quick: Animation, standard: Animation, toast: Animation
    static func animation(_ a: Animation, reduce: Bool) -> Animation?
}
enum ClippyFont { static func role(_ r: TextRole, settings: AppSettings) -> Font }   // replaces PanelTypography
enum TextRole { case title, body, bodyEmphasis, meta, micro, mono, display }

// Materials
struct ClippyGlass: ViewModifier {                      // glass / material / solid fallback
    init<S: Shape>(shape: S, interactive: Bool = false, tint: Color? = nil)
}
extension View { func clippyGlass<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View }
struct ClippyGlassGroup<Content: View>: View { init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) }  // wraps GlassEffectContainer
struct PanelBackdrop: View                               // window-level glass/vibrancy/solid
struct FocusRing: ViewModifier                           // 2pt accent ring, radius-aware

// Components
struct ClippySearchField: View            { init(text: Binding<String>, prompt: LocalizedStringKey, scope: SearchScope?, onArrow: (ArrowKey) -> Void) }
struct FilterChip: View                   { init(_ title: String, glyph: String?, count: Int?, isOn: Binding<Bool>) }
struct FilterChipRow: View                { init(filters: Binding<Set<ClipFilter>>) }
struct KeyCap: View                       { init(_ keys: String) }
struct HintBar: View                      { init(hints: [Hint]) }                 // context-driven footer
struct Toast: Identifiable                { enum Style { case success, warning, danger }; var message: String; var action: (title: String, run: () -> Void)? }
struct ToastHost: View                    { init(queue: ToastQueue) }
struct Banner: View                       { init(style: Toast.Style, message: String, action: (String, () -> Void)?, onDismiss: (() -> Void)?) }
struct EmptyState: View                   { init(glyph: String, title: LocalizedStringKey, message: LocalizedStringKey, action: (String, () -> Void)?) }
struct SkeletonRows: View                 { init(count: Int = 3) }
struct SettingsSection<Content: View>: View { init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) }
struct SettingsRow<Control: View>: View   { init(_ title: LocalizedStringKey, description: LocalizedStringKey?, keywords: [String], @ViewBuilder control: () -> Control) }
struct ClippyPalette<Item: PaletteItem>: View { init(items: [Item], query: Binding<String>, onRun: (Item) -> Void, onDismiss: () -> Void) }
protocol PaletteItem: Identifiable { var title: String { get }; var section: String { get }; var shortcut: String? { get }; var glyph: String { get } }

// Clip presentation (value types; no AppSettings observation, LAY-12)
struct ClipRowModel: Identifiable, Equatable {
    var id: Int64; var kind: ClipKindStyle; var title: String; var isSensitive: Bool; var isPinned: Bool
    var appName: String?; var appIconKey: String?; var createdAt: Date; var categoryIDs: [Int64]; var thumbnailKey: String?
    var quickPasteIndex: Int?
}
enum ClipKindStyle: CaseIterable { case text, link, email, image, file, color, code }   // maps from ClipKind (+code detector)
struct ClipRow: View       { init(model: ClipRowModel, density: Density, isSelected: Bool, isCursor: Bool, actions: ClipRowActions) }
struct ClipCard: View      { init(model: ClipRowModel, isSelected: Bool, isCursor: Bool, actions: ClipRowActions) }
struct ClipPreview: View   { init(model: ClipRowModel, style: PreviewStyle) }            // Row / Card / Column / QuickLook
struct MaskedClip: View    { init(reveal: Binding<Bool>) }
struct ReasonChip: View    { init(reason: SuggestionReason) }
struct SelectionBar: View  { init(count: Int, actions: SelectionActions) }
struct SidebarRail: View   { init(items: [SidebarItem], selection: Binding<SidebarSelection>) }
struct SidebarList: View   { init(items: [SidebarItem], selection: Binding<SidebarSelection>, width: Binding<CGFloat>) }
struct SplitGrabber: View  { init(width: Binding<CGFloat>, range: ClosedRange<CGFloat>, onReset: () -> Void) }
struct QuickLookPanel: View{ init(clip: ClipRowModel?, isRevealed: Binding<Bool>, onClose: () -> Void) }
enum Density: String, CaseIterable { case compact, comfortable, cards }
```

### 7.2 Replacement map (existing code -> new)

| Priority | Existing | Replaced by / action | Roadmap IDs closed |
|---|---|---|---|
| P0 | `Support/Theme.swift` (`PanelTypography`, `PanelMaterialStyle`), `ThemedBackground.swift`, `ThemePreset.swift` | `DesignSystem/{Tokens,Contrast,Typography,Motion,Glass}.swift`; `ThemeTokens` retained as storage, `ThemePreset` unchanged | LAY-13, LAY-14, SET-01, SET-08, A11Y-03 |
| P0 | `PanelHeaderView.swift` | `PanelHeader` + `ClippySearchField` + `FilterChipRow` (drag region) | PNL-01, PNL-12, KEY-08 (chips), KEY-09 |
| P0 | `ClipCardView.swift` (881 lines) | `ClipRow`, `ClipCard`, `ClipPreview`, `MaskedClip`, `ClipRowModel` | LAY-01..03, LAY-06..10, LAY-12, A11Y-01 |
| P0 | `ClipListView.swift` (1595 lines) | `HistoryView` (list + grid), keyboard focus model (`PanelFocus`), `SelectionModel` (anchor+cursor), hint bar | LAY-02/04/05/08, KEY-01..07, KEY-10, PNL-03 |
| P1 | `CategorySidePane.swift`, `CategoryEditorView.swift` | `SidebarList`, `SidebarRail`, `SplitGrabber` | SBR-01, 02, 03, 05, 06, A11Y-02 |
| P1 | `PanelSelection.swift`, `ReorderableForEach.swift` | `SelectionModel`; keep reorder logic but with distinct file/reorder indicators | KEY-04, SBR-05 |
| P1 | `SuggestionsPaneView.swift` | `SuggestionsSection` using `ClipRow` + `ReasonChip` | ROADMAP 18 |
| P1 | new | `ClippyPalette` (Cmd+K), `QuickLookPanel`, preview column, `ToastHost`, `Banner` | LAY-11, KEY-11 |
| P2 | `SettingsView.swift` (1828 lines) | `Settings/SettingsWindow` + `*Pane.swift` + `SettingsRow/Section`, search index | SET-02..09 |
| P2 | `ClipEditorView.swift`, `ImageEditing.swift` | Editor shell (inspector, find bar, dirty-Esc), image editor tool rail (crop/rotate/markup/redact) | A11Y-02, EDT-* |
| P2 | `ScriptsView.swift`, `ScriptsPanelView.swift`, `PlainTextEditor.swift` | Scripts split view + output drawer using tokens for editor colors | SET-01 (scripts), KEY-09 |
| P2 | AI assistant / AI Actions views (`Sources/Clippy/AI/`) | Assistant transcript + composer, actions master-detail | SET-01, SET-07 |
| P2 | `OnePasswordView.swift` | Vault list/detail with masked fields | KEY-09 |
| P3 | Onboarding (new), permission banners | `OnboardingWindow`, `Banner` wiring | PNL-09 |
| P3 | `PanelController.swift` / `AppDelegate` window setup | `.titled`+`fullSizeContentView` hidden titlebar, level policy, per-display frames | PNL-02, 05, 06, 07, 08 |

### 7.3 Ownership boundaries for this repo's task split
`SplitList` (ClipListView + `UI/ClipList/`), `SplitCard` (ClipCardView + `UI/Card/`), `SplitSettings` (`SettingsView` + `UI/Settings/` + `AppSettings`) can build against `DesignSystem/` only after it lands; the design-system files need an owner not listed in the current batch map (new folder `Sources/Clippy/DesignSystem/`). New persisted settings implied by this brief (owner: SplitSettings): `density`, `sidebarWidth`, `sidebarCollapsed`, `previewColumnVisible`, `maskSensitive`, `screenShareProtection`, `pasteDefaultPlain`, `hotkeys.*`, `accentOverridesPreset`.

### 7.4 Open questions (need owner decision)
1. Set `NSWindow.sharingType = .none` on the panel when sensitive clips are visible? (Recommended; breaks screen-share/screenshot of the panel.)
2. Minimum deployment target: glass APIs need macOS 26; the brief provides a material fallback, but confirm the older-OS floor.
3. Link favicons/titles require network. Default off, opt-in only (compliance).
4. Default Return behavior: formatted or plain? Brief keeps the current behavior of Shift+Return as the alternate; confirm which is the default.

---

## 8. Reference gaps (pull from Mobbin once access exists)

Search terms and apps, grouped by the screen that needs them. Priority in brackets.

| Screen / pattern | Mobbin search terms | Apps to pull |
|---|---|---|
| [P0] Clipboard list rows & previews (macOS) | "clipboard history", "command palette list", "search list with keyboard hints" | Raycast (Clipboard History), Paste, Maccy, Pastebot, Alfred (Clipboard Viewer), CleanShot X (history) |
| [P0] Command palette overlay | "command palette", "command menu", "action panel", "cmd k" | Linear, Raycast, Arc, Notion, Superhuman, Craft, Things 3 (Quick Entry) |
| [P0] Filter chips + search grammar | "filter chips", "search filters", "tokenized search field", "saved searches" | Linear (filters), Apple Mail (macOS 26 search tokens), Finder, Notion, Bear |
| [P1] Sidebar: expanded + icon rail, drag reorder, counts | "sidebar navigation collapsed", "icon rail", "sidebar with counts", "drag to reorder list" | Things 3, Bear, Craft, Linear, Apple Notes, Arc |
| [P1] Preview column / Quick Look | "preview pane", "inspector panel", "quick look" | Finder (macOS 26), Raycast, Pastebot, Apple Photos |
| [P1] Sensitive / masked content | "password field masked", "reveal secret", "hide sensitive", "copy secret with auto-clear" | 1Password, Bitwarden, Apple Passwords (macOS 15+), Proton Pass |
| [P1] Settings with sidebar + search | "settings window", "preferences search", "settings sections", "toggle rows" | macOS 26 System Settings, Raycast, Arc, Linear, Things 3 |
| [P1] Onboarding / permission flow (macOS) | "permission request onboarding", "accessibility permission", "welcome step flow", "first run" | Raycast, CleanShot X, Bartender, Rectangle, Loom, 1Password |
| [P2] AI Assistant chat + composer, tool-call rows | "AI chat", "chat composer", "context attachments", "tool call disclosure" | Raycast AI, Notion AI, Claude (macOS), ChatGPT (macOS), Cursor |
| [P2] AI action / prompt template editor | "prompt editor", "custom prompt", "template variables" | Raycast AI Commands, Notion AI, Craft AI |
| [P2] Scripts editor + output drawer | "code editor", "terminal output panel", "run script button" | Raycast Script Commands, Shortcuts (macOS), Xcode Playgrounds, Nova |
| [P2] Image editor tool rail (crop/markup/redact) | "image editor toolbar", "markup tools", "crop overlay", "redact" | CleanShot X, Preview.app markup, Pixelmator, Apple Photos |
| [P2] Toast / banner / undo | "toast notification", "undo snackbar", "inline banner warning" | Linear, Things 3, Apple Mail (Undo Send), Notion |
| [P3] Empty / loading / error states | "empty state", "skeleton loading", "error state" | Linear, Notion, Raycast, Arc |
| [P3] Liquid Glass in practice on macOS 26 | "macOS 26 Tahoe", "Liquid Glass toolbar", "glass sidebar" | Apple first-party apps on macOS 26 (Finder, Notes, Safari, Music), early adopters (Things 3, Bear, Craft, Raycast) |
| [P3] Hotkey recorder + conflict UI | "keyboard shortcut recorder", "shortcut conflict" | Raycast, Alfred, Rectangle, Paste |

Not verified this session (to confirm when the library is available): which of the apps above actually ship the listed patterns; the exact glass treatment in third-party apps on macOS 26; Paste's current default Quick Look and preview behaviors beyond the shortcut page.
