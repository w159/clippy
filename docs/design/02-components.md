# 02 - Component Specifications

Companion: [`01-principles-and-tokens.md`](01-principles-and-tokens.md). These are design-system contracts for the macOS 26 SwiftUI redesign; they do not claim that the components are already implemented. **[INFERENCE]** marks proposed implementation detail without direct project/runtime evidence.

## Shared state contract

Interactive controls provide these states consistently; semantics belong to the action and control type, not merely color.

| State | Visual treatment | Interaction / accessibility |
|---|---|---|
| Rest | Solid content surfaces or single functional glass layer; neutral glyphs | Default AX role/name/value; tab stop only for actionable controls |
| Hover | `hover` fill or system glass `.interactive()` response; 80ms | Pointer affordance appears without covering content; no state change |
| Pressed | Stronger fill / native pressed feedback; 80ms | Action triggers once on release; provide button role |
| Selected | `selection` + accent leading bar for list rows; selected chip has semantic selected trait | `accessibilityAddTraits(.isSelected)`; selection persists when focus moves |
| Focused | 2pt visible accent focus ring, not clipped | Keyboard action and focus order clear; do not move focus just because pointer clicks |
| Disabled | Non-interactive subdued fill/glyph; label stays legible | `.disabled(true)` plus reason/help text where actionable; VoiceOver says “Dimmed” |

Shared constants come from `ClippyTokens` (signature in section “Shared design-system API” below). Avoid hard-coding parallel radii, color values, or animation durations in view bodies.

## Panel shell, header, and search

**Anatomy and dimensions.** Window shell with 24pt corner radius, system window shadow and a glass/system backdrop; inner content laid out as header, optional filter bar, content columns and a context-sensitive shortcut footer. Header is 48pt high: search field grows to available width; trailing density/overflow controls remain in fixed-width group. Search field is 32pt high, solid `surfaceInset`, capsule radius, `magnifyingglass` leading, clear button only when nonempty. Search is section-scoped; hide/replace it where it has no function (ROADMAP KEY-09). Footer is 32pt, not glass, with shortcuts for the active focus/selection state.

**States.** Rest: placeholder and `⌘F` hint; hover: subtle inset border; pressed: clear/toolbar actions get native response; selected: not applicable to shell (active filter selection belongs to chips); focused: 2pt field ring and insertion cursor; disabled: hide search entirely on sections without search rather than display a dead field. Shell busy state may show a small progress indicator beside the search field; do not disable search.

**Behavior and SwiftUI.** Header drag region excludes all controls; mark window AX title “Clippy”. Keep one panel/list alive when showing while visible; focus search instead of rebuilding (PNL-01/04/12). Size min derives from sidebar rail + content minimum; clamp on display changes, never set an arbitrary 280pt min (PNL-03/06). Prefer AppKit panel window shadow over clipped SwiftUI shadow. Use `safeAreaBar`/scroll-edge effects only where content actually scrolls beneath controls. The shell may use the system glass backdrop, but the text field itself stays solid. **[INFERENCE]** The shell has no custom traffic-light or title bar controls; use current app's panel controller integration.

## Filter chips

**Anatomy and size.** Horizontal scroll row, 32pt chip height, 8pt gap, 10pt horizontal inset. Optional 12pt leading symbol, one-line label, optional count. The group uses one `GlassEffectContainer(spacing: 8)` and one `.glassEffect(.regular, in: Capsule())` per chip.

**States.** Rest: regular glass; hover: `.interactive()` / system response; pressed: system response; selected: semantic selected trait, subtle accent tint and `accentText`, never color-only check; focused: focus ring and arrow-key navigation; disabled: subdued, remains labeled and nonselectable. Filter expansion state exposes `accessibilityValue` (“3 filters active”).

**Behavior.** Kind/app/date/category filters update the query grammar and scrolling results; chip selection must not create an independent filter state that drifts from query text (KEY-08). Multi-select semantics are AND across groups, OR within a group, matching the shared design brief. Content labels include All, Text, Links, Images, Files, Code, Colors, Pinned, Today, App… and Sensitive. [INFERENCE: exact query grammar and chip set remain coordinated with search implementation.]

