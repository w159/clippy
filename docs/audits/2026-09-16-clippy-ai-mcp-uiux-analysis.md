# Clippy: AI, MCP, and UI/UX Analysis

Date: 2026-09-16
Scope: MCP tool surface, AI integration, clip-list UI/UX
Baseline: v1.8.2 (commit 72bf808), macOS 27.0, Swift 6.4, `.macOS(.v26)` package floor

This is incremental on `docs/audits/2026-06-22-clippy-uiux-audit.md` and its
implementation note. The June audit's open items (Dynamic Type in `Theme.swift`,
top/bottom drop cue, word-level diff in AIActionSheet) are not re-reported here.

---

## 1. Executive summary

Three findings account for most of what feels broken.

1. **Five of the eight MCP tools never reach the model.** They emit
   `"exclusiveMinimum": true`, the draft-04 boolean form, which MCP clients reject
   and drop silently. The three surviving tools are `clippy_add`,
   `clippy_create_category`, `clippy_list_categories`, i.e. write-only, no search,
   no read, no delete. Fixed in this session, verified below.
2. **Even with all eight restored, the requested workflow is impossible.** There is
   no update path for clips or categories, and scripts and AI actions live in JSON
   files the MCP server never opens. Separately, GRDB's `ValueObservation` does not
   observe writes from an external process, so an MCP write does not appear in the
   running app at all.
3. **Categories are not being used: 600 of 644 clips (93%) are uncategorized**, and
   2 of 6 categories are empty. The organizing model the UI is built around is not
   the one being used. That, not theming, is why the list feels undifferentiated.

Plus one bug flooding the logs: **1273 of 1313 log lines (97%) are
`Failed to save file clip: unreadableFile`.** Copying a folder in Finder fails every
time, silently.

Apple Intelligence is available on this machine right now and is not used anywhere in
the codebase.

---

## 2. MCP: what is wrong and what to build

### 2.1 The schema bug (fixed, verified)

`src/index.ts:46` serialized every tool schema with `zodToJsonSchema(t.schema, { target: "openApi3" })`.
OpenAPI 3.0 inherits draft-04 numeric keywords, so `z.number().int().positive()`
became `{"type":"integer","exclusiveMinimum":true,"minimum":0}`. MCP clients validate
against draft-07+, where `exclusiveMinimum` must be a number. A tool whose schema
fails validation is dropped from the tool list with no user-visible error, which is
why this went unnoticed.

Every tool taking an `id`, `clipID`, `categoryID`, or `limit` was affected, and only
those:

| Tool | Numeric param | Reached the model before the fix |
|---|---|---|
| `clippy_search` | `limit` | no |
| `clippy_list_recent` | `limit` | no |
| `clippy_get` | `id` | no |
| `clippy_delete` | `id` | no |
| `clippy_set_category` | `clipID`, `categoryID` | no |
| `clippy_add` | none | yes |
| `clippy_list_categories` | none | yes |
| `clippy_create_category` | none | yes |

Fix applied: `target: "jsonSchema7"`. Rebuilt and synced into the plugin bundle.

```
$ node build/index.mjs  (tools/list probe)
 tools: 8 boolean exclusiveMinimum: 0
 clippy_get.id -> {"type": "integer", "exclusiveMinimum": 0, "description": "Clip id."}
$ node ../clippy-plugin/mcp/index.mjs  (same probe)
 tools: 8 boolean exclusiveMinimum: 0
```

Before the fix the same probe printed `"exclusiveMinimum": true` on all five.

**The fix does not reach the running server yet.** There are three copies of the bundle
and `sync-mcp.sh` writes only two of them:

| Copy | Updated by | Current |
|---|---|---|
| `integrations/clippy-mcp/build/index.mjs` | `npm run build` | fixed |
| `integrations/clippy-plugin/mcp/index.mjs` | `sync-mcp.sh` | fixed |
| `/Applications/Clippy.app/Contents/Resources/clippy-mcp/index.mjs` | `scripts/make-app.sh:62`, at app build | **stale** |

