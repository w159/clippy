<div align="center">
  <img src="img/Clippy.png" width="160" alt="Clippy">

  <h1>Clippy</h1>

  <p><strong>The clipboard manager for people who copy and paste all day.</strong></p>
  <p>Every clip you copy, searchable in a keystroke. Pins, categories, AI actions, scripts, and 1Password access, all in a panel that pops up right where you are typing. Your data never leaves your Mac.</p>

  <p>
    <img src="https://img.shields.io/badge/macOS-26%2B-0ea5e9?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 26+">
    <img src="https://img.shields.io/badge/Price-Free-22c55e?style=for-the-badge" alt="Free">
    <img src="https://img.shields.io/badge/Privacy-Local%20only-a855f7?style=for-the-badge" alt="Local only">
    <img src="https://img.shields.io/badge/Updates-Auto-15803d?style=for-the-badge" alt="Auto update">
  </p>

  <p>
    <a href="https://github.com/w159/clippy/releases/latest"><strong>Download for macOS</strong></a>
    &nbsp;&middot;&nbsp;
    <a href="#getting-started">Getting started</a>
    &nbsp;&middot;&nbsp;
    <a href="#keyboard-shortcuts">Shortcuts</a>
    &nbsp;&middot;&nbsp;
    <a href="#for-developers">For developers</a>
  </p>
</div>

---

## See it in action

| The panel, where you are typing | Built for the keyboard |
| --- | --- |
| ![Main panel](img/clippy_main_window.png) | ![Hotkey workflow](img/clippy_feature_hotkeys.svg) |

| Settings | Private by default |
| --- | --- |
| ![Settings](img/clippy_feature_settings.svg) | ![Privacy](img/clippy_feature_privacy.svg) |

## What Clippy does

Press **Cmd+Shift+V** anywhere and Clippy appears at your cursor. Type to search your history, hit Return to paste. That is the whole loop, and it stays out of your way the rest of the time.

- **Clipboard history that you can actually find.** Everything you copy is captured and indexed for instant full-text search. Start typing and results filter as you go.
- **Pins and categories.** Keep the snippets you reuse one keystroke away. Pinned clips float to the top and survive history limits and "clear" actions. Organize the rest into color-coded categories.
- **Appears at your caret.** The panel opens right where you are typing, not in a corner of the screen. In apps that hide the caret it falls back to the mouse.
- **Smart cards.** Links, emails, file paths, colors, and images are recognized and shown with the right icon, a color swatch, or a thumbnail, tinted to match the app you copied from.
- **AI actions on any clip.** Summarize, rewrite, translate, fix grammar, or run your own custom prompts on a clip. Define your own actions with a prompt template, then review the result before it replaces anything.
- **An AI assistant built in.** Chat with an assistant that can search your clips, create new ones, and (only when you allow it) run your saved scripts. Works with OpenAI, Anthropic, Ollama, or Azure.
- **Run scripts on your clips.** Save shell scripts and run them from the panel, with live status and output you can copy or save as a new clip.
- **1Password access.** Browse a 1Password item's full detail, reveal and copy individual fields, and pull TOTP codes on demand. Secrets are marked concealed and the clipboard auto-clears after 90 seconds.
- **Extract text from images (OCR).** Right-click an image clip and "Extract Text" using Apple's on-device Vision engine. The recognized text becomes a new clip.
- **Make it yours.** Themes, accent colors, panel transparency, card styles, typography, capture sounds, and panel size and position are all adjustable.
- **Optional iCloud sync.** Turn it on to keep your history in step across your Macs. Off by default.
- **Stays current on its own.** Signed automatic updates install in place, so you are always on the latest version.

## Privacy

Clippy is local-first. Your clipboard data lives in a single database file on your Mac at `~/Library/Application Support/Clippy/clippy.sqlite` and is never sent anywhere unless you explicitly turn on iCloud sync or use an AI feature with your own provider key.

