# clippy (Claude Code plugin)

Drive the [Clippy](../../README.md) macOS clipboard manager from Claude Code. The plugin is self-contained: it ships a bundled MCP server (no install step beyond Node 22+), slash commands, two skills, and a curator agent.

## Layout

```
clippy-plugin/
├── .claude-plugin/plugin.json   # manifest
├── .mcp.json                    # registers the bundled MCP server (stdio)
├── mcp/index.mjs                # vendored clippy-mcp bundle (built from ../clippy-mcp)
├── commands/
│   ├── clippy-search.md         # /clippy-search <terms>
│   ├── clippy-add.md            # /clippy-add <text>
│   └── clippy-recent.md         # /clippy-recent [count]
├── skills/
│   ├── clipboard-triage/        # organize and categorize clipboard history
│   ├── clip-capture/            # save conversation artifacts into Clippy
│   └── clip-automation/         # create and edit scripts and AI actions
└── agents/
    └── clip-curator.md          # autonomous dedupe/organize agent
```

## Install

From this repository:

```bash
claude plugin marketplace add /path/to/clippy   # or the git URL
claude plugin install clippy@clippy
```

Requires Node 22.13+ on PATH (the server uses the built-in `node:sqlite`).

## MCP tools

Twenty-two tools across four families, plus five deprecated aliases kept so
existing configs keep working.

**Orientation**

| Tool | Purpose |
|---|---|
| `clippy_stats` | Counts, category breakdown, top source apps. Start here for open-ended asks. |

**Clips**

| Tool | Purpose |
|---|---|
| `clippy_search_clips` | Full-text search, filterable by kind, category, source app |
| `clippy_list_recent` | Newest clips first |
| `clippy_get_clip` | One clip in full, including media paths |
| `clippy_create_clip` | Save a new text clip, optionally filed |
| `clippy_update_clip` | Rewrite a clip's text and/or title |
| `clippy_delete_clips` | Delete many ids in one call |

**Categories**

| Tool | Purpose |
|---|---|
| `clippy_list_categories` | Categories with clip counts |
| `clippy_create_category` | Create one |
| `clippy_update_category` | Rename, recolor, re-icon, reorder |
| `clippy_delete_category` | Delete the board; its clips are released, not deleted |
| `clippy_assign_clips` | File or unfile many clips at once |

**Scripts** (`clippy_list_scripts`, `clippy_get_script`, `clippy_create_script`,
`clippy_update_script`, `clippy_delete_script`)

Clippy executes scripts, so anything created or edited over MCP lands
**disabled** and the app refuses to run it until a human reviews the body and
enables it in Settings > Scripts. There is no parameter to enable one from here.

**AI actions** (`clippy_list_ai_actions`, `clippy_get_ai_action`,
`clippy_create_ai_action`, `clippy_update_ai_action`, `clippy_delete_ai_action`)

The one-click prompts on a clip's menu. A prompt template must contain `{clip}`.
Built-in actions can be edited but not deleted.

**Deprecated aliases:** `clippy_search`, `clippy_get`, `clippy_add`,
`clippy_delete`, `clippy_set_category` forward to their replacements.

Search and list results are 300-character previews. Full clip text comes from
`clippy_get_clip` on a specific id, so a broad search does not spray a clipboard
history into a transcript. Every call is logged to stderr with the tool name and
argument shape.

## Commands, skills, agent

- `/clippy-search`, `/clippy-add`, `/clippy-recent` are thin wrappers over the tools above.
- `clipboard-triage` skill: survey recent clips, propose a categorization plan, apply it after approval. Never deletes without confirmation.
- `clip-capture` skill: save commands, snippets, and URLs from the conversation into Clippy with useful titles.
- `clip-automation` skill: create and edit Clippy's scripts and AI actions, including the disabled-on-create rule for scripts.
- `clip-curator` agent: autonomous dedupe and organization pass; always lists deletion candidates with reasons before any delete.

## Database path

The server reads and writes Clippy's SQLite database directly at
`~/Library/Application Support/Clippy/clippy.sqlite`, and the `scripts.json` /
`ai-actions.json` files beside it. Set `CLIPPY_DB_PATH` to point elsewhere
(useful for testing); the other two are resolved relative to it.

The running app notices these writes within about two seconds. GRDB's
`ValueObservation` cannot see commits from another process, so Clippy polls
SQLite's `data_version` and the two JSON files' modification dates, then tells
GRDB to republish. Before that, a clip added over MCP stayed invisible until the
next in-app write or a relaunch.

## Refreshing the vendored server

`mcp/index.mjs` is a build artifact copied from [`../clippy-mcp`](../clippy-mcp). After changing the server source, refresh it with:

```bash
../scripts/sync-mcp.sh
```

or manually:

```bash
cd ../clippy-mcp && npm run build && cp build/index.mjs ../clippy-plugin/mcp/index.mjs
```
