# clippy-mcp

An MCP server that lets Claude read and write the [Clippy](../../) macOS clipboard manager's data: clips, categories, scripts, and AI actions. It talks directly to Clippy's GRDB/SQLite database and to the two JSON stores beside it (no app API needed).

See [SCHEMA.md](./SCHEMA.md) for the exact tables, columns, FTS setup, JSON shapes, and file:line citations the server was built from.

## Tools

### Orientation

| Tool | Purpose |
|---|---|
| `clippy_stats()` | Totals, filed/unfiled split, kind breakdown, categories with counts, top source apps. |

### Clips

| Tool | Purpose |
|---|---|
| `clippy_search_clips(query, kind?, categoryID?, sourceApp?, limit?)` | FTS5 search with filters. Returns 300-char previews. |
| `clippy_list_recent(kind?, limit?)` | Most recent clips, newest first. |
| `clippy_get_clip(id)` | One clip in full, incl. contentText and media/thumb file paths. |
| `clippy_create_clip(text, title?, categoryID?)` | Insert a text clip, optionally filed. |
| `clippy_update_clip(id, text?, title?)` | Rewrite a clip's content and/or title. |
| `clippy_delete_clips(ids[])` | Delete up to 500 clips in one call. |

### Categories

| Tool | Purpose |
|---|---|
| `clippy_list_categories()` | All categories with clip counts. |
| `clippy_create_category(name, colorHex?, iconKind?, iconValue?)` | Create a category. |
| `clippy_update_category(id, name?, colorHex?, iconKind?, iconValue?, position?)` | Rename, recolor, re-icon, reorder. |
| `clippy_delete_category(id)` | Delete the board. Clips are released, not deleted. Starter category is protected. |
| `clippy_assign_clips(clipIDs[], categoryID, member)` | File or unfile up to 500 clips at once. |

### Scripts

`clippy_list_scripts()`, `clippy_get_script(id)`, `clippy_create_script(...)`,
`clippy_update_script(id, ...)`, `clippy_delete_script(id)` over `scripts.json`.

**Scripts created or edited here land `isEnabled: false`.** Clippy executes
scripts as the signed-in user, so a tool that could both write and enable one
would be a path from any connected MCP client to arbitrary shell on the Mac.
`ScriptRunner` refuses a disabled script, and there is deliberately no parameter
to enable one - that requires a human in Settings > Scripts. An edit re-disables,
because the previous approval was for the previous body.

### AI actions

`clippy_list_ai_actions()`, `clippy_get_ai_action(id)`,
`clippy_create_ai_action(...)`, `clippy_update_ai_action(id, ...)`,
`clippy_delete_ai_action(id)` over `ai-actions.json`. Prompt templates must
contain `{clip}`. Built-in actions can be edited but not deleted.

### Deprecated aliases

`clippy_search`, `clippy_get`, `clippy_add`, `clippy_delete`, and
`clippy_set_category` still work on their original schemas and forward to their
replacements. They will be removed once pinned client configs have moved.

The FTS index (`clips_fts`) is kept in sync automatically by Clippy's own database triggers, so clip writes need no manual FTS maintenance.

## JSON Schema dialect

Tool schemas are serialized with `zodToJsonSchema(..., { target: "jsonSchema7" })`.
This is load-bearing: the `openApi3` target emits the draft-04 boolean form
`"exclusiveMinimum": true`, which MCP clients reject, and a tool whose schema
fails validation is dropped from the model's tool list **with no error**. Five of
the original eight tools were invisible this way. `test/smoke.mjs` walks every
advertised schema and fails the build on a non-numeric `exclusiveMinimum`.

## Prerequisites

- Node.js 22.13 or newer. The server uses Node's built-in `node:sqlite` module, which is available unflagged from v22.13, so there are no native dependencies to compile or ship.
- Clippy installed and launched at least once (so the database exists). The default DB path is `~/Library/Application Support/Clippy/clippy.sqlite`.

## Build

```bash
cd integrations/clippy-mcp
npm install
npm run build
```

This bundles everything into a single `build/index.mjs` (the server entry point) via esbuild. `npm test` builds, then runs an offline smoke test against a throwaway database. The Clippy app ships this same file inside its bundle at `Clippy.app/Contents/Resources/clippy-mcp/index.mjs` and launches it on demand, so installed users do not need to build anything.

## Configuration

The server resolves the database at `~/Library/Application Support/Clippy/clippy.sqlite`. Override with the `CLIPPY_DB_PATH` environment variable.

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "clippy": {
      "command": "node",
      "args": ["/Users/jerry/Downloads/clippy/integrations/clippy-mcp/build/index.mjs"]
    }
  }
}
```

### Claude Code (project `.mcp.json`)

Add to a `.mcp.json` at your project root:

```json
{
  "mcpServers": {
    "clippy": {
      "command": "node",
      "args": ["/Users/jerry/Downloads/clippy/integrations/clippy-mcp/build/index.mjs"]
    }
  }
}
```

Use an absolute path to `build/index.mjs`. To point at a non-default database, add `"env": { "CLIPPY_DB_PATH": "/path/to/clippy.sqlite" }`.

## Live refresh

Writes made here appear in the running app within about two seconds.

GRDB's `ValueObservation` does not detect commits from another connection, and
the app holds `scripts.json` / `ai-actions.json` in memory, so before this the
app not only failed to show an MCP write, its next save overwrote one. Clippy now
runs an `ExternalChangeWatcher` that polls SQLite's `data_version` (which
increments only for commits from *other* connections, so the app's own captures
never trip it) and the two JSON files' modification dates, then calls
`Database.notifyChanges(in: .fullDatabase)` to make observation republish.

## Safety

- All SQL uses parameterized statements; user input is never interpolated into SQL.
- WAL mode is set on connect to cooperate with the app's connection, plus
  `busy_timeout = 5000` so a write landing while the app holds the lock waits
  instead of failing with `SQLITE_BUSY`.
- Scripts written here are disabled until a human enables them (see above).
- Search and list results carry 300-character previews; full clip text requires
  `clippy_get_clip` on a specific id, so a broad search does not dump a whole
  clipboard history - which at a regulated firm is client data - into a transcript.
- Every tool call writes one audit line to stderr (timestamp, outcome, tool name,
  argument key names, never argument values). Clippy captures that stream, so
  "what did the assistant read and change" is answerable after the fact.
- JSON stores are written atomically (temp file plus rename), so the app never
  reads a half-written file.
- No secrets are stored in code.