The live server is the third one: `~/.claude.json` registers `clippy` as
`{"type":"http","url":"http://127.0.0.1:6015/mcp"}`, and port 6015 is held by
`/Applications/Clippy.app/Contents/Resources/clippy-mcp/index.mjs` (pid 948), spawned by
`McpServerController`. Its hash differs from the rebuilt bundle. The fix ships when
Clippy.app is next built and installed; the client also negotiates its tool list at
startup, so the client must restart after that. Worth adding the app-bundle copy to
`sync-mcp.sh`, or having `make-app.sh` fail loudly when `build/index.mjs` is older than
`src/`.

**This is a contract the repo should hold permanently.** Add a case to
`test/smoke.mjs` that walks `tools/list` and fails on any non-numeric
`exclusiveMinimum` / `exclusiveMaximum`. The bug class recurs on any zod-to-schema
target change.

### 2.2 The architectural problem: external writes are invisible

`ClipStore` observes the database with GRDB `ValueObservation`
(`UI/ClipStore.swift:78,109`). GRDB documents plainly that ValueObservation "does not
detect or notify about changes made through external database connections," and that
cross-process observation needs a separate notification mechanism. The MCP server is a
separate Node process opening the same file with `node:sqlite`.

Consequence: `clippy_add` inserts a row that the running app will not show until the
next in-app write or an app restart. "Tell Claude to add this clip" produces a clip
the user cannot see. Same for category changes.

`src/db.ts:openDatabase` also sets `journal_mode` and `foreign_keys` but no
`busy_timeout`. Two writers on one WAL file with no busy timeout gives intermittent
`SQLITE_BUSY` failures under ordinary use.

Two ways out:

- **A. Route writes through the app (recommended).** The app already runs an
  `McpServerController` and an `McpInstallService`; the June work (S3388) also built a
  Unix-domain-socket path. Make the MCP server a thin client that hands mutations to
  the app, which performs them through its own GRDB connection. Observation then works
  by construction, in-app validation and eviction rules apply, and there is exactly one
  writer. This is the design that makes "manage everything from Claude" actually work.
- **B. Keep direct SQLite writes, add a change signal.** MCP writes, then pokes the app
  (Darwin notification / `CFNotificationCenterGetDarwinNotifyCenter`); the app responds
  with `db.notifyChanges(in: .fullDatabase)` inside a write transaction. Cheaper, but
  leaves two writers, needs `PRAGMA busy_timeout`, and every app-side invariant
  (history cap, eviction, FTS assumptions, media sweeping) has to be re-implemented or
  bypassed in Node.

Pick A. B is a stopgap.

### 2.3 The CRUD gap against the actual request

| Asked for | Today |
|---|---|
| Add clips | `clippy_add` |
| Remove clips | `clippy_delete` (single, no batch) |
| **Update / edit clips** | **nothing** - no tool writes `contentText` or `userTitle` |
| Create categories | `clippy_create_category` |
| **Rename / recolor / delete categories** | **nothing** |
| **Add / update scripts** | **nothing** - `scripts.json` is outside the DB |
| **Add / update AI actions** | **nothing** - `ai-actions.json` is outside the DB |

Scripts and AI actions are `JSONFileStore`-backed files in Application Support
(`scripts.json`, 5 entries; `ai-actions.json`, 12 entries), and the MCP server only
ever opens `clippy.sqlite`. That is the concrete reason "add a script that does X" is
impossible today. It is a storage decision, not a missing function: either the MCP
server learns those two JSON stores, or scripts and AI actions move into the database.
If option A above is taken, the question dissolves, because the app owns both stores
already.

Field shapes are stable and small, so either path is cheap:

- `Script`: `id, name, interpreter, body, outputToClipboard, feedsClipboard, sortOrder, createdAt, updatedAt`
- `AIAction`: `id, name, promptTemplate, outputDisposition, temperature, maxTokens, symbolName, iconKind, isBuiltIn, sortOrder`

### 2.4 Proposed tool surface

Nineteen tools, five groups. Names are verb-first and consistent; every write has a
matching read.

**Orientation**
- `clippy_stats` - clip count, category counts, uncategorized count, DB path, app
  version. One call that tells a fresh model what it is working with. Today a model
  must guess.

**Clips**
- `clippy_search_clips` (text, filters: kind, category, source app, date range)
- `clippy_get_clip`
- `clippy_create_clip`
- `clippy_update_clip` (title and/or content) - new
- `clippy_delete_clips` (batch) - replaces the single-id `clippy_delete`

**Categories**
- `clippy_list_categories`
- `clippy_create_category`
- `clippy_update_category` (name, color, icon, order) - new
- `clippy_delete_category` - new
- `clippy_assign_clips` (batch add/remove across many clips at once) - replaces
  `clippy_set_category`. Filing 600 uncategorized clips one call at a time is the
  difference between a usable workflow and an unusable one.

**Scripts**
- `clippy_list_scripts`, `clippy_get_script`, `clippy_create_script`,
  `clippy_update_script`, `clippy_delete_script` - all new

**AI actions**
- `clippy_list_ai_actions`, `clippy_create_ai_action`, `clippy_update_ai_action`,
  `clippy_delete_ai_action` - all new

**Renaming breaks callers.** The three renames above (`clippy_search` ->
`clippy_search_clips`, `clippy_delete` -> `clippy_delete_clips`, `clippy_set_category`
-> `clippy_assign_clips`) are hardcoded across nine files: `clip-curator.md` (4),
`clippy-plugin/README.md` (8), the three `commands/*.md` (1 each), `clip-capture/SKILL.md`
(3), `clipboard-triage/SKILL.md` (6), `clippy-mcp/README.md` (10), and `test/smoke.mjs`
(17, including a hardcoded `expected` list). Plus any user-side MCP config. Land the
renames and every caller in one change, or keep the old names as aliases for one release.
Do not ship the rename alone.

### 2.5 Descriptions: the problem is leakage, not length

The current descriptions are not too short. They describe the schema instead of the
task. `clippy_set_category` says it "inserts the `clip_category` row (idempotent)."
A model does not have rows; it has a goal. `clippy_create_category` mentions
`isStarter` and `sortOrder`, neither of which a caller should think about.

Rewrite each to answer three things in this order: what job it does, when to reach for
it over a neighbouring tool, and what it returns. Name the composition explicitly,
because tools that chain are the ones models get wrong.

Before:

> Add or remove a clip's membership in a category. member=true inserts the
> clip_category row (idempotent); member=false removes it.

After:

> File clips into a category, or remove them from one. Use after `clippy_search_clips`
> to organize results in bulk: pass the ids you got back. Categories come from
> `clippy_list_categories`; create one first with `clippy_create_category` if none
> fits. A clip can be in several categories. Returns the per-clip result.

Two supporting changes:
- Every tool result should carry ids the next tool accepts. Search already does; the
  script and AI-action tools must too.
- The `clippy-plugin` skills (`clipboard-triage`, `clip-capture`) should document the
  intended chains once, instead of every tool description re-explaining them.

### 2.6 Safety (non-negotiable at a registered adviser)

**Script tools are an RCE vector by construction.** Clippy executes scripts. If any
MCP client can write `scripts.json`, any MCP client can land arbitrary shell in an app
that runs it. Required design answer, one of:
- Scripts created over MCP land **disabled** and require an explicit enable in the UI, or
- Every MCP-created script is flagged `origin: mcp` and routed through the existing
  per-run `confirmHook` regardless of the user's confirmation setting.

Take the first. It fails closed and needs no runtime state.

