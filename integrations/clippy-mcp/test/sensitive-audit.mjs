// Sensitive-clip exclusion and audit-stream tests. Drives the built server over
// stdio against a throwaway database + sidecar, then inspects the audit files
// the way Swift's AuditLog.verify() does (hash chain over raw line bytes).
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";

const here = path.dirname(new URL(import.meta.url).pathname);
const root = path.resolve(here, "..");
const sha = (s) => createHash("sha256").update(s).digest("hex");
const fail = (m) => {
  console.error("FAIL:", m);
  process.exit(1);
};
const check = (cond, m) => cond || fail(m);

function makeEnv(flagsContent) {
  const dir = mkdtempSync(path.join(tmpdir(), "clippy-mcp-sens-"));
  const dbPath = path.join(dir, "clippy.sqlite");
  const db = new DatabaseSync(dbPath);
  db.exec(readFileSync(path.join(here, "schema.sql"), "utf8"));
  const insert = db.prepare(
    `INSERT INTO clips (contentText, typeIdentifier, createdAt, contentKind, sourceAppName)
     VALUES (?, 'public.utf8-plain-text', ?, 'text', 'Test')`,
  );
  const ids = {};
  ids.plain = Number(insert.run("quarterly meeting notes", "2026-01-01 00:00:01.000").lastInsertRowid);
  ids.card = Number(insert.run("card 4111111111111111 notes", "2026-01-01 00:00:02.000").lastInsertRowid);
  ids.cleared = Number(insert.run("api token meeting maybe", "2026-01-01 00:00:03.000").lastInsertRowid);
  ids.userFlagged = Number(insert.run("harmless meeting text", "2026-01-01 00:00:04.000").lastInsertRowid);
  ids.lowConf = Number(insert.run("low confidence meeting", "2026-01-01 00:00:05.000").lastInsertRowid);
  db.close();
  if (flagsContent !== undefined) {
    const sidecar = path.join(dir, "media", "_sidecar");
    mkdirSync(sidecar, { recursive: true });
    writeFileSync(
      path.join(sidecar, "sensitive-flags.json"),
      typeof flagsContent === "function" ? flagsContent() : flagsContent,
    );
  }
  return { dir, dbPath, ids };
}

const key = (text) => `t-${sha(text)}`;
const flags = () =>
  JSON.stringify({
    [key("card 4111111111111111 notes")]: { kinds: ["creditCard"], confidence: 2, flaggedAt: "2026-01-01T00:00:00Z", userOverride: null },
    // Detected as sensitive, but the user said "not sensitive": must be visible.
    [key("api token meeting maybe")]: { kinds: ["genericSecret"], confidence: 1, flaggedAt: "2026-01-01T00:00:00Z", userOverride: false },
    // No detection, but the user marked it sensitive: must be withheld.
    [key("harmless meeting text")]: { kinds: [], confidence: 0, flaggedAt: "2026-01-01T00:00:00Z", userOverride: true },
    // Below threshold and no override: visible.
    [key("low confidence meeting")]: { kinds: [], confidence: 0, flaggedAt: "2026-01-01T00:00:00Z", userOverride: null },
  });

