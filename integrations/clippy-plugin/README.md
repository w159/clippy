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
│   └── clip-capture/            # save conversation artifacts into Clippy
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

The `clippy` server exposes eight tools:

| Tool | Purpose |
|---|---|
| `clippy_search` | Full-text search over clips |
| `clippy_list_recent` | Newest clips first, optional `limit` |
| `clippy_get` | Full content of one clip by id |
| `clippy_add` | Add a text clip (optional `title`) |
| `clippy_delete` | Delete a clip by id |
| `clippy_list_categories` | List categories |
| `clippy_set_category` | Add/remove a clip's category membership |
| `clippy_create_category` | Create a category |

## Commands, skills, agent

- `/clippy-search`, `/clippy-add`, `/clippy-recent` are thin wrappers over the tools above.
- `clipboard-triage` skill: survey recent clips, propose a categorization plan, apply it after approval. Never deletes without confirmation.
- `clip-capture` skill: save commands, snippets, and URLs from the conversation into Clippy with useful titles.
- `clip-curator` agent: autonomous dedupe and organization pass; always lists deletion candidates with reasons before any delete.

## Database path

The server reads Clippy's SQLite database directly at `~/Library/Application Support/Clippy/clippy.sqlite`. Set `CLIPPY_DB_PATH` to point elsewhere (useful for testing). The running Clippy app shows externally added or changed clips on its next capture or relaunch.

## Refreshing the vendored server

`mcp/index.mjs` is a build artifact copied from [`../clippy-mcp`](../clippy-mcp). After changing the server source, refresh it with:

```bash
../scripts/sync-mcp.sh
```

or manually:

```bash
cd ../clippy-mcp && npm run build && cp build/index.mjs ../clippy-plugin/mcp/index.mjs
```
