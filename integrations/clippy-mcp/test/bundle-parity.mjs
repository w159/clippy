// Does the plugin's vendored server expose the same tools as the current source?
//
// This is a parity check, not a byte comparison. esbuild writes the resolved
// path of every bundled module into the output as a comment, so a checkout whose
// node_modules is a symlink (the `node_modules.nosync.noindex` layout used to
// keep npm's churn out of iCloud) produces a bundle that differs from CI's in
// 219 comment lines and nothing else. `diff` calls that stale; it is not.
//
// What actually matters is the contract: same tool names, same descriptions,
// same input schemas. So both bundles are started and asked for tools/list, and
// the normalized results are compared. A real drift - a tool added, a schema
// changed, a description rewritten - fails this. A path comment does not.
import { spawn } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";

const here = path.dirname(new URL(import.meta.url).pathname);
const root = path.resolve(here, "..");
const built = path.join(root, "build", "index.mjs");
const vendored = path.resolve(root, "..", "clippy-plugin", "mcp", "index.mjs");

// Both servers refuse to start without a database, so give them a throwaway one.
const dir = mkdtempSync(path.join(tmpdir(), "clippy-parity-"));
const dbPath = path.join(dir, "clippy.sqlite");
const seed = new DatabaseSync(dbPath);
seed.exec(readFileSync(path.join(here, "schema.sql"), "utf8"));
seed.close();

/** Start one bundle, ask for tools/list, return the tools array. */
function listTools(bundle) {
  return new Promise((resolve, reject) => {
    const child = spawn("node", [bundle], {
      env: { ...process.env, CLIPPY_DB_PATH: dbPath },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let buf = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`${bundle}: timed out waiting for tools/list`));
    }, 20_000);

    child.stdout.on("data", (chunk) => {
      buf += chunk.toString();
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (!line) continue;
        const msg = JSON.parse(line);
        if (msg.id === 2) {
          clearTimeout(timer);
          child.kill();
          resolve(msg.result.tools);
        }
      }
    });
    child.on("error", reject);

    child.stdin.write(
      JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "parity", version: "0.0.0" },
        },
      }) + "\n",
    );
    child.stdin.write(
      JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized", params: {} }) + "\n",
    );
    child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list" }) + "\n");
  });
}

/** Stable key order so two structurally identical schemas compare equal. */
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort()
        .map((k) => [k, canonical(value[k])]),
    );
  }
  return value;
}

function fingerprint(tools) {
  return new Map(
    tools.map((t) => [
      t.name,
      JSON.stringify(canonical({ description: t.description, inputSchema: t.inputSchema })),
    ]),
  );
}

const [fromSource, fromPlugin] = await Promise.all([listTools(built), listTools(vendored)]);
const source = fingerprint(fromSource);
const plugin = fingerprint(fromPlugin);

const problems = [];
for (const name of source.keys()) {
  if (!plugin.has(name)) problems.push(`missing from the vendored bundle: ${name}`);
  else if (plugin.get(name) !== source.get(name)) problems.push(`differs: ${name}`);
}
for (const name of plugin.keys()) {
  if (!source.has(name)) problems.push(`only in the vendored bundle (removed from source?): ${name}`);
}

if (problems.length > 0) {
  console.error("Vendored plugin bundle is out of date:");
  for (const p of problems) console.error(`  - ${p}`);
  console.error("\nRun integrations/scripts/sync-mcp.sh and commit the result.");
  process.exit(1);
}

console.log(`BUNDLE PARITY: ${source.size} tools identical in source build and plugin bundle`);
