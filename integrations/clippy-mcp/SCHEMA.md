# Clippy Database Schema

Derived by reading the Swift sources (read-only) and confirming against a copy of the live DB. All citations are `file:line` into `Sources/Clippy/Storage/`.

## Database location

- File: `~/Library/Application Support/Clippy/clippy.sqlite`
- Computed in `ClipDatabase.init` from `applicationSupportDirectory` + `"Clippy"` + `"clippy.sqlite"` (`ClipDatabase.swift:25-29`).
- Opened with GRDB's `DatabaseQueue` (`ClipDatabase.swift:34`). GRDB enables WAL journaling by default, so a `clippy.sqlite-wal` and `clippy.sqlite-shm` sit next to it while the app runs.
- Override for the MCP server via env `CLIPPY_DB_PATH`.

## Media location

- Directory: `~/Library/Application Support/Clippy/media/` (`ClipDatabase.swift:30-32`).
- For an image clip, the file on disk is `media/<mediaFilename>` and the thumbnail is `media/<thumbFilename>`. `mediaFilename` is `<sha256>.png`, `thumbFilename` is `<sha256>-thumb.jpg` (`MediaStore.swift:40-42`). The DB stores filenames only; full path = `<mediaDir>/<filename>` (`MediaStore.swift:30-32`).

## Tables

Schema comes from the GRDB migrator (`ClipDatabase.makeMigrator()`, `ClipDatabase.swift:39-138`), evolved across migrations v1..v4. Final column set verified against the live file.

### `clips`  (`ClipDatabase.swift:42-52`, `105-114`, `115-120`; model `Clip.swift:9-27`)

| column | type | notes |
|---|---|---|
| `id` | INTEGER | autoincrement primary key |
| `contentText` | TEXT NOT NULL | the clip's plain text |
| `contentRTF` | BLOB | nullable rich text |
| `contentHTML` | BLOB | nullable HTML |
| `typeIdentifier` | TEXT NOT NULL | UTI, e.g. `public.utf8-plain-text` |
| `sourceAppBundleID` | TEXT | nullable |
| `sourceAppName` | TEXT | nullable |
| `createdAt` | DATETIME NOT NULL | text format `YYYY-MM-DD HH:MM:SS.SSS` in **UTC** (GRDB Date encoding) |
| `contentKind` | TEXT NOT NULL DEFAULT 'text' | `'text'` or `'image'` (`ClipContentKind`, `Clip.swift:4-7`) |
| `mediaFilename` | TEXT | image clips only |
| `thumbFilename` | TEXT | image clips only |
| `pixelWidth` | INTEGER | image clips only |
| `pixelHeight` | INTEGER | image clips only |
| `byteSize` | INTEGER | image clips only |
| `userTitle` | TEXT | nullable custom display name (`ClipDatabase.swift:115-120`) |

Note: the `isPinned` column existed in v1 but was **dropped** in migration v2 (`ClipDatabase.swift:101-103`). Pinning is now category membership.

### `category`  (`ClipDatabase.swift:60-70`; model `Category.swift:12-22`)

| column | type | notes |
|---|---|---|
| `id` | INTEGER | autoincrement primary key |
| `name` | TEXT NOT NULL | |
| `colorHex` | TEXT NOT NULL | e.g. `#FF9500` |
| `iconKind` | TEXT NOT NULL | `symbol` / `emoji` / `appLogo` (`CategoryIconKind`, `Category.swift:4-8`) |
| `iconValue` | TEXT NOT NULL | SF Symbol name, emoji, or bundle id |
| `sortOrder` | INTEGER NOT NULL DEFAULT 0 | |
| `isStarter` | BOOLEAN NOT NULL DEFAULT 0 | at most one row may have `isStarter=1` (unique index `category_single_starter`, `ClipDatabase.swift:81-83`) |
| `createdAt` | DATETIME NOT NULL | UTC text, same format as above |

A starter "Pinned" category is seeded in v2 (`ClipDatabase.swift:86-92`).

### `clip_category`  (junction, `ClipDatabase.swift:71-78`; model `Category.swift:30-35`)

| column | type | notes |
|---|---|---|
| `clipID` | INTEGER NOT NULL | FK -> `clips(id)` ON DELETE CASCADE |
| `categoryID` | INTEGER NOT NULL | FK -> `category(id)` ON DELETE CASCADE |
| `addedAt` | DATETIME NOT NULL | UTC text |

Primary key is `(clipID, categoryID)`. Membership add uses `INSERT OR IGNORE`, remove uses `DELETE ... WHERE clipID=? AND categoryID=?` (`ClipDatabase+Categories.swift:101-115`).

