# 01 - Principles and Tokens

Design foundation for the Clippy redesign (macOS 26, SwiftUI). Companion: `02-components.md`.
Claims tagged **[INFERENCE]** are design judgment or unverified against a primary source.
Contrast ratios in section 8 were computed with a throwaway Python WCAG 2.x script (relative-luminance formula); no ratio appears here that was not in its output.

Sources read/researched while writing:
- Apple Human Interface Guidelines, *Materials* - https://developer.apple.com/design/human-interface-guidelines/materials
- Apple, *Adopting Liquid Glass* - https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass
- WWDC25 219 *Meet Liquid Glass* - https://developer.apple.com/videos/play/wwdc2025/219/
- WWDC25 323 *Build a SwiftUI app with the new design* - https://developer.apple.com/videos/play/wwdc2025/323/
- Paste product page - https://pasteapp.io/ (feature framing: visual cards, pinboards, sensitive-app rules)
- Raycast Clipboard History product page - https://www.raycast.com/core-features/clipboard-history (search result only, not opened)

Maccy and Things 3 were not inspected; no product-specific behavior is claimed for them.

---

## 1. Principles

Clippy is a popup you summon mid-task, use for two to five seconds, and dismiss. It stores text that may include client PII, so the UI must be fast, legible at a glance, and honest about sensitivity (FTC Safeguards / Reg S-P context).

1. **Keyboard first, pointer welcome.** Every action reachable without the mouse; focus and selection are always visible. Two-stage Escape (clear query, then hide) fixes ROADMAP PNL-11. Arrow navigation must be 2D-aware (KEY-03), and focus must live on the list container, not only the search field (KEY-06).
2. **Content is the headline.** The clip's text/image is the largest element; source app is a small icon in metadata (LAY-07: ~93% of cards currently lead with "Microsoft Edge Dev"). One clip type = one recognizable silhouette.
3. **Glanceable density.** Default to a 32pt compact row (LAY-08) so 12+ clips fit without scrolling; opt in to comfortable cards. Truncate with intent: title `lineLimit(1)`, timestamp never wraps (LAY-03).
4. **Glass is chrome, never content.** Apple: Liquid Glass "is best reserved for the navigation layer that floats above the content" and glass-on-glass "can quickly make the interface feel cluttered" (WWDC25 219). Clip rows are solid content-layer surfaces.
5. **Sensitivity is visible, reasons are explicit.** A masked clip looks masked (no partial leak in previews, list, drag, Quick Look, VoiceOver label). Any automated decision (skipped capture, redaction, auto-expire) carries a **reason chip** so a user or examiner can see why.
6. **One signal per meaning.** Selection owns the accent stroke/fill (LAY-09). Color-by-app/kind is a small glyph tint, never a border competing with selection. Accent tint only for primary actions (WWDC25 219: "When every element is tinted, nothing stands out").
7. **Adapt, never break.** Layout derives from measured minimums, not hard-coded widths (PNL-03, LAY-02). Honor Reduce Motion, Reduce Transparency, Increase Contrast and Dynamic Type (A11Y-03). Every state (empty/loading/error) is designed, not incidental.

---

## 2. Liquid Glass rules

Grounded in the Apple sources above.

### 2.1 Where glass, where solid

| Layer | Surface | Rationale |
|---|---|---|
| Panel window backdrop | System window glass via `NSGlassEffectView` / `.glassEffect` on shell (or system material fallback) | Distinct floating layer over the user's app |
| Header background | Panel backdrop; search is a solid inset field (`surfaceInset`), not glass | Search text needs predictable contrast; matches `redesign-brief.md` |
| Filter-chip row, multi-selection action bar | Glass, grouped in a `GlassEffectContainer` | Floating controls/navigation layer |
| Sidebar | Solid `surfaceSidebar`; do not glass each dense navigation row | Dense labels/counts stay legible; matches `redesign-brief.md` |
| Footer shortcut bar | Sits on panel backdrop, no extra glass blob; keycaps are solid/translucent fills | Compact context-specific hints |
| Toasts, command palette, floating preview toolbar | Glass, one container per cluster | Transient functional controls |
| Clip rows, cards, previews, code/text bodies | **Solid** content surfaces | Repeated content layer; glass harms hierarchy |
| Settings form rows | Solid grouped `Form` | Content; use system `Form` / `.formStyle(.grouped)` |
| Sensitive masked state | Solid, higher-contrast | Must not depend on what is behind the panel |