## Clip row (compact, 32pt)

**Anatomy.** 32pt default min height: 2pt selected leading bar; 16pt kind glyph or 24pt square preview; one-line content title; flexible gap; trailing source app icon and nonwrapping timestamp. 8pt horizontal padding; 4pt row gap. Title/content leads; source app name is not the headline (LAY-07). Timestamp uses `.fixedSize(horizontal: true, vertical: false)`, one line and higher layout priority (LAY-03). At narrow widths, remove optional category chip then app icon before truncating title; never overlay actions across text (LAY-06).

**States.** Rest: content and metadata; hover: row fill plus actions crossfade into trailing slot; pressed: transient fill; selected: selected surface + 2pt bar; focused: visible focus ring and current cursor highlight; disabled/unavailable: dimmed reason, no paste action. Pending paste: trailing spinner and “Pasting…” AX value. Sensitive: masked variant below.

**Behavior and SwiftUI.** Value model, `Equatable`, no `AppSettings.shared` observation from each row (LAY-12). Use `LazyVStack` and stable clip IDs; list owns 2D keyboard navigation, range anchor/cursor and focus. Combine row AX children and provide named Paste/Pin/Edit/Delete actions (A11Y-01), do not ignore action buttons. Density row is 32pt at standard text scale and grows when Dynamic Type needs extra lines. **[INFERENCE]** `ClipRow` should be one reusable public design-system component, with paste/action callbacks injected rather than reaching into stores.

## Comfortable clip card

**Anatomy and size.** Two-line row variant at 56pt min height; card density uses adaptive 180–260pt width, 96–200pt height, 8pt grid gap, 12pt inset. The content preview leads; metadata footer contains source app/time/pin. Images use aspect-fit within 16:10 (no crop/upscale); code uses monospaced text. A small kind accent marker may identify type, but the card border/stroke belongs to selection only (LAY-09).

**States.** Rest: solid `surfaceElevated`, 1pt `stroke` only if needed for separation; hover: actions replace metadata in footer, never overlay preview; pressed: card surface response; selected: accent inner stroke/fill, distinct from focus; focused: 2pt outer ring; disabled: visible unavailable label with disabled actions. Masked cards never render text/image preview. **[INFERENCE]** Cards density remains optional while compact list is default.

**Behavior and SwiftUI.** Use adaptive grid computed from real chrome minimums, not fixed user column count; “Auto” default increases columns as window grows (LAY-02/05). Provide `.accessibilityElement(children: .combine)` with named actions. Avoid per-card environment/settings subscriptions.

## Clip previews by kind

Previews share the six interaction states above when interactive; passive content previews do not add hover/pressed affordances, while their containing row/card carries selected/focused/disabled state. Always expose content kind and safe metadata via accessibility text. All previews stay on solid surfaces.

| Preview | Anatomy / size | Behavior / SwiftUI notes |
|---|---|---|
| Image | 24pt square row thumb; 16:10 card image area with consistent max height; checkerboard for alpha, otherwise `surfaceInset` | Aspect-fit only; preserve alpha format (LAY-10). Use cached thumbnail; full-resolution display deferred to Quick Look. Label dimensions/type/size without reading image content. |
| File | 24pt system file icon + filename (middle truncation) + optional parent path and size | Use `NSWorkspace` file icon; report moved/unavailable file with `warning` glyph and text. Avoid implying local file exists if URL is stale. **[INFERENCE]** file-open affordance is context menu / Quick Look, not automatic open. |
| Link | 16pt favicon (only if user enables previews) + title/host, one-line each | No network fetch by default; display host safely. Non-HTTPS scheme gets explicit scheme warning, never a misleading secure badge. |
| Color | 20pt swatch, 1pt border, `radius.xs`, monospaced hex | Text label includes hex; click copies color code; swatch itself is not the only representation. |
| Code | First 1 line row / 2 lines card in 12pt monospaced face, optional language chip | No syntax color in dense list; preview/editor may offer it. Truncate safely; never run or interpret captured code. |

