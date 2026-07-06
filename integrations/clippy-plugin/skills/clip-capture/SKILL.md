---
name: clip-capture
description: Save useful artifacts from the current conversation into the Clippy clipboard manager. Use when the user says "save that", "clip this", "add this to clippy", or asks to keep a command, code snippet, URL, or other text for later reuse.
---

# Clip Capture

Capture worthwhile artifacts from the conversation (shell commands, code snippets, URLs, config blocks, one-liners) into Clippy so the user can paste them later.

## Workflow

1. **Identify the artifact.** Take exactly what the user pointed at. If they said "save that" ambiguously, pick the most recent command/snippet/URL and confirm your choice in one line before saving. Save the raw text, not your commentary around it.

2. **Title it well.** Pass a short, specific `title` to `clippy_add` that says what the clip does, not where it came from. Good: "ffmpeg trim first 10s", "Postgres connection string (staging)". Bad: "snippet", "from conversation".

3. **Categorize when obvious.** Call `clippy_list_categories` first. If an existing category clearly fits (for example "Commands", "URLs", "Snippets"), file the new clip there with `clippy_set_category` after adding it. Do not invent new categories for a single clip unless the user asks.

4. **Confirm.** Report the returned clip id and title. Remind the user that the running Clippy app shows externally added clips on its next capture or relaunch.

## Rules

- One clip per logical artifact. If the user wants three commands saved, that is three `clippy_add` calls with three titles, not one blob.
- Never save secrets (API keys, passwords, tokens) without an explicit request, and warn the user when they ask you to.
- Preserve formatting exactly: keep newlines and indentation in code and config clips.