### 2.2 Rules

- **No glass on glass.** Elements sitting on a glass bar use fills/vibrancy, not another `glassEffect` (WWDC25 219).
- **Group with `GlassEffectContainer`.** WWDC25 323: glass cannot sample other glass, so nearby glass elements in different containers can render inconsistently; a container shares the sampling region. Filter chips and selection actions each share one container; toast controls use a separate container. Banners are solid and stay outside glass groups. Keep independently acting clusters separate.
- **Regular variant only.** Do not mix Regular and Clear (WWDC25 219). Clear needs media-rich content plus dimming; a text clipboard list fails those conditions. [INFERENCE: Clear is never used in Clippy.]
- **Tint sparingly.** `.tint` on glass only for the primary action (e.g. Paste, Confirm), per WWDC25 323.
- **Prefer standard controls.** Use `.buttonStyle(.glass)` / `.glassProminent`, system `Picker(.segmented)`, `.searchable`/system toolbars, `.inspector`, `NavigationSplitView` so the system supplies morphing and accessibility adaptation. Remove custom backgrounds behind bars/sheets (Adopting Liquid Glass; WWDC25 323 on `presentationBackground`).
- **Scroll edge effect** under the filter/action overlay if content scrolls behind it; prefer `safeAreaBar(edge:)` and system effects instead of a custom darkening layer.
- **Concentric corners.** Nest radii with `ConcentricRectangle` / `.containerConcentric` (WWDC25 323) so control corners follow their container.
- **Accessibility adaptation.** Apple's system Liquid Glass responds to Reduce Transparency, Increase Contrast, Reduce Motion (WWDC25 219). Custom surfaces must also read `accessibilityReduceTransparency` / `colorSchemeContrast` and fall back to solid `surfaceElevated` + 1pt `stroke`.
- **`panelMaterial` setting (LAY-14).** Preserve the five `PanelMaterialStyle` raw values, but resolve them to Glass (default), Vibrancy (`NSVisualEffectView.material = .hudWindow`), or Solid. Map `ultraThin`/`thin` -> Glass, `regular`/`thick` -> Vibrancy, and `opaque` -> Solid. [INFERENCE: this migration map is proposed; verify AppKit rendering at runtime.]
- **macOS availability.** Target is macOS 26 so `glassEffect` needs no guard; retain a `#available(macOS 26, *)` material fallback only if deployment target is ever lowered. [INFERENCE]

### 2.3 Panel window notes
Borderless `NSPanel` shell: glass is the content view's background; the window must be `isOpaque = false`, `backgroundColor = .clear`. Shadow comes from the window (`hasShadow = true`), not SwiftUI `.shadow`, so it is not clipped. [INFERENCE: verify at runtime.]

---

## 3. Tokens: shape, space, depth

### 3.1 Radius scale

| Token | pt | Use |
|---|---:|---|
| `radius.xs` | 4 | Inline code chips, keycaps, color swatches |
| `radius.sm` | 8 | Compact row selection inset, small buttons |
| `radius.md` | 12 | Cards, previews, text fields, popovers |
| `radius.lg` | 16 | Sidebar, sheets/inspector, command palette |
| `radius.xl` | 24 | Panel shell |
| `radius.full` | capsule | Filter/reason chips, toasts, default glass controls |

Rule: inner radius follows outer radius - inset; use `ConcentricRectangle` when possible. Exact values are design proposals, not Apple's published metrics. [INFERENCE]

### 3.2 Spacing (4pt grid)

`space.0=0, 1=4, 2=8, 3=12, 4=16, 5=20, 6=24, 8=32, 10=40`. Panel outer inset 12; 8pt card/list gutter; row padding 8 horizontal and 4 vertical (compact row is 32pt total). Minimum custom pointer target 28x28pt [INFERENCE]; use system `controlSize` for native controls, not fixed heights (WWDC25 323).

### 3.3 Elevation

| Token | Treatment | Used by |
|---|---|---|
| `e0` | no shadow; solid fill | rows, sidebar, settings rows |
| `e1` | 1pt `stroke`; restrained shadow only in Cards density | cards, popovers |
| `e2` | regular glass with system-adaptive shadow; solid fallback when accessibility requires | filter/action clusters, palette, Quick Look toolbar, toasts |