- Passwords and other content marked concealed by the source app (the `org.nspasteboard.ConcealedType` marker) are never stored.
- Transient and auto-generated clipboard writes are never stored.
- Any app you add to the ignore list is never captured.
- AI features and iCloud sync are opt-in. Script and code execution by the assistant are off by default and always ask before running, showing you exactly what will run.

## Getting started

1. **Download** the latest `Clippy.zip` from the [releases page](https://github.com/w159/clippy/releases/latest) and unzip it.
2. **Move** `Clippy.app` to your Applications folder and open it. Clippy lives in the menu bar, not the Dock.
3. **Grant Accessibility access** when prompted (System Settings > Privacy & Security > Accessibility). This lets Clippy read where your cursor is and paste for you. It is required for the panel to appear at your caret and paste in place.
4. **Press Cmd+Shift+V** in any app to open the panel. Start typing to search, press Return to paste.

Requires macOS 26 (Tahoe) or newer.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Open the panel | Cmd+Shift+V |
| Command palette (every action) | Cmd+K |
| Switch to History | Cmd+1 |
| Switch to the Nth category in the sidebar | Cmd+2 to Cmd+9 |
| Paste the selected clip | Return |
| Paste in the alternate mode (plain or formatted) | Shift+Return |
| Quick paste the Nth visible clip | Cmd+Option+1 to Cmd+Option+9 |
| Extend the selection | Shift+Arrow keys |
| Select all clips | Cmd+A |
| Copy without pasting | Cmd+C |
| Preview the selected clip (Quick Look) | Space (with the list focused) |
| Edit the selected clip | Cmd+E |
| Pin the selected clip | Cmd+P |
| Delete the selected clip | Cmd+Delete |
| Undo the last delete | Cmd+Z |
| Clear the selection, then the search, then close | Esc |

## Settings at a glance

| Tab | What you can change |
| --- | --- |
| General | Hotkey, paste behavior, move-pasted-clip-to-top, history limit, launch at login |
| Appearance | Theme and accent colors, panel transparency, card style, typography, capture sounds, panel size and position |
| Capture | Polling interval, image capture, per-app ignore list |
| AI | Enable AI features, choose a provider and key, custom AI actions, assistant agent and tool permissions, bundled MCP server |
| Scripts | Create, edit, and manage your saved scripts |
| Integrations | Categories and pins, export history, reveal the database, 1Password, iCloud sync |

---

## For developers

<details>
<summary><strong>Tech stack and design</strong></summary>

Clippy is a native macOS app written in **Swift 6 / SwiftUI**, rendered inside a nonactivating `NSPanel` so it can appear over other apps without stealing focus. It uses the **Accessibility API** for caret positioning and simulated Cmd+V paste, and **GRDB / SQLite with FTS5** for storage and full-text search. Automatic updates are delivered through **Sparkle** with EdDSA-signed releases.

The original stack rationale lives in [`docs/clipboard-manager-stack-decision.md`](docs/clipboard-manager-stack-decision.md).

</details>

<details>
<summary><strong>Build and run from source</strong></summary>

Requires macOS 26+ and Swift 6.2 (Xcode 26 or current Command Line Tools).

Build the app bundle and open it:

```sh
./scripts/make-app.sh
open build/Clippy.app
```

For a quick development loop:

```sh
swift build && .build/debug/Clippy
```

Use the `.app` bundle for daily usage so the stable bundle id keeps Accessibility permission across rebuilds. `./scripts/make-app.sh 1.2.3` injects an explicit version. Run the test suite with `swift test`.

</details>

<details>
<summary><strong>Project layout</strong></summary>

```text
Sources/Clippy/
  main.swift                       app entry, accessory activation policy
  AppDelegate.swift                wiring: status item, hotkey, services
  Capture/ClipboardMonitor.swift   NSPasteboard changeCount polling + filters
  Storage/                         Clip model, GRDB database, FTS5, categories, archive, media
  Positioning/CaretLocator.swift   AX caret rect + coordinate conversion
  Panel/                           nonactivating panel, placement, editor window
  Paste/                           pasteboard write + simulated Cmd-V keystroke
  AI/                              actions engine, assistant agent, providers, tool defs
  Scripts/                         script model, store, runner
  Integrations/                    1Password, iCloud sync, MCP install + controller
  Support/                         settings, hotkey, keychain, OCR, sounds, theme, icons
  UI/                              SwiftUI views (list, cards, editor, settings, panels)
```

</details>

<details>
<summary><strong>AI configuration</strong></summary>

AI features are off by default. Enable them in Settings > AI and supply a provider key (stored in the Keychain). Supported providers: **OpenAI, Anthropic, Ollama, Azure**.

- **AI actions** run a prompt template against a clip. Templates support `{clip}` and `{instruction}` substitution and per-action temperature, max tokens, and output disposition. The built-ins are editable.
- **The assistant** runs an agentic tool-use loop with tools: `search_clips`, `create_clip`, `list_scripts`, `run_script`, `execute_code`. Script and code execution are off by default and always require per-call confirmation. Code runs as the current user with a 30s timeout and no sandbox; the UI states this plainly.

</details>

<details>
<summary><strong>MCP server and Claude Code plugin</strong></summary>

Clippy ships an MCP server so external AI agents can read and write your clips. The app bundles it and can install it for supported clients from Settings > AI.

- [`integrations/clippy-mcp`](integrations/clippy-mcp) talks directly to Clippy's SQLite database (no running app required) and exposes tools for search, recent, get, add, delete, and category management. See its [README](integrations/clippy-mcp/README.md) and [SCHEMA.md](integrations/clippy-mcp/SCHEMA.md). It uses Node's built-in `node:sqlite` (Node 22.13+), so there are no native dependencies.
- [`integrations/clippy-plugin`](integrations/clippy-plugin) is a Claude Code plugin that registers the server and adds `/clippy-search`, `/clippy-add`, and `/clippy-recent` slash commands.

Override the database path with the `CLIPPY_DB_PATH` environment variable.

</details>

<details>
<summary><strong>Releases and auto-update</strong></summary>

Pushing a version tag runs [`.github/workflows/release.yml`](.github/workflows): tests, an app build at the tag version, an EdDSA-signed zip, a GitHub Release, and a refreshed `appcast.xml` on `main`.

```sh
git tag v1.4.0
git push origin v1.4.0
```

One-time setup before the first release (the private key must never enter the repo):

```sh
# 1) Get Sparkle's key tools
curl -L -o /tmp/sparkle.tar.xz \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.3/Sparkle-2.9.3.tar.xz
mkdir -p /tmp/sparkle-dist && tar -xf /tmp/sparkle.tar.xz -C /tmp/sparkle-dist

# 2) Generate the keypair (private key goes to the login Keychain)
/tmp/sparkle-dist/bin/generate_keys

# 3) Commit the printed public key
echo "<public key from step 2>" > scripts/sparkle-public-key.txt

# 4) Export the private key once and add it as the GitHub Actions secret SPARKLE_ED_PRIVATE_KEY
/tmp/sparkle-dist/bin/generate_keys -x /tmp/sparkle-private-key
cat /tmp/sparkle-private-key | pbcopy && rm /tmp/sparkle-private-key
```

Local builds without a real public key skip the updater wiring. Setting `CODESIGN_IDENTITY` switches `make-app.sh` from an ad-hoc signature to Developer ID signing with the hardened runtime for notarization.

</details>

<details>
<summary><strong>Debug flags</strong></summary>

- `--show-panel` opens the panel immediately after launch.
- `--screenshot [path]` renders the panel to a PNG and exits (used for UI smoke tests).

</details>

<details>
<summary><strong>Roadmap</strong></summary>

Tracked in [`docs/ROADMAP.md`](docs/ROADMAP.md). Near-term items include streaming AI responses, AI vision for image clips, a real sandbox for `execute_code`, assistant conversation persistence, and custom hotkey recording.

Full change history is in [`docs/CHANGELOG.md`](docs/CHANGELOG.md).

</details>