### `clips_fts`  (FTS5, `ClipDatabase.swift:54-58`, recreated at `131-137`)

- Virtual table using FTS5, `unicode61` tokenizer.
- Columns indexed: `contentText`, `userTitle`.
- Synchronized with `clips` via GRDB `t.synchronize(withTable: "clips")`, which creates three triggers on `clips`: `__clips_fts_ai` (after insert), `__clips_fts_ad` (after delete), `__clips_fts_au` (after update). Confirmed present in the live DB.
- **Consequence for the MCP server:** a plain `INSERT INTO clips` or `DELETE FROM clips` keeps `clips_fts` correct automatically. No manual FTS maintenance is needed, and doing so would double-index.

## Search SQL  (`ClipDatabase.swift:279-294`)

The app builds an FTS5 "match all prefixes" pattern from the query, then runs:

```sql
SELECT clips.* FROM clips
JOIN clips_fts ON clips_fts.rowid = clips.id
WHERE clips_fts MATCH ?
ORDER BY rank
LIMIT ?
```

The MCP server mirrors this. It builds a prefix pattern by tokenizing the query and appending `*` to each term (e.g. `foo bar` -> `foo* bar*`), matching `FTS5Pattern(matchingAllPrefixesIn:)` behavior, with terms quoted to neutralize FTS operators.

## Date handling

GRDB stores `Date` as `YYYY-MM-DD HH:MM:SS.SSS` in UTC. The MCP server writes `createdAt`/`addedAt` in exactly this format (UTC) so the app parses them, and converts them back to ISO-8601 on read for callers.

The JSON stores below use a different shape: Swift's `.iso8601` strategy, which is whole seconds with a `Z` suffix and **no fractional part** (`2026-09-16T21:04:07Z`). `JSON.stringify(new Date())` produces milliseconds and will not decode, so `stores.ts` strips them (`swiftISODate`). `test/smoke.mjs` asserts the shape on disk.

## JSON stores (not in the database)

Scripts and AI actions live in files beside `clippy.sqlite`, written by the app's generic `JSONFileStore` (`Support/JSONFileStore.swift`) with `outputFormatting = [.prettyPrinted, .sortedKeys]`. The MCP server matches that formatting so a file written by either side diffs cleanly, and writes atomically via a temp file plus rename.

### `scripts.json`  (`Scripts/Script.swift`, `Scripts/ScriptStore.swift`)

| key | type | notes |
|---|---|---|
| `id` | String | uppercase UUID |
| `name` | String | |
| `interpreter` | String | `zsh` \| `bash` \| `sh` \| `python3` \| `node` \| `ruby` \| `applescript` \| `swift` |
| `body` | String | source, written to a temp file and executed |
| `feedsClipboard` | Bool | clip arrives on stdin and in `$CLIPPY_CLIP` |
| `outputToClipboard` | Bool | stdout offered as a new clip |
| `createdAt` / `updatedAt` | String | Swift `.iso8601`, whole seconds |
| `sortOrder` | Int | display order |
| `isEnabled` | Bool | **false for anything the MCP server writes.** `ScriptRunner.run` refuses a disabled script (`Scripts/ScriptRunner.swift`). Absent in JSON written by builds before this key existed, where it decodes to `true`. |

### `ai-actions.json`  (`AI/AIAction.swift`)

| key | type | notes |
|---|---|---|
| `id` | String | uppercase UUID |
| `name` | String | label on the clip menu |
| `promptTemplate` | String | must contain `{clip}` |
| `outputDisposition` | String | `proposeEdit` \| `copyToClipboard` \| `newClip` |
| `temperature` | Double | |
| `maxTokens` | Int | |
| `symbolName` | String | SF Symbol |
| `iconKind` | String | `symbol` |
| `isBuiltIn` | Bool | built-ins are editable but not deletable |
| `sortOrder` | Int | |

## Cross-process visibility

`ClipStore` observes the database with GRDB `ValueObservation`, which [does not detect changes made through external connections](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/valueobservation). The JSON stores are worse: the app holds them in memory, so its next save clobbers an external write.

`Storage/ExternalChangeWatcher.swift` closes both gaps on a 2s poll:

- SQLite `PRAGMA data_version`, which increments on commits from *other* connections and is unchanged for the reading connection's own commits. Clippy uses a single `DatabaseQueue`, so this is a false-positive-free signal. On a change it calls `Database.notifyChanges(in: .fullDatabase)`, GRDB's documented escape hatch for undetected changes.
- `scripts.json` / `ai-actions.json` modification dates, compared against the store's own last load or save (`JSONFileStore.reloadIfModifiedExternally`).
