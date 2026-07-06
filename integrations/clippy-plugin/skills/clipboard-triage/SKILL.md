---
name: clipboard-triage
description: Organize the user's Clippy clipboard history. Use when the user asks to clean up, sort, categorize, or triage their clipboard, or says things like "organize my clips", "my clipboard is a mess", or "file these clips into categories".
---

# Clipboard Triage

Help the user turn a pile of raw clips into an organized, categorized clipboard history. Work in small, confirmable steps. Never destroy data without explicit approval.

## Workflow

1. **Survey.** Call `clippy_list_recent` (limit 30-50) and `clippy_list_categories`. Summarize what is there: how many clips, what kinds (commands, URLs, code, prose), which are already categorized.

2. **Propose.** Group the uncategorized clips into a handful of themes and map each theme to an existing category when one fits. Only propose new categories when nothing existing fits, and keep the total small (a clipboard manager needs 5-10 categories, not 30). Show the user the plan as a table: clip id, title/preview, proposed category.

3. **Apply.** After the user approves (or adjusts) the plan:
   - Create any missing categories with `clippy_create_category`.
   - File each clip with `clippy_set_category`.
   - Use `clippy_get` when a preview is too short to classify confidently.

4. **Report.** List what was filed where, and anything left unclassified.

## Deletion rules

- Never call `clippy_delete` unprompted.
- If the user asks to prune duplicates or junk, first show the exact clips you intend to delete (id, title, preview) and why, then wait for confirmation before deleting.
- When in doubt, categorize instead of deleting.

## Notes

- Clip previews come back with search/list results; full text requires `clippy_get`.
- The running Clippy app picks up external changes on its next capture or relaunch; mention this after making changes.
