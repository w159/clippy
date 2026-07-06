---
description: Show the most recent clips from Clippy's clipboard history.
argument-hint: "[count]"
---

Show the user's most recent Clippy clips.

If **$ARGUMENTS** is a number, pass it as `limit` to the `clippy_list_recent` MCP tool; otherwise call it with no arguments (default limit). Present the results as a compact list, one clip per line: `[id] title - preview`, newest first, including categories when present. Offer to open any clip in full with `clippy_get` if the user wants the complete text.