## Sensitive-clip masked state

**Anatomy and dimensions.** In any row/card/preview surface, replace the original content with a lock glyph, “Sensitive” label, neutral opaque mask block and safe time/source metadata only. Use a solid high-contrast backing, never glass or a blurred-but-readable fragment. Exact block sizing follows the row/card geometry.

**States.** Rest: masked placeholder; hover: reveal affordance appears but not content; pressed: only activate explicit reveal; selected: normal selected/focus treatment with masked placeholder intact; focused: announce “Sensitive clip” and keyboard instructions, never content; disabled: if reveal is blocked, state why without exposing data. Revealed-on-intent state is temporary and visually announced, then remasks on timeout/panel hide.

**Security contract.** Masked value must not leak into Quick Look, accessibility value/label, toast/banner, logger, drag, screenshot capture, or command palette. Paste remains possible because paste is explicit intent; revealing is separate from copying/exporting. **[INFERENCE]** Option-hold or Cmd+R reveal mechanics and timeout must match the existing security model before implementation; do not invent/store plaintext in presentation state.

## Reason chip

**Anatomy and size.** 20–24pt capsule, 8pt horizontal inset, optional 10pt leading symbol, concise one-line rationale (“Skipped: secure field”, “Sensitive app ignored”, “OCR unavailable”). Neutral `surfaceInset` and `textSecondary`; no primary-accent treatment.

**States.** Rest: caption text and reason glyph; hover: help popover explains policy and available next step; pressed: only if the chip offers an action; selected: not applicable unless filtering by reason, then selected trait; focused: ring and keyboard-open popover; disabled: show reason but disable remediation when permission/policy prevents it. Always provide text with icon; never color alone.

**Behavior.** UI text comes from typed reason enum/localized string, not raw exception or clipboard content. May occur on a clip, status banner or OCR/capture operation. **[INFERENCE]** Keep reason codes structured in the owning feature; the design component receives already-safe display text.

## Toast and banner

**Toast.** 36pt capsule, max 360pt wide, floating just above footer; glass belongs to the transient notification layer, not the clip content. Leading semantic glyph, one-line safe message, optional trailing Undo/action. Status, not clip contents: “Copied”, “Deleted 3 clips”, never copied text. Success auto-dismisses after 3s; actionable toast stays 6s and pauses while hovered. **[INFERENCE]** Durations are product defaults; respect VoiceOver announcement and do not auto-dismiss while VoiceOver focus is on the action.

States: rest = visible message; hover = pause timer; pressed = action activates once; selected = not applicable; focused = action has visible ring and works by Return; disabled = omit or explain disabled action instead of presenting dead button. Use `AccessibilityNotification.Announcement` for state change.

**Banner.** Full-width 40pt directly below header for persistent permission/error status, solid semantic tint at low opacity over `surface`, glyph + sentence + one action. Blocking banner cannot be dismissed until fixed; nonblocking can be dismissed. Hover/pressed/focused states apply to its action; disabled action carries cause in AX help. No sensitive values in message/details.
States: rest shows the persistent cause and action; hover/pressed/focused apply to its action; selected is not applicable; disabled action keeps its explanation accessible.

## Empty, loading, and error states

Centered stack in the content area; preserve the shell/search and keep keyboard navigation predictable. **Empty**: 40pt hierarchical glyph, one-line title, up to two lines of guidance, at most one primary action. Variants: no clips (“Nothing copied yet”), no search result (“No matches”; Clear filters), empty category (move/file explanation). **Loading**: stable row/card skeletons reflecting chosen density; avoid shimmer with Reduce Motion and never show spinner for work that finishes under 400ms. **Error**: plain-language cause, retry when safe, optional “Copy details” containing diagnostic metadata only (no clipboard payload); show persistent error banner for permission/configuration failures. **[INFERENCE]** Skeleton count is viewport-adaptive (3 minimum, at most 8), not a fixed production claim.

Six states: rest presents the relevant message; hover only on the primary action; pressed begins action once; selected applies to focusable retry/filter controls; focused exposes clear action order; disabled explains why retry/action is unavailable. Loading has progress indicator/announcement for operations lasting >400ms; error state remains after action failure until retry/dismissal.

