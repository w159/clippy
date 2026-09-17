// Smoke test: spawn the built server against a throwaway database and drive it
// over stdio JSON-RPC. Covers the schema dialect, then a round-trip through each
// tool family (clips, categories, scripts, AI actions) and the safety rules that
// must hold. Never touches the user's real database or JSON stores: everything
// lives under one temp directory, which is also the server's support directory.
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const here = path.dirname(new URL(import.meta.url).pathname);
const root = path.resolve(here, "..");

// 1. Build a temp DB with the derived schema. scripts.json / ai-actions.json are
//    created on demand by the server in the same directory.
const dir = mkdtempSync(path.join(tmpdir(), "clippy-mcp-test-"));
const dbPath = path.join(dir, "clippy.sqlite");
const schema = readFileSync(path.join(here, "schema.sql"), "utf8");
const seed = new DatabaseSync(dbPath);
seed.exec(schema);
// Seed the starter category so the delete-protection check has a target.
seed
  .prepare(
    `INSERT INTO category (name, colorHex, iconKind, iconValue, sortOrder, isStarter, createdAt)
     VALUES ('Pinned', '#FF9500', 'symbol', 'pin.fill', 0, 1, '2026-01-01 00:00:00.000')`,
  )
  .run();
seed.close();

// 2. Spawn the server.
const child = spawn("node", [path.join(root, "build", "index.mjs")], {
  env: { ...process.env, CLIPPY_DB_PATH: dbPath },
  stdio: ["pipe", "pipe", "pipe"],
});
const stderrLines = [];
child.stderr.on("data", (d) => {
  const text = d.toString();
  stderrLines.push(text);
  process.stderr.write(`[server] ${text}`);
});

let buf = "";
const pending = new Map();
child.stdout.on("data", (chunk) => {
  buf += chunk.toString();
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl).trim();
    buf = buf.slice(nl + 1);
    if (!line) continue;
    const msg = JSON.parse(line);
    if (msg.id !== undefined && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  }
});

let nextId = 1;
function rpc(method, params) {
  const id = nextId++;
  return new Promise((resolve) => {
    pending.set(id, resolve);
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  });
}
function notify(method, params) {
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
}

async function call(name, args = {}) {
  const resp = await rpc("tools/call", { name, arguments: args });
  return JSON.parse(resp.result.content[0].text);
}

const fail = (m) => {
  console.error("FAIL:", m);
  child.kill();
  process.exit(1);
};

const check = (condition, message) => {
  if (!condition) fail(message);
};