**Clip history at an RIA is client PII by definition.** 644 clips of whatever has been
copied: account numbers, client names, credentials pulled from 1Password. An MCP server
that returns full `contentText` to any connected client is an exfiltration surface that
an examiner will ask about under Safeguards and Reg S-P. Required:
- Default search and list results to the 300-char preview they already return; full
  content only from `clippy_get_clip` on an explicit id.
- Log every MCP call with the tool name and argument key names (never values), so
  there is an audit trail. This is cheap and it is the answer to "who read what."

Correction to an earlier draft of this section: there is no concealed-clip handling to
honor in the read path, because there are no concealed clips in the database to begin
with. `ClipboardMonitor.skippedTypes` drops anything carrying
`org.nspasteboard.ConcealedType` at capture, so a 1Password copy is never stored. That
is a stronger control than redaction on read, and it means the exposure is ordinary
clips that happen to contain sensitive text - which the preview default addresses and
redaction could not.

### 2.7 Housekeeping

- `@modelcontextprotocol/sdk`'s low-level `Server` class is deprecated in the pinned
  version (TS 6385, four call sites in `src/index.ts`). Migrate to `McpServer` while
  reworking the tool surface rather than after.
- `integrations/clippy-mcp/node_modules` was effectively empty at the start of this
  session, so `sync-mcp.sh` would have failed for anyone cloning fresh. `npm install`
  restored it. Worth a line in the MCP README's build step.

---

## 3. AI integration

### 3.1 Apple Intelligence is available and unused

Verified on this machine:

```
$ cat /tmp/fmprobe.swift
import FoundationModels
let m = SystemLanguageModel.default
print("availability:", m.availability)
$ swift /tmp/fmprobe.swift
availability: available
```

macOS 27.0, Swift 6.4, package floor already `.macOS(.v26)`. Zero references to
`FoundationModels` anywhere under `Sources/`. `docs/ROADMAP.md` lists this as deferred;
the reason it was deferred (platform floor) no longer holds.

The architecture is ready for it. `AIAgentProviderFactory.make(kind:config:)` already
switches over `AIProviderKind`, and there are four conforming providers with a shared
streaming and tool-calling interface (`AIAgent.swift:724`). A `FoundationModelsAgentProvider`
is a fifth case, gated on `SystemLanguageModel.default.availability`, with the Settings
AI tab gaining an option that is disabled with the availability reason when the model is
not ready.

One thing I did not verify and should be confirmed before committing to a design:
whether `LanguageModelSession` tool-calling maps cleanly onto the existing `AITool`
protocol (`AIToolDefinition.swift:12`). Check the guided-generation and `Tool` protocol
shape against the current SDK before writing the provider. Do not reconstruct that API
from memory.

Why it matters beyond "another provider": every AI feature in Clippy today requires an
API key and ships clipboard contents to a third party. At this firm that is the reason
to leave AI turned off. An on-device provider makes the default-on features below
defensible under Safeguards and Reg S-P, because nothing leaves the machine.

### 3.2 Where on-device AI earns its place

The current AI surface is a chat panel plus 12 template-driven AI actions, both of which
the user has to go and invoke. The value of a local, free, instant model is that it can
run without being asked.

Highest value, in order:

1. **Auto-titling on capture.** 43 of 644 clips (7%) have a user title; the rest display
   their source app name. The list is a wall of "Microsoft Edge Dev". A local model
   titling each clip on capture fixes the single worst information-hierarchy problem in
   the app, and there is already a batch AI-title path to reuse
   (`ClipListView.runBatchAITitles`).
2. **Auto-filing into categories.** 93% uncategorized. Given the existing category
   names and a new clip, suggest a category; file it on accept, or file silently above a
   confidence threshold with an undo. This is the feature that makes categories real.
3. **Semantic search.** FTS5 prefix matching cannot find "the postgres connection string"
   when the clip says `DATABASE_URL=...`. Embeddings over `contentText`, stored in the
   same SQLite file, hybrid-ranked with the existing FTS results. Local embeddings keep
   this free and private.