Fallback for Reduce Transparency or Increase Contrast: `e2` -> `surfaceElevated` + 1pt `stroke`; keep the system window shadow on the panel itself.

---

## 4. Motion

Apple: glass "materializes" by modulating lensing rather than fading, and Reduce Motion disables elastic effects (WWDC25 219). Durations/curves below are proposals [INFERENCE].

| Token | Duration | Curve | Use | Reduce Motion |
|---|---:|---|---|---|
| `motion.instant` | 0.08s | `.easeOut` | hover/pressed fill | opacity only |
| `motion.quick` | 0.15s | `.easeOut` | selection, chip toggle, action/metadata crossfade | same |
| `motion.standard` | 0.22s | `.spring(response: 0.28, dampingFraction: 0.86)` | sidebar collapse, inspector | 0.1s opacity, no offset/scale |
| `motion.toast` | 0.26s in / 0.18s out | `.spring(duration: 0.26, bounce: 0.08)` / `.easeInOut` | toast/palette entrance and dismissal | 0.15s opacity |
| `motion.masked` | 0.12s | `.linear` | reveal/remask transition | 0.08s opacity; no blur/morph |
| `motion.panelShow` | 0.10s | `.easeOut` fade + 4pt rise | panel appears | fade only |

Never animate layout on each search keystroke. Selection scroll uses `motion.quick`, or none with Reduce Motion. Provide `ClippyMotion.animation(_:reduce:)` reading `accessibilityReduceMotion`.

---

## 5. SF Symbols

- SF Symbols only for UI glyphs; no emoji (source-app icons remain from `AppIconProvider`).
- Use `.monochrome` for toolbar/chrome glyphs; `.hierarchical` for empty-state hero; `.palette` only for status/semantic signals. WWDC25 323 says monochrome rendering is used in more toolbar contexts to reduce noise.
- Tint conveys meaning, not decoration. Kind glyphs use `textSecondary`; color-by-app/kind tint remains a small glyph only.
- Symbol weight matches adjacent text; size follows type scale, not fixed frame alone.
- Icon-only buttons always include `.help()` and `.accessibilityLabel`.

| Meaning | Symbol |
|---|---|
| text / rich text | `text.alignleft` / `doc.richtext` |
| image / file / link / color / code | `photo` / `doc` / `link` / `paintpalette` / `chevron.left.forwardslash.chevron.right` |
| pin / mask | `pin` / `eye.slash` |
| skipped reason / copy / delete | `nosign` / `doc.on.doc` / `trash` |
| search / palette / sidebar | `magnifyingglass` / `command` / `sidebar.left` |
| warning / error / success | `exclamationmark.triangle.fill` / `xmark.octagon.fill` / `checkmark.circle.fill` |

[INFERENCE: the listed names are proposed SF Symbols 7 identifiers; verify individually during implementation.]

---
## 6. Semantic colors and measured contrast