try {
  await rpc("initialize", {
    protocolVersion: "2024-11-05",
    capabilities: {},
    clientInfo: { name: "smoke", version: "0.0.0" },
  });
  notify("notifications/initialized", {});

  // -------------------------------------------------------------------------
  // tools/list: presence and schema dialect
  // -------------------------------------------------------------------------
  const list = await rpc("tools/list", {});
  const names = list.result.tools.map((t) => t.name).sort();
  console.log("TOOLS:", names.length, "\n ", names.join("\n  "));

  const expected = [
    // clips
    "clippy_search_clips", "clippy_list_recent", "clippy_get_clip",
    "clippy_create_clip", "clippy_update_clip", "clippy_delete_clips",
    // categories
    "clippy_list_categories", "clippy_create_category", "clippy_update_category",
    "clippy_delete_category", "clippy_assign_clips", "clippy_stats",
    // scripts
    "clippy_list_scripts", "clippy_get_script", "clippy_create_script",
    "clippy_update_script", "clippy_delete_script",
    // AI actions
    "clippy_list_ai_actions", "clippy_get_ai_action", "clippy_create_ai_action",
    "clippy_update_ai_action", "clippy_delete_ai_action",
    // deprecated aliases, kept so existing configs keep working
    "clippy_search", "clippy_get", "clippy_add", "clippy_delete", "clippy_set_category",
  ];
  for (const e of expected) check(names.includes(e), `missing tool ${e}`);

  // Every advertised schema must be draft-07+. The draft-04 / OpenAPI-3.0
  // boolean form (`exclusiveMinimum: true`) makes MCP clients silently drop the
  // tool from the model's tool list -- no error, the tool just never exists.
  // Guards against a zod-to-json-schema target regression.
  for (const tool of list.result.tools) {
    const walk = (node, at) => {
      if (node === null || typeof node !== "object") return;
      for (const key of ["exclusiveMinimum", "exclusiveMaximum"]) {
        if (key in node && typeof node[key] !== "number") {
          fail(
            `${tool.name}: ${at}.${key} is ${JSON.stringify(node[key])}, ` +
              `expected a number (draft-04 boolean form rejected by MCP clients)`,
          );
        }
      }
      for (const [k, v] of Object.entries(node)) walk(v, `${at}.${k}`);
    };
    walk(tool.inputSchema, tool.name);
    // Deprecated aliases are one-liners pointing at their replacement; every
    // live tool has to carry enough text to tell a model when to reach for it.
    if (!tool.description.startsWith("DEPRECATED")) {
      check(
        tool.description.length > 120,
        `${tool.name}: description is too thin to steer a model`,
      );
    }
  }
  console.log("SCHEMA DIALECT: draft-07+ on all", list.result.tools.length, "tools");

  // -------------------------------------------------------------------------
  // Clips: create -> search -> get -> update -> delete
  // -------------------------------------------------------------------------
  const added = await call("clippy_create_clip", {
    text: "hello kangaroo from clippy mcp",
    title: "Smoke Note",
  });
  check(added.id, "create_clip returned no id");

  const found = await call("clippy_search_clips", { query: "kangaroo" });
  const hit = found.results.find((r) => r.id === added.id);
  check(hit, "search did not return the new clip (FTS sync broken)");
  check(hit.title === "Smoke Note", "title not surfaced in search results");

  check(
    (await call("clippy_search_clips", { query: "kangaroo", kind: "image" })).results.length === 0,
    "kind filter did not apply",
  );

  const got = await call("clippy_get_clip", { id: added.id });
  check(got.contentText === "hello kangaroo from clippy mcp", "get returned wrong contentText");

  const edited = await call("clippy_update_clip", {
    id: added.id,
    text: "hello wallaby from clippy mcp",
    title: "Edited Note",
  });
  check(edited.updated, "update_clip did not report success");
  const reread = await call("clippy_get_clip", { id: added.id });
  check(reread.contentText === "hello wallaby from clippy mcp", "update did not persist text");
  check(reread.userTitle === "Edited Note", "update did not persist title");
  check(
    (await call("clippy_search_clips", { query: "wallaby" })).results.length === 1,
    "FTS index did not follow the update",
  );
  check(
    (await call("clippy_update_clip", { id: added.id })).error === "nothing_to_update",
    "update with no fields should be rejected, not silently succeed",
  );

  // -------------------------------------------------------------------------
  // Categories: create -> assign in bulk -> update -> protections -> delete
  // -------------------------------------------------------------------------
  const cat = await call("clippy_create_category", { name: "MCP Test", colorHex: "30B0C7" });
  check(cat.id, "create_category returned no id");
  check(cat.colorHex === "#30B0C7", "colorHex was not normalized");

  const second = await call("clippy_create_clip", { text: "second clip", title: "Two" });
  const assigned = await call("clippy_assign_clips", {
    clipIDs: [added.id, second.id, 999999],
    categoryID: cat.id,
    member: true,
  });
  check(assigned.appliedCount === 2, "bulk assign did not file both clips");
  check(assigned.missing.length === 1, "bulk assign did not report the unknown id");

  const scoped = await call("clippy_search_clips", { query: "clip", categoryID: cat.id });
  check(scoped.results.length >= 1, "category filter returned nothing");

  const renamed = await call("clippy_update_category", { id: cat.id, name: "Renamed" });
  check(renamed.name === "Renamed", "category rename did not persist");
  check(renamed.clipCount === 2, "rename must not disturb membership");

  const starter = (await call("clippy_list_categories")).categories.find((c) => c.isStarter);
  check(
    (await call("clippy_delete_category", { id: starter.id })).error ===
      "starter_category_protected",
    "the starter category must be protected from deletion",
  );

  const removedCategory = await call("clippy_delete_category", { id: cat.id });
  check(removedCategory.clipsReleased === 2, "deleting a category must release, not delete, clips");
  check(
    (await call("clippy_get_clip", { id: added.id })).id === added.id,
    "deleting a category must not delete its clips",
  );

  // -------------------------------------------------------------------------
  // Stats
  // -------------------------------------------------------------------------
  const stats = await call("clippy_stats");
  check(stats.clips.total === 2, `stats total should be 2, got ${stats.clips.total}`);
  check(stats.clips.unfiled === 2, "stats should report both clips unfiled after the delete");

  // -------------------------------------------------------------------------
  // Scripts: created disabled, edits re-disable. This is the RCE guard.
  // -------------------------------------------------------------------------
  const script = await call("clippy_create_script", {
    name: "Say hello",
    body: "echo hello",
    interpreter: "zsh",
  });
  check(script.isEnabled === false, "a script created over MCP MUST land disabled");
  check(script.notice, "create_script must tell the caller the script is disabled");
  check(existsSync(path.join(dir, "scripts.json")), "scripts.json was not written");

  const scriptBody = await call("clippy_get_script", { id: script.id });
  check(scriptBody.body === "echo hello", "get_script returned the wrong body");

  const scriptEdited = await call("clippy_update_script", {
    id: script.id,
    body: "echo goodbye",
  });
  check(scriptEdited.isEnabled === false, "editing a script MUST re-disable it");
  check(
    (await call("clippy_get_script", { id: script.id })).body === "echo goodbye",
    "script edit did not persist",
  );

  // The on-disk shape has to decode into Swift's Script, so the keys matter.
  const scriptsOnDisk = JSON.parse(readFileSync(path.join(dir, "scripts.json"), "utf8"));
  for (const key of [
    "id", "name", "interpreter", "body", "feedsClipboard",
    "outputToClipboard", "createdAt", "updatedAt", "sortOrder", "isEnabled",
  ]) {
    check(key in scriptsOnDisk[0], `scripts.json is missing "${key}"; Swift will fail to decode it`);
  }
  check(
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(scriptsOnDisk[0].createdAt),
    `scripts.json createdAt "${scriptsOnDisk[0].createdAt}" is not Swift's .iso8601 shape`,
  );

  check((await call("clippy_list_scripts")).disabledCount === 1, "list_scripts miscounted disabled");
  check((await call("clippy_delete_script", { id: script.id })).deleted, "delete_script failed");

  // -------------------------------------------------------------------------
  // AI actions: the {clip} placeholder is mandatory; built-ins are protected.
  // -------------------------------------------------------------------------
  check(
    (await call("clippy_create_ai_action", { name: "Bad", promptTemplate: "no placeholder" }))
      .error === "missing_clip_placeholder",
    "an AI action without {clip} must be rejected",
  );

  const action = await call("clippy_create_ai_action", {
    name: "Bulletize",
    promptTemplate: "Rewrite as bullet points:\n\n{clip}",
  });
  check(action.id, "create_ai_action returned no id");
  check(action.outputDisposition === "proposeEdit", "default disposition should be proposeEdit");

  const tuned = await call("clippy_update_ai_action", { id: action.id, temperature: 0.9 });
  check(tuned.temperature === 0.9, "ai action update did not persist");
  check(
    (await call("clippy_update_ai_action", { id: action.id, promptTemplate: "still nothing" }))
      .error === "missing_clip_placeholder",
    "an edit that drops {clip} must be rejected",
  );
  check((await call("clippy_delete_ai_action", { id: action.id })).deleted, "delete_ai_action failed");

  // -------------------------------------------------------------------------
  // Deprecated aliases still work
  // -------------------------------------------------------------------------
  const legacyAdded = await call("clippy_add", { text: "legacy path", title: "Legacy" });
  check(legacyAdded.id, "clippy_add alias broke");
  check((await call("clippy_delete", { id: legacyAdded.id })).deletedCount === 1,
        "clippy_delete alias broke");

  // -------------------------------------------------------------------------
  // Clip deletion, and the audit trail
  // -------------------------------------------------------------------------
  const removed = await call("clippy_delete_clips", { ids: [added.id, second.id] });
  check(removed.deletedCount === 2, "batch delete did not remove both clips");
  check(
    (await call("clippy_search_clips", { query: "wallaby" })).results.length === 0,
    "delete did not remove the clip from the FTS index",
  );

  const auditLog = stderrLines.join("");
  check(auditLog.includes("clippy-mcp ok clippy_create_clip"), "no audit line for a write");
  check(auditLog.includes("clippy-mcp ok clippy_delete_clips"), "no audit line for a delete");

  console.log("\nALL CHECKS PASSED");
  child.kill();
  process.exit(0);
} catch (err) {
  fail(err && err.stack ? err.stack : String(err));
}