## Sidebar: expanded and icon rail

**Expanded anatomy.** 176pt default width, clamp 150–260pt subject to panel content minimum. Library, category, and tool sections; 30pt rows; 8pt category dot with label/count; 6pt resize hit strip with horizontal-resize cursor and double-click reset. Collapse toggle `⌘⌃S`. Sidebar stays solid `surfaceSidebar`, not glass row-by-row.

**Rail anatomy.** 44pt wide, 28pt minimum icon hit target, 16pt glyph, tooltip includes section/name/count. Switch to rail below 520pt panel width or explicit toggle, never cut off the main list. **[INFERENCE]** 520pt is a design breakpoint; compute effective content width at runtime.

**States.** Rest: neutral rows; hover: row hover fill; pressed: native row response; selected: selected pill + active glyph (and AX selected trait); focused: focus ring, arrows navigate; disabled: unavailable row remains labeled with reason. Drag target state distinguishes category filing (2pt inset ring) from category reorder (insertion line); resize state shows cursor/grabber. Search/filter doesn't lose sidebar focus on pointer interaction.

**SwiftUI.** Focusable button rows; category selection and clip filing are distinct actions. Use `NavigationSplitView` when matching system structure is viable; otherwise `HStack` with measured breakpoint and persisted width. Keep category count scoped to visible list results (SBR-03).

## Segmented control

Use native `Picker(selection:) { ... }.pickerStyle(.segmented)` for 2–4 options (density, appearance); native sizing through `.controlSize(.regular)` and macOS 26 style. **[INFERENCE]** Target minimum height is 28pt; avoid forcing a fixed native-control frame. Icon-only custom variant includes visible tooltip/AX labels.

States: rest is system neutral; hover/pressed use native control feedback; selected is system selected segment plus bound enum value; focused supports arrow-key change and visible system focus; disabled follows system disabled style and announces “Dimmed.” Do not tint every segment or build a second custom segmented style that diverges from system.

## Settings row

**Anatomy and size.** 44pt minimum, expands for two-line helper; label/body leading, optional caption description below, control aligned trailing. Color uses one color well + one monospaced hex value; stepper value visible; port values have no grouping separators. Group by pane/section and support settings search keywords (SET-02/03/09).

States: rest shows current value; hover applies only to navigable row, not every form row; pressed triggers control; selected indicates current pane/setting only where semantically selectable; focused is on actual toggle/field/button with visible ring; disabled is subdued with inline reason/link, not just lower opacity. Validation errors remain next to the specific setting and are AX-announced.

Use native Toggle/Picker/Stepper/ColorPicker and keyboard focus order. Commit validated text on submit and focus loss; a failed Keychain write must retain the draft (SET-06). **[INFERENCE]** Shared `SettingsRow` wraps content slots rather than owning persistence.

## Sheet and inspector

**Sheet.** System `.sheet` presentation with concise title, content form, Cancel and primary action footer; Escape dismisses/cancels, primary button uses native prominent style. Use system sheet material instead of custom glass/background (Apple Adopting Liquid Glass / WWDC25 323). Width adapts to content and Dynamic Type.

**Inspector.** Trailing 280–360pt detail pane tied to selected clip: preview metadata/source/categories/tags/OCR status and actions. System `.inspector` where applicable; content remains solid. If selection changes, inspector content updates without resetting list selection.

States: rest displays content; hover/pressed on actions only; selected refers to focused form value/selected clip; focused starts on title/action per flow and restores invoking focus after close; disabled fields explain permission/availability. No modal “selected” treatment for the sheet itself. Both labels/roles support VoiceOver; masked clips retain mask throughout.

## Command palette overlay (⌘K)

**Anatomy and size.** 560pt target width, max 90% of panel, 16pt corner; one glass surface/container (not glass on glass). Search/input row 44pt, results 36pt, section labels and trailing shortcut keycaps. Groups: clip actions (selection context), navigate, app commands/settings. Fuzzy search operates on safe titles only; sensitive records stay masked and not in history snippets.

