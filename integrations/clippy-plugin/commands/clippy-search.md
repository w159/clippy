---
description: Search the Clippy clipboard history (full-text) and show matching clips.
argument-hint: <search terms>
---

Search the user's Clippy clipboard manager for clips matching: **$ARGUMENTS**

Use the `clippy_search` MCP tool with `query` set to the text above (default limit is fine). Then present the results as a compact list, one clip per line: `[id] title - preview` followed by its categories if any. If nothing matches, say so and suggest `clippy_list_recent` to browse instead.

Do not invent clip contents; only report what the tool returns.