Contrast policy: [WCAG 2.x AA](https://www.w3.org/WAI/WCAG21/Understanding/contrast-minimum.html) is 4.5:1 for normal text and 3:1 for large text and meaningful non-text UI. Values below were computed with the standard WCAG relative-luminance formula in a throwaway Python script; every reported ratio came from its output. This is a proposed token palette, not a claim that every existing `ThemePreset` already passes.

| Role | Light | Dark | Light contrast on surface / elevated / selection / inset | Dark contrast on surface / elevated / selection / inset |
|---|---|---|---|---|
| `surface` | `#F5F5F7` | `#1C1C1E` | — | — |
| `surfaceElevated` | `#FFFFFF` | `#2C2C2E` | — | — |
| `selection` | `#FBEFD6` | `#4A3A17` | — | — |
| `surfaceInset` | `#EAEAEE` | `#141416` | — | — |
| `surfaceSidebar` | `#EFEFF3` | `#18181A` | — | — |
| `stroke` | `#D9D9DE` | `#3A3A3E` | decorative only | decorative only |
| `masked` | `#D9D9DE` | `#3A3A3E` | pair with label/glyph | pair with label/glyph |
| `scrollbar` | `#8A8A8F` | `#75757B` | 3.16 on surface | 3.72 on surface |
| `textPrimary` | `#1D1D1F` | `#F5F5F7` | 15.46 / 16.83 / 14.76 / 14.03 | 15.63 / 12.80 / 10.10 / 16.90 |
| `textSecondary` | `#66666B` | `#B4B4BA` | 5.24 / 5.71 / 5.01 / 4.76 | 8.25 / 6.75 / 5.33 / 8.92 |
| `textTertiary` | `#66666B` | `#B4B4BA` | 5.24 / 5.71 / 5.01 / 4.76 | 8.25 / 6.75 / 5.33 / 8.92 |
| `accent` fill | `#E0A23C` | `#F0B24A` | foreground is `onAccent` | foreground is `onAccent` |
| `onAccent` | `#1D1D1F` | `#1D1D1F` | 7.54 on `#E0A23C` | 8.95 on `#F0B24A` |
| `accentText` / `warning` / `focusRing` | `#8A5A00` / `#8F5B00` / `#8A5A00` | `#F0B24A` | accentText/focus 5.44 / 5.93 / 5.20 / 4.94; warning 5.26 / 5.73 / 5.03 / 4.78 | all 9.05 / 7.41 / 5.85 / 9.79 |
| `success` | `#1E7B34` | `#5DD37A` | 4.90 / 5.33 / 4.68 / 4.44 | 8.96 / 7.34 / 5.80 / 9.69 |
| `danger` | `#C4291C` | `#FF6B5E` | 5.24 / 5.70 / 5.00 / 4.75 | 6.09 / 4.99 / 3.94 / 6.59 |
| `strokeStrong` | `#8A8A8F` | `#75757B` | 3.16 / 3.44 / 3.01 / 2.86 | 3.72 / 3.04 / 2.40 / 4.02 |

Interpretation and limits:
- `textPrimary`, `textSecondary`, `accentText`, and `warning` exceed 4.5 on all listed surfaces. `success` on light `surfaceInset` is 4.44; dark `danger` on selected is 3.94, so never use that danger color for selected-row text. Pair status glyphs with `textPrimary` labels.
- `focusRing` uses the contrast-safe `accentText` value and exceeds 4.5:1 on all listed surfaces. `strokeStrong` misses 3:1 on light `surfaceInset` (2.86) and dark `selection` (2.40); use the focus ring on selected rows, and avoid `strokeStrong` on those backgrounds.
- `accent` fill is never text on light; use `onAccent`. Avoid raw amber as a text link; use `accentText`.
- Ratios for icon/outline roles are not generalized to tinted media/glass backgrounds. Use system adaptive vibrant foregrounds over glass, and solid backing for custom text over unpredictable imagery.

### 6.1 Mapping to the existing `ThemeTokens`

`ThemeTokens` in `Support/ThemePreset.swift` is the persisted base format: `panel`, `scrollBackground`, `cardSurface`, `cardBorder`, `headerBar`, `footerBar`, `sidebar`, `scrollbar`, `textPrimary`, `textSecondary`, `accent`, `success`, `danger`, `isDark`. The shared value-type `ClippyTokens` is derived from it with `ClippyTokens.resolve(from: ThemeTokens, contrast: ColorSchemeContrast)`; views read that resolved value. This preserves preset names, custom settings and existing storage.

| Semantic role | Existing field / derivation |
|---|---|
| `surface` | `scrollBackground` |
| `surfaceElevated` | `cardSurface` |
| `surfaceInset` | derived from `panel`; legacy `headerBar` remains available to Custom compatibility |
| `surfaceSidebar` | `sidebar` |
| `stroke` | `cardBorder` |
| `strokeStrong` | derived from `textSecondary`/`surface` and contrast-adjusted to >=3:1 |
| `textPrimary`, `textSecondary` | same-named fields |
| `textTertiary` | derived from `textSecondary` and contrast-adjusted for AA |
| `accent` | same-named field |
| `focusRing` | computed alias of `accentText` |
| `accentText`, `onAccent`, `selection`, `warning`, `kind.*` | derived from the base accent/palette and contrast-adjusted as needed |
| `success`, `danger` | same-named fields |
| `headerBar`, `footerBar` | folded into panel backdrop by default; retained for Custom compatibility |
| `masked` | neutral semantic mask fill |
| color scheme | `isDark` |

Do not rename/delete persisted preset cases during UI migration. Ratios in the default palette above do not claim every named preset passes; derive contrast companions per preset and verify every preset. The palette and ratios are tied only to the exact computed light/dark hex pairs.


---

## 7. Typography and Dynamic Type

Use SwiftUI text styles, not fixed point sizes, so system text sizing and accessibility sizes remain effective (A11Y-03). Existing `PanelFontFamily` may continue to override body/title face; keep monospaced styles fixed to the monospaced design. [INFERENCE: exact point sizes are nominal macOS defaults and may vary by system rendering.]

| Role | SwiftUI `Font.TextStyle` | Weight / design | Use |
|---|---|---|---|
| `display` | `.title2` | `.semibold`, default | Empty-state headline, onboarding |
| `title` | `.headline` | `.semibold` | Pane / section title, clip title |
| `body` | `.body` | `.regular` | Clip text, settings labels |
| `bodyEmphasis` | `.body` | `.medium` | Selected clip, primary chip label |
| `metadata` | `.callout` | `.regular` | App/source/time, metadata |
| `caption` | `.caption` | `.regular` | Helper text, reason chip |
| `micro` | `.caption2` | `.medium` | Counts, shortcut hints; do not shrink further |
| `code` | `.body` | `.monospaced` design | Code preview, hex values |

Use `.font(.body, design: .monospaced)` only for code; apply `.dynamicTypeSize` naturally. Compact row's 32pt is its default minimum, not a clipping constraint: let it grow to two lines at larger text sizes. The app's five-step font-size preference should select Dynamic Type categories rather than scaling `Font.system(size:)`. [INFERENCE: suggested mapping of preference steps to categories requires product confirmation.]

---

## 8. Existing theme presets and proposed default

All ten persisted enum cases stay valid. Named palettes keep their existing `fixedTokens` / `Theme.tokens(settings:)` base surface and text palette; the shared semantic tokens are layered over those values rather than replacing the palette. Current names, read from `Support/ThemePreset.swift`:

| `ThemePreset` case (stored raw value) | UI label | Token mapping policy |
|---|---|---|
| `system` | Match system | `panel`, surfaces, text and `isDark` follow effective system appearance; semantic roles use system light/dark table above |
| `cleanLight` | Clean Light | Preserve Clean Light palette; map existing `panel`, `scrollBackground`, `cardSurface`, `cardBorder`, `headerBar`, `sidebar`, text and `accent` to semantic roles |
| `githubDark` | GitHub Dark | Preserve GitHub Dark palette; map through same role adapter |
| `dracula` | Dracula | Preserve Dracula palette; map through same role adapter |
| `materialDarkPlus` | Material Dark+ | Preserve Material Dark+ palette; map through same role adapter |
| `nord` | Nord | Preserve Nord palette; map through same role adapter |
| `oneDark` | One Dark | Preserve One Dark palette; map through same role adapter |
| `tokyoNight` | Tokyo Night | Preserve Tokyo Night palette; map through same role adapter |
| `solarizedDark` | Solarized Dark | Preserve Solarized Dark palette; map through same role adapter |
| `custom` | Custom | Preserve user-entered base fields; derive semantic companion roles from edited surface/accent and require custom contrast validation |

`AppearanceMode` (`system`, `light`, `dark`), `AccentTheme` (`clippyAmber`, `system`, `blue`, `purple`, `pink`, `red`, `orange`, `yellow`, `green`, `teal`, `graphite`), `PanelMaterialStyle` (`ultraThin`, `thin`, `regular`, `thick`, `opaque`), `CardStyle` (`filled`, `bordered`, `plain`) and `CardColorMode` (`byApp`, `byKind`, `accent`, `neutral`) continue working during cutover. UI default proposal: `ThemePreset.system` + `AppearanceMode.system` + `AccentTheme.clippyAmber`; panel glass, compact rows, Auto columns, sidebar visible at wide widths and rail below breakpoint. This keeps the preset system behavior while eliminating the default amber-on-white text failure via separate `accentText` / `onAccent` roles. [INFERENCE: precise settings defaults are a product proposal.]

References for competitor framing: Paste's product page describes searchable clipboard history, pinning, visual previews and per-app sensitive-app rules (https://pasteapp.io/); Raycast's Clipboard History product page describes clipboard history retrieval/search (https://www.raycast.com/core-features/clipboard-history). The latter URL was returned in web search but not opened; limit the claim to that search snippet. Maccy and Things 3 were not inspected; no product-specific behavior is claimed for them.

---