4. **Sensitive-content detection on capture.** A local classifier flagging API keys,
   account numbers, and SSNs, auto-concealing the clip. This is a compliance control, not
   a convenience, and it is the most defensible AI feature in the app.
5. **Smart paste transforms.** "Paste this as JSON", "paste as a markdown table",
   "paste with the client name removed" from the paste bar, using the local model.

Items 1, 2, and 4 run on capture and must be off the capture path. The June race-condition
fix (v1.8.2) made capture resolution timing load-bearing; do this work on the existing
`captureQueue` after the row is written, never inline.

### 3.3 Chat panel

The assistant panel is well built (streaming, tool activity, inline confirmation cards,
retry, selectable text). Two gaps stand out, both already on the roadmap:

- Conversations do not survive a restart. Given that the panel is where the MCP-like
  work happens in-app, this is the difference between a tool and a toy.
- `execute_code` has no sandbox; the control is per-call confirmation plus a 30s timeout.
  The roadmap is honest about it. With Apple Intelligence making AI default-on, this
  becomes higher priority than it was when AI was opt-in.

---

## 4. UI/UX

### 4.1 Read the numbers first

- 644 clips, **600 uncategorized (93%)**, 44 category memberships total.
- 6 categories; the screenshot shows 2 of them empty (`claude` 0, `variables` 0).
- 43 clips (7%) have a user title. The other 93% display a source app name.
- 6 image clips out of 644.

The app's primary organizing affordance is used by 7% of the content. Either the filing
cost is too high (it is: one clip at a time, via a submenu) or the model is wrong for how
clipboard history is actually consumed. Both are true.

### 4.2 The card is the problem

From `img/clippy_main_window.png`:

**Information hierarchy is inverted.** The largest, brightest text on each card is the
source application name, with its icon. The clip content, the only thing anyone scans
for, is below it in smaller grey text. "Microsoft Word / integration" spends its visual
budget telling you it came from Word. Fix: content is the headline; source app becomes a
small icon in the metadata row. This is also what auto-titling (3.2) feeds.

**Density.** Each card is roughly 125px tall with a full-width border and a single line
of content. Seven clips fill a 1178px-tall window. A clipboard manager is a scanning
surface; 7 visible items means paging through 644 clips is hopeless. Offer a compact
row mode (one line, ~32px) alongside the current card mode, and make compact the default
for the History pane.

**Border noise.** Every card carries a saturated 1px stroke, and the colors vary per card
(purple, green, blue). The selection ring is also a saturated stroke, so selection has to
compete with decoration for the same signal. Fix: drop per-card strokes; use a subtle
fill for grouping and reserve a stroke for selection alone.

**Non-native surface.** Flat near-black background, no vibrancy or material, uniform
corner radii, custom typography. It reads as a cross-platform app rather than a macOS
one. Adopt the standard material for the panel background and system-standard list
selection, and keep the accent color for the category swatches, where color carries
meaning.

**Relative timestamps render "in 0s".** Visible on four cards in the screenshot.
`ClipCardView.swift:497` uses
`Date.RelativeFormatStyle(presentation: .numeric, unitsStyle: .narrow)`, which renders a
sub-second-old clip in the future tense. `ScriptsPanelView.swift:220` has the same call.
Fix: floor the interval and special-case anything under a minute to "now".

### 4.3 Structural: two files over the line

`SettingsView.swift` is 1720 lines and `ClipListView.swift` is 1506, against the
300-line ceiling in the project's own `coding-principles.md`. `ClipListView` currently
owns sectioning, card rendering, the AI actions menu, AI proposal handling, OCR, the
status banner, timeline reveal, batch delete, batch AI titling, keyboard selection, and
paste. That is why the panel "feels disconnected": adding a coherent interaction means
touching a file that does nine unrelated jobs, so changes get bolted on at the edges.