States: rest begins focused in query; hover highlights action; pressed runs it; selected follows current result; focused navigates with Up/Down and returns focus after dismissal; disabled action states why (e.g. no selected clip). Escape closes, Return runs, arrows navigate; result always names its target/effect. Search field <-> palette morph only if same `GlassEffectContainer`/namespace and Reduce Motion fallback is opacity. **[INFERENCE]** The shortcut is a proposed product binding, subject to conflict check.

## Quick Look preview

Space toggles preview of selected item; Space/Escape closes preview before panel dismissal. Preview is a system Quick Look surface where file preview applies; for in-app text/link/color/image use dedicated display. Optional right preview column starts at a content-width threshold; compact mode floats a 90%-width panel capped at 640×420pt. Glass is limited to the floating toolbar, preview content is solid. Toolbar actions: paste, edit, copy, close; image fit/100%, code/text find, color values.

States: rest shows selected clip; hover reveals toolbar; pressed invokes action; selected follows selected clip; focused supports arrowing between clips and toolbar keyboard shortcuts; disabled shows an explanatory unavailable preview. Sensitive content remains masked until explicit reveal; reveal state is transient, re-masks when closed/panel hidden. File missing/error gets a recoverable error state. **[INFERENCE]** Exact implementation can use `QLPreviewPanel`/QuickLookUI, but coordinate ownership with current panel `NSWindow` first.

## Shared design-system API (proposed)

Names and signatures are the stable SwiftUI-facing contract; access control may be `internal` if the design-system remains in the Clippy target. **[INFERENCE]** `Sources/Clippy/DesignSystem/` is the proposed shared location, following the companion redesign brief.

```swift
struct ClippyTokens {
    var surface, surfaceElevated, surfaceInset, surfaceSidebar: Color
    var stroke, strokeStrong: Color
    var textPrimary, textSecondary, textTertiary: Color
    var accent, accentText, onAccent, selection: Color
    var success, warning, danger, masked: Color
    var kind: (ClipKindStyle) -> Color
    var focusRing: Color { accentText }
    static func resolve(from t: ThemeTokens,
                        contrast: ColorSchemeContrast) -> ClippyTokens
}

extension EnvironmentValues {
    var clippyTokens: ClippyTokens { get set }
}

struct GlassSurface<Content: View>: View {
    let shape: AnyShape
    let interactive: Bool
    @ViewBuilder let content: () -> Content
    init<S: Shape>(in shape: S, interactive: Bool = false,
                   @ViewBuilder content: @escaping () -> Content)
}

struct PanelShell<Content: View>: View {
    let section: PanelSection
    @ViewBuilder let content: () -> Content
    init(section: PanelSection, @ViewBuilder content: @escaping () -> Content)
}

struct PanelHeader: View {
    let model: PanelHeaderModel
    let search: SearchBinding
    let actions: PanelHeaderActions
    init(model: PanelHeaderModel, search: SearchBinding, actions: PanelHeaderActions)
}

struct FilterBar: View {
    let chips: [FilterChipModel]
    let selection: Set<FilterID>
    let toggle: (FilterID) -> Void
}

struct ClipRow: View {
    let model: ClipRowModel
    let state: ClipRowState
    let actions: ClipRowActions
    init(model: ClipRowModel, state: ClipRowState = .rest,
         actions: ClipRowActions)
}

struct ClipCard: View {
    let model: ClipRowModel
    let state: ClipRowState
    let actions: ClipRowActions
    init(model: ClipRowModel, state: ClipRowState = .rest,
         actions: ClipRowActions)
}

struct ClipPreview: View {
    let model: ClipPreviewModel
    let density: ClipDensity
    init(model: ClipPreviewModel, density: ClipDensity)
}

struct FilterChip: View {
    let model: FilterChipModel
    let state: ControlState
    let action: () -> Void
    init(model: FilterChipModel, state: ControlState = .rest,
         action: @escaping () -> Void)
}

struct ReasonChip: View {
    let model: ReasonChipModel
    let state: ControlState
    init(model: ReasonChipModel, state: ControlState = .rest)
}

struct Toast: View {
    let model: ToastModel
    let action: (() -> Void)?
    let dismiss: () -> Void
    init(model: ToastModel, action: (() -> Void)? = nil,
         dismiss: @escaping () -> Void)
}

struct ActivityBanner: View {
    let model: BannerModel
    let action: (() -> Void)?
    init(model: BannerModel, action: (() -> Void)? = nil)
}

struct EmptyStateView: View {
    let model: EmptyStateModel
    let action: (() -> Void)?
    init(model: EmptyStateModel, action: (() -> Void)? = nil)
}

struct SidebarView: View { let model: SidebarModel; let actions: SidebarActions }
struct SidebarRail: View { let model: SidebarModel; let actions: SidebarActions }

struct ClippySegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [SegmentOption<Value>]
    init(selection: Binding<Value>, options: [SegmentOption<Value>])
}

struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    let detail: Text?
    @ViewBuilder let control: () -> Control
    init(title: LocalizedStringKey, detail: Text? = nil,
         @ViewBuilder control: @escaping () -> Control)
}

struct ClippySheet<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content
    init(title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content)
}

struct ClipInspector: View { let model: ClipInspectorModel; let actions: ClipRowActions }
struct CommandPalette: View { let model: CommandPaletteModel; let run: (PaletteAction) -> Void }
struct QuickLookPreview: View { let model: ClipPreviewModel; let actions: ClipRowActions }
struct SensitiveClipMask: View { let model: MaskedClipModel; let reveal: () -> Void }
```

