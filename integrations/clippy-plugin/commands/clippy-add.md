---
description: Add a new text clip to Clippy's clipboard history.
argument-hint: <text to save as a clip>
---

Add a new plain-text clip to the user's Clippy clipboard manager containing: **$ARGUMENTS**

Use the `clippy_create_clip` MCP tool with `text` set to the text above. If the user clearly intended a custom title (for example they wrote `title: ...`), pass it as the `title` argument; otherwise omit it.

After it succeeds, confirm with the returned clip id. The clip appears in the running app within about two seconds.