Split before adding anything: card rendering, the AI action menu, the banner, and
keyboard/selection handling are four clean extractions with no behavior change.
`SettingsView` splits along its existing tabs.

### 4.4 Feature gaps worth naming

- **File clips are broken** (see 5.1). Fixing the bug also raises the question of whether
  a file clip should show a Quick Look preview rather than a filename string.
- No preview pane. A 300-character preview on a card is not enough to decide; selecting a
  clip should show it in full without opening the editor.
- No filters in the list. The search field is the only narrowing tool. Kind, source app,
  and date-range chips would carry most of what `#kind` search syntax currently hides in
  a text field.
- No favorites or pinning surfaced in the list (pin exists in the key hints).
- Empty categories render identically to full ones; `claude 0` and `variables 0` in the
  sidebar are dead weight that should either be styled as empty or offer a "file
  something here" affordance.

---

## 5. Bugs found

### 5.1 Folder copies fail every time (HIGH)

`~/Library/Application Support/Clippy/Logs/clippy.log`: 1313 lines total, of which
**1273 (97%) are `Failed to save file clip: unreadableFile`**, spanning 2026-07-12 to
2026-09-02.

Root cause: `ClipboardMonitor.captureFileIfPresent` filters candidate URLs by
`attributesOfItem(...)[.size] > 0` (line 246), then `MediaStore.storeFile` reads them
with `Data(contentsOf:)` (line 74). A directory has a non-zero size attribute and cannot
be read as data. Reproduced:

```
$ swift /tmp/dt.swift        # on /tmp/dirtest, an empty directory
size attr: 64
read FAILED: Error Domain=NSCocoaErrorDomain Code=256 ... NSPOSIXErrorDomain Code=21 "Is a directory"
```

Every Finder folder copy hits this, logs an error, and produces no clip. The user sees
nothing: no clip, no capture sound, no error surfaced in the UI.

Fix: check `isDirectoryKey` in the viability filter. Decide what a folder clip should be
(a path reference with no byte copy is the obvious answer, and `Clip.filePath` already
exists) rather than dropping it. Same filter should skip iCloud-evicted files
(`ubiquitousItemDownloadingStatus`) instead of failing on them.

This also means the capture path swallows errors: 1273 failures over two months with no
user-visible signal. Capture failures should surface once, not silently.

### 5.2 An unreadable iCloud archive locks sync out permanently (MEDIUM)

16 occurrences of
`iCloud sync failed: Error while parsing string: unescaped control characters other than TAB (U+0009) are explicitly prohibited (at line 543, column 23)`,
all between 2026-06-17 and 2026-06-23, none since.

The escaping bug itself is already fixed: `ClippyArchive.quote` escapes every control
character, and `git log` puts that hardening in the June work. What is not fixed is the
failure mode. `sync()` calls `pullIfPresent` before the export, both inside one `do`, so
a parse failure on the remote file skips the export - which means the bad file is never
replaced and every subsequent sync hits the same error forever. One poisoned archive
written by an older build disables sync for good, on every device sharing it.

Fix: a pull that cannot be parsed is logged and the file quarantined (moved aside, not
deleted - it is the only copy of whatever the other device had), then the export proceeds
and writes a good one over the top.

### 5.3 Log level hides everything useful (MEDIUM)

27 INFO and 22 WARN lines against 1313 ERROR lines, over three months. The default level
suppresses the events needed to diagnose capture and paste behavior, which is why the
June sound investigation needed external probe scripts. Test artifacts
(`test-above-<UUID>`) from the test suite are also written into the user's production
log.

Correction to an earlier draft: this section claimed the log has no rotation. It does -
`ClippyLog` rotates at 2 MB and keeps one backup. The single file since June is simply a
105 KB log that never reached the threshold.

---

## 6. Sequence, and what shipped

Everything in the first three groups shipped in v1.9.0 on 2026-09-16, except where
noted. The UI group is deliberately deferred: it cannot be verified without a display,
and the June audit deferred its own visual work for the same reason.