async function session(env) {
  const child = spawn("node", [path.join(root, "build", "index.mjs")], {
    env: { ...process.env, CLIPPY_DB_PATH: env.dbPath },
    stdio: ["pipe", "pipe", "pipe"],
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
  const rpc = (method, params) =>
    new Promise((resolve) => {
      const id = nextId++;
      pending.set(id, resolve);
      child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  await rpc("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "t", version: "0" } });
  child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
  return {
    call: async (name, args = {}) => JSON.parse((await rpc("tools/call", { name, arguments: args })).result.content[0].text),
    close: () => child.kill(),
  };
}

// ---- 1. Normal flag store ---------------------------------------------------
const env = makeEnv(flags);
const s = await session(env);

const search = await s.call("clippy_search_clips", { query: "meeting" });
const found = search.results.map((r) => r.id).sort((a, b) => a - b);
check(!found.includes(env.ids.card), "search returned a flagged (high-confidence) clip");
check(!found.includes(env.ids.userFlagged), "search returned a clip the user marked sensitive");
check(found.includes(env.ids.plain), "search hid an ordinary clip");
check(found.includes(env.ids.cleared), "userOverride=false must make a detected clip visible");
check(found.includes(env.ids.lowConf), "a below-threshold flag must not hide a clip");

const recent = await s.call("clippy_list_recent", { limit: 10 });
const recentIDs = recent.results.map((r) => r.id);
check(recentIDs.length === 3 && !recentIDs.includes(env.ids.card), `list_recent leaked or short-filled: ${recentIDs}`);

// The page must still fill to `limit` past withheld rows.
const limited = await s.call("clippy_list_recent", { limit: 3 });
check(limited.results.length === 3, "list_recent must fill the limit after filtering");

const refused = await s.call("clippy_get_clip", { id: env.ids.card });
check(refused.error === "sensitive_content_withheld", "get_clip must refuse a flagged clip");
check(!JSON.stringify(refused).includes("4111"), "refusal must not echo content");
const refusedUser = await s.call("clippy_get_clip", { id: env.ids.userFlagged });
check(refusedUser.error === "sensitive_content_withheld", "get_clip must refuse a user-flagged clip");
check((await s.call("clippy_get_clip", { id: env.ids.plain })).contentText === "quarterly meeting notes", "get_clip failed on an ordinary clip");
const editRefused = await s.call("clippy_update_clip", { id: env.ids.card, title: "x" });
check(editRefused.error === "sensitive_content_withheld", "update_clip must refuse a flagged clip");
s.close();

// ---- 2. Audit stream --------------------------------------------------------
const auditDir = path.join(env.dir, "audit");
const files = readdirSync(auditDir).filter((f) => /^mcp-audit-\d{4}-\d{2}\.jsonl$/.test(f));
check(files.length === 1, `expected one mcp audit file, got ${files}`);
const file = path.join(auditDir, files[0]);
check((statSync(file).mode & 0o777) === 0o600, "audit file must be mode 0600");
check((statSync(auditDir).mode & 0o777) === 0o700, "audit directory must be mode 0700");
const raw = readFileSync(file);
const lines = raw.toString("utf8").split("\n").filter(Boolean);
check(lines.length === 7, `expected 7 audit lines, got ${lines.length}`);
let expected = "0".repeat(64);
for (const line of lines) {
  const entry = JSON.parse(line);
  check(entry.prev === expected, "audit chain broken");
  check(entry.actor === "mcp" && typeof entry.action === "string" && Array.isArray(entry.clipIDs), "audit line shape");
  expected = sha(line);
}
const text = raw.toString("utf8");
check(!text.includes("4111") && !text.includes("quarterly"), "audit stream must never contain clip content");
const getLine = lines.map((l) => JSON.parse(l)).find((e) => e.action === "clippy_get_clip" && e.clipIDs[0] === env.ids.card);
check(getLine && getLine.detail.startsWith("outcome=refused"), "a refused read must be audited as refused with its clip id");
const searchLine = lines.map((l) => JSON.parse(l)).find((e) => e.action === "clippy_search_clips");
check(searchLine && searchLine.clipIDs.includes(env.ids.plain) && !searchLine.clipIDs.includes(env.ids.card), "search audit lists returned ids only");

// Tamper detection (mirrors AuditLog.verify): edit a middle line, chain must break.
const tampered = lines.slice();
tampered[1] = tampered[1].replace('"mcp"', '"evil"');
let broke = false;
let exp = "0".repeat(64);
for (const line of tampered) {
  if (JSON.parse(line).prev !== exp) broke = true;
  exp = sha(line);
}
check(broke, "tampering must break the chain");

// ---- 3. Fail closed on a malformed sidecar ----------------------------------
const bad = makeEnv("{ not json");
const s2 = await session(bad);
const none = await s2.call("clippy_list_recent", {});
check(none.results.length === 0, "an unreadable flag store must withhold every clip");
check((await s2.call("clippy_get_clip", { id: bad.ids.plain })).error === "sensitive_content_withheld", "unreadable flag store must refuse get");
s2.close();

// ---- 4. No sidecar at all: nothing flagged ----------------------------------
const clean = makeEnv(undefined);
const s3 = await session(clean);
check((await s3.call("clippy_list_recent", {})).results.length === 5, "a missing flag store means nothing is flagged");
s3.close();

console.log("sensitive-audit: all checks passed");
process.exit(0);
