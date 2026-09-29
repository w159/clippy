# Reference gaps: what to pull from Mobbin later (05)

Status: to-do list. Mobbin MCP was OAuth-gated and unavailable, so none of the design docs use Mobbin material. When access exists, pull the items below, save screenshots under `docs/design/reference/` (not created yet), and update the mapped screen in `03-screens.md`. Do not authenticate to anything on behalf of the owner without their instruction.

Sources actually used instead (fetched this session): <https://pasteapp.io/help/keyboard-shortcuts>, <https://manual.raycast.com/clipboard-history>, <https://www.alfredapp.com/help/features/clipboard/>, <https://tapbots.com/pastebot/>.

How to record each pull: app, platform (macOS unless noted), screen name, date, what specific decision it settles.

## 1. Pull list

| # | App or query | Screen type / flow to capture | Mobbin search terms | Decision it settles | Maps to (03-screens.md) |
|---|---|---|---|---|---|
| 1 | Paste | History strip, pinboards, preview | "Paste clipboard manager", "clipboard history" | Row density, how metadata and kind are shown | 1 Popup panel |
| 2 | Raycast | Clipboard History list with detail pane | "Raycast clipboard", "list with detail" | Wide layout: list plus preview column | 1 Popup panel, 5 Quick Look |
| 3 | Raycast | Action Panel (Cmd+K) | "Raycast action panel", "command palette" | Palette anatomy, section headers, keycaps | 4 Command palette |
| 4 | Linear | Command menu (Cmd+K), empty and typed state | "Linear command menu", "command palette" | Prefix scoping, recents, empty state | 4 Command palette |
| 5 | Arc | Command bar | "Arc command bar" | Morph from search field to palette [INFERENCE: Arc is a browser, so this is a pattern reference only] | 4 Command palette |
| 6 | Alfred | Clipboard viewer with snippet save | "Alfred clipboard history" | Compact list with keyboard hints | 1 Popup panel |
| 7 | Pastebot | Quick paste menu with docked preview | "Pastebot quick paste" | Preview docked to side of a quick menu | 5 Quick Look |
| 8 | Pastebot | Smart Pastebin rule editor | "Pastebot smart pastebin", "rule builder" | Filter chips writing into a query grammar | 1 Popup panel (chips), 3 Sidebar |
| 9 | macOS apps with sidebar | Icon rail collapse states | "sidebar collapsed icon rail macOS" | Rail width, tooltips, selected state | 3 Sidebar |
| 10 | Things 3, Bear, Craft | Sidebar sections and counts | "sidebar list counts" | Group headers and drop indicators | 3 Sidebar |
| 11 | macOS System Settings | Sidebar plus search, result jump and flash | "System Settings search" | Settings search behavior | 8 Settings |
| 12 | Raycast | Settings sidebar with per-command options | "Raycast preferences" | Row layout with descriptions | 8 Settings |
| 13 | ChatGPT, Claude, Raycast AI Chat | Chat with tool call disclosure | "AI chat tool use", "chat with sources" | Tool activity drawer, context chip | 9 AI Assistant |
| 14 | Raycast AI Commands | Prompt template editor with test | "prompt editor", "AI command" | Two-pane editor with live test | 10 AI Actions editor |
| 15 | Script Editor, Nova, Xcode | Editor with output drawer | "code editor output panel" | Bottom drawer states, run status | 11 Scripts |
| 16 | Shortcuts (macOS) | Action list plus run result | "Shortcuts editor" | Run result states | 11 Scripts |
| 17 | 1Password 8 | Vault list, item detail, TOTP countdown, locked state | "1Password item detail", "locked vault" | Needs-sign-in and detail layout | 12 1Password view |
| 18 | Any macOS app | Permission onboarding (Accessibility) | "permissions onboarding macOS", "welcome permissions" | Live status after returning from System Settings | 13 Onboarding |
| 19 | Loom, CleanShot, Raycast | First-run wizard | "onboarding steps macOS" | Step count, skip, re-open | 13 Onboarding |
| 20 | Preview, Pixelmator | Image editor crop and inspector | "image editor crop", "inspector panel" | Handles, checkerboard, undo affordance | 7 Image editor |
| 21 | Bear, Craft, iA Writer | Text editor with inspector and find | "text editor inspector", "find bar" | Editor chrome, conflict banner | 6 Clip editor |
| 22 | Any | Toast, banner, empty states | "toast", "empty state", "banner" | Wording and placement | all (04-interaction.md section 7) |
| 23 | Any | Masked or sensitive content patterns | "masked text", "reveal password" | Mask and reveal design | 1 Popup panel, 12 1Password view |

## 2. Flow pulls (multi-screen)

- **Copy, open, search, paste**: Paste, Raycast, Alfred, Pastebot. Capture the first 5 seconds after the hotkey. Settles: default focus and footer hints (04 section 1).
- **Multi-select and batch actions**: Finder-like lists. Settles: selection bar (04 section 5).
- **Drag to file into a category**: Pastebot pastebins, Things 3 areas. Settles: drop indicators (04 section 4).
- **First run to first paste**: any utility needing Accessibility. Settles: onboarding steps (03 screen 13).

## 3. Questions to answer when pulling

1. Which apps show a preview column at ~1100pt, and at what width do they hide it? (screen 1, 5)
2. Do palettes in these apps use prefix scoping, sections, or both? (screen 4)
3. Where do Settings search results land: filtered list, or jump-and-highlight? (screen 8)
4. How do tool-using AI chats show approval for write actions? (screen 9)
5. How is a not-signed-in state phrased in credential-manager UIs? (screen 12)

## 4. Not verified this session

Which of the listed apps ship each pattern, and their exact appearance on macOS 26, was not checked. Linear and Arc were not fetched at all. Treat table rows 4, 5, 10, 12, 16, 19, 20 and 21 as leads, not facts.