**Shipped: bugs**
1. MCP schema target, plus a smoke-test guard that fails the build on a non-numeric
   `exclusiveMinimum`.
2. Folder-copy capture fix (5.1), including iCloud-evicted files, plus one summary log
   line when a copy produces no clips at all. The per-copy UI notice was dropped: the
   failure mode that caused 1273 log lines is gone, and there is no general banner bus to
   hang a notice on, so building one would have been scope for a rare residual case.
3. `in 0s` timestamp fix (4.2), in `RelativeTime`, used by both call sites.
4. `PRAGMA busy_timeout` on the MCP connection.
5. iCloud archive quarantine (5.2).

**Shipped: MCP**
6. Option B-plus from 2.2, not A. Writes still go straight to SQLite, but
   `ExternalChangeWatcher` polls `data_version` and the two JSON files and calls
   `notifyChanges(in: .fullDatabase)`, so the app reflects them in about two seconds.
   Option A (route every mutation through the app) remains the better end state - one
   writer, app-side invariants - but it is a larger change than the visibility problem
   required, and B closes the user-visible gap today. Revisit A when MCP writes need to
   respect the history cap and eviction rules.
7. Full clip and category CRUD, batch assign and delete, `clippy_stats`.
8. Script and AI-action tools with the fail-closed disabled-on-create rule.
9. Task-shaped descriptions; the new `clip-automation` skill carries the chains for
   scripts and actions, `clipboard-triage` for filing.
10. Per-call audit logging. Concealed-clip handling turned out to be unnecessary - see
    the correction in 2.6.

**Shipped: Apple Intelligence**
11. `AppleIntelligenceProvider` behind the existing factory, availability-gated, now the
    default provider. Tool calling is explicitly not implemented and says so in the type:
    Foundation Models wants compile-time `@Generable` argument types and `AITool` carries
    a runtime JSON schema. Chat, AI actions, and auto-titling all work.
12. Auto-titling on capture already existed (`aiAutoSuggestTitles`, opt-in, detached). It
    is now hard-gated on a provider that runs locally, because it fires on every copy.

**Still open: the rest of the AI work**
13. Auto-filing suggestions into categories.
14. Sensitive-content detection and auto-conceal.
15. Local embeddings for semantic search, hybrid-ranked with FTS.

**Still open: the UI**
16. Split `ClipListView` and `SettingsView`. No behavior change.
17. Rebuild the card: content as headline, source app demoted, compact row mode default.
18. Remove per-card strokes; selection owns the stroke.
19. Native material and system list selection.
20. Preview pane; kind/app/date filter chips.

---

## 7. Evidence index

| Claim | Source |
|---|---|
| 5 tools rejected, 3 accepted | session MCP connection report + `tools/list` probe |
| `exclusiveMinimum: true` before, `0` after | `node build/index.mjs` tools/list probe, both bundles |
| ValueObservation ignores external writes | GRDB docs, `ValueObservation.md` "Dealing with Undetected Changes" |
| No `busy_timeout` | `integrations/clippy-mcp/src/db.ts:openDatabase` |
| Scripts/AI actions outside the DB | `~/Library/Application Support/Clippy/{scripts.json,ai-actions.json}` |
| 644 clips / 600 uncategorized / 43 titled / 6 images | `sqlite3 clippy.sqlite` counts |
| Apple Intelligence available | `swift /tmp/fmprobe.swift` -> `availability: available` |
| No FoundationModels usage | `ctx_search` over `Sources/`, 0 matches |
| 1273/1313 log lines are one error | `awk` over `Logs/clippy.log` |
| Directory passes size filter, fails read | `swift /tmp/dt.swift` |
| Card hierarchy, borders, `in 0s` | `img/clippy_main_window.png` |
| File sizes over the 300-line ceiling | `wc -l Sources/Clippy/**/*.swift` |