Associated values are typed and presentation-safe. `ClipRowActions` injects callbacks for paste, copy, pin, edit, delete; no view directly touches storage, logging, capture, AI or paste services. `ControlState` covers rest/hover/pressed/selected/focused/disabled; `ClipRowState` adds pending-paste and masked/revealed; `ClipDensity` is compact/comfortable/cards. `GlassSurface` owns Reduce Transparency/Increase Contrast fallback. Keep the `ClippyTokens.resolve(from:contrast:)` adapter and `EnvironmentValues.clippyTokens` access path consistent across all feature views.


### Existing view replacement map

Replace the following existing view responsibilities at cutover; update their callers rather than keeping visual shims/re-exports. Non-visual controllers and data models remain in place unless separately changed.

| Existing file | New component responsibility | Notes |
|---|---|---|
| `Sources/Clippy/UI/PanelHeaderView.swift` | `PanelHeader` inside `PanelShell` | Preserve search/drag-region behavior; eliminate duplicate style rules |
| `Sources/Clippy/UI/ClipListView.swift` | `PanelShell` content composition, `ClipRow`, filters, sidebar routing | Keep list/search/navigation orchestration in a host model/view; migrate every row/render branch |
| `Sources/Clippy/UI/ClipCardView.swift` | `ClipRow` + `ClipCard` + `ClipPreview` | Replace per-card controls and old colored border styling |
| `Sources/Clippy/UI/CategorySidePane.swift` | `SidebarView` + `SidebarRail` | Preserve filing/reorder operations while replacing row/focus/resizing treatment |
| `Sources/Clippy/UI/ThemedBackground.swift` | `GlassSurface` / token-backed shell and surface backgrounds | Remove unused `panelMaterial` path only after all settings callers are migrated |
| `Sources/Clippy/UI/SettingsView.swift` | `SettingsRow` and shared grouped settings primitives | Split section/page ownership separately; not a full settings redesign spec here |
| `Sources/Clippy/UI/ClipEditorView.swift` | System sheet / inspector surfaces where editor is presented | Editor content/actions remain owned by editor; replace presentation shell only |
| No current view identified for palette, reason chip, toast or Quick Look | Add `CommandPalette`, `ReasonChip`, `Toast`, `QuickLookPreview` | New capabilities, not a replacement claim |

Paths above are existing-file references from ROADMAP and the redesign brief. Before implementation, search all call sites of each replaced view, migrate each one, and remove old style branches only after none remain. This spec does not authorize unrelated data-layer or capture behavior changes.
